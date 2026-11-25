import AppKit
import CryptoKit
import Darwin
import ImageIO

/// Owns only the Finder artwork on eligible immediate children of the selected Desktop.
@MainActor
final class FolderVillage: NSObject {
    struct House {
        let id: String
        let name: String
        let variant: Int
        let url: URL
    }
    private struct Icon: Codable, Equatable {
        let custom: Bool
        let file: String?   // Digest of data and resource-fork payloads; nil means no Icon file.
    }
    private struct Entry: Codable {
        var path: String
        var bookmark: Data?
        let variant: Int
        let original: Icon
        var expected: Icon
        var installed: Icon?
        var upgradingFrom: Icon?
        var backupDigest: String?
        var restoring: Bool?
        var overridden = false
    }
    private struct Ledger: Codable {
        var version = 1
        var enabled = false
        var entries: [String: Entry] = [:]
        var variants: [String: Int] = [:]
    }
    private enum Issue: String, LocalizedError {
        case denied = "Folder access was denied. Allow Snowfall to access Desktop Folder in System Settings → Privacy & Security → Files & Folders."
        case busy = "Another village operation is finishing. Try again in a moment."
        case registry = "The local folder-icon backup could not be read or saved. The existing backups have been kept."
        case artwork = "One of the six bundled house images is missing or unreadable."
        case folder = "A folder became unavailable or its Finder icon could not be updated. Existing backups have been kept."
        case icon = "One folder has an icon file that could not be backed up safely."
        case conflict = "An interrupted icon change could not be identified safely. Its original backup has been kept."
        case missing = "A previously styled folder is unavailable. Reconnect its volume and restore again."
        var errorDescription: String? { rawValue }
    }

    private(set) var houses: [House] = []
    private(set) var eligibleCount = 0
    private(set) var enabled = false
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    let desktop: URL
    private let storage: URL
    private let assets: URL
    private var ledger = Ledger()
    private var watcher: DispatchSourceFileSystemObject?
    private var changes: DispatchWorkItem?
    private struct Artwork {
        let fork: Data
        let signature: Icon
    }
    private var artwork: [Int: Artwork] = [:]
    private let files = FileManager.default
    private var registry: URL { storage.appendingPathComponent("state.json") }
    private var copies: URL { storage.appendingPathComponent("originals", isDirectory: true) }

    init(desktop: URL? = nil, storage: URL? = nil, assets: URL) {
        let fm = FileManager.default
        self.desktop = (desktop ?? fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]).standardizedFileURL
        self.storage = (storage ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.snowfallos.desktop/FolderVillage", isDirectory: true)).standardizedFileURL
        self.assets = assets
        super.init()
        if let state = try? readLedger() { ledger = state; enabled = state.enabled }
    }

    deinit { changes?.cancel(); watcher?.cancel() }

    /// Read-only, including on a first launch where the support directory does not exist.
    func inspect() throws {
        do {
            ledger = try readLedger()
            enabled = ledger.enabled
            try report(try folders())
        } catch { throw safe(error) }
    }

    /// Validates a Finder selection without listing its contents or its neighbors.
    func currentHouse(at url: URL) -> House? {
        let selected = url.standardizedFileURL
        guard selected.deletingLastPathComponent().standardizedFileURL.path == desktop.path,
              !selected.lastPathComponent.hasPrefix("."),
              let flags = try? selected.resourceValues(forKeys: [.isHiddenKey, .isPackageKey, .isAliasFileKey]),
              flags.isHidden != true, flags.isPackage != true, flags.isAliasFile != true,
              let id = try? identity(selected), houses.contains(where: { $0.id == id }),
              let entry = ledger.entries[id], !entry.overridden,
              (try? currentIcon(selected)) == (entry.installed ?? entry.expected) else { return nil }
        return House(id: id, name: selected.lastPathComponent, variant: entry.variant, url: selected)
    }

    func apply() throws {
        try mutate {
            let current = try folders()  // Ask the OS for access before committing the opt-in.
            for variant in 1...6 { _ = try houseArt(variant) }
            ledger.enabled = true
            try persist()
            try reconcile(current)
        }
    }

    func refresh() throws {
        do {
            let state = try readLedger()
            if !state.enabled {
                try inspect()
                stopWatching()
                return
            }
        } catch { throw safe(error) }
        try mutate {
            let current = try folders()
            if ledger.enabled { try reconcile(current) } else { try report(current) }
        }
    }

    func restore() throws {
        do {
            let state = try readLedger()
            if !state.enabled && state.entries.isEmpty { try inspect(); stopWatching(); return }
        } catch { throw safe(error) }
        try mutate {
            ledger.enabled = false
            try persist()
            let current = try folders()
            var firstIssue: Error?
            for (id, entry) in Array(ledger.entries) {
                do {
                    guard let folder = try resolve(id: id, entry: entry, current: current) else { throw Issue.missing }
                    try undo(id: id, entry: entry, folder: folder)
                } catch { if firstIssue == nil { firstIssue = error } }
            }
            try report(current)
            if let error = firstIssue { throw error }
        }
    }

    private func mutate(_ operation: () throws -> Void) throws {
        do {
            try files.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(storage.appendingPathComponent("change.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixOr(.registry) }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Issue.busy }
            defer { flock(fd, LOCK_UN) }
            ledger = try readLedger()
            defer {
                enabled = ledger.enabled
                if enabled { startWatching() } else { stopWatching() }
            }
            try operation()
        } catch { throw safe(error) }
    }

    private func readLedger() throws -> Ledger {
        let bytes: Data
        do { bytes = try Data(contentsOf: registry) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return Ledger() }
            throw safe(error, fallback: .registry)
        }
        guard let state = try? JSONDecoder().decode(Ledger.self, from: bytes), state.version == 1,
              state.entries.allSatisfy({ key, record in
                  key.count == 64 && key.allSatisfy(\.isHexDigit) && (1...6).contains(record.variant)
              }), state.variants.values.allSatisfy({ (1...6).contains($0) }) else { throw Issue.registry }
        return state
    }

    private func persist() throws {
        do { try JSONEncoder().encode(ledger).write(to: registry, options: .atomic) }
        catch { throw safe(error, fallback: .registry) }
    }

    private func folders() throws -> [String: URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .isAliasFileKey]
        let children = try files.contentsOfDirectory(at: desktop, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var found: [String: URL] = [:]
        for url in children {
            do {
                let flags = try url.resourceValues(forKeys: keys)
                guard flags.isDirectory == true, flags.isPackage != true, flags.isSymbolicLink != true,
                      flags.isHidden != true, flags.isAliasFile != true, !url.lastPathComponent.hasPrefix("."),
                      let id = try identity(url) else { continue }
                found[id] = url
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
                throw error
            }
        }
        return found
    }

    private func identity(_ url: URL) throws -> String? {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }; throw posixOr(.folder)
        }
        guard statInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        let volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? String(statInfo.st_dev)
        let birth = statInfo.st_birthtimespec
        return digest(Data("\(volume)/\(statInfo.st_ino)/\(birth.tv_sec)/\(birth.tv_nsec)".utf8))
    }

    private func resolve(id: String, entry: Entry, current: [String: URL]) throws -> URL? {
        if let url = current[id], try identity(url) == id { return url }
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               try identity(url) == id { return url }
        }
        let old = URL(fileURLWithPath: entry.path, isDirectory: true)
        return try identity(old) == id ? old : nil
    }

    private func houseArt(_ number: Int) throws -> Artwork {
        if let cached = artwork[number] { return cached }
        let url = assets.appendingPathComponent("cottage-\(number).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Issue.artwork }
        let png: Data
        if image.width == 256, image.height == 256 {
            // Preserve the bundled PNG's palette and compression across every Finder copy.
            png = try Data(contentsOf: url)
        } else {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Issue.artwork }
            let scale = 256 / CGFloat(max(image.width, image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let bounds = CGRect(x: (256 - size.width) / 2, y: (256 - size.height) / 2, width: size.width, height: size.height)
            context.cgContext.interpolationQuality = .high
            context.cgContext.draw(image, in: bounds)
            guard let encoded = bitmap.representation(using: .png, properties: [:]) else { throw Issue.artwork }
            png = encoded
        }

        // Finder's custom folder icon is the 'icns' resource (-16455) of Icon\r.
        // One 256px PNG serves both desktop zoom and Retina without duplicate bitmap sizes.
        func word(_ value: Int) -> Data {
            var encoded = UInt32(value).bigEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        let part = Data("ic08".utf8) + word(8 + png.count) + png
        let family = Data("icns".utf8) + word(8 + part.count) + part
        let payload = word(family.count) + family
        let header = word(256) + word(256 + payload.count) + word(payload.count) + word(50)
        // Resource map: one type at +28, one unnamed resource, no attributes or handles.
        let map = header + Data([0,0,0,0, 0,0, 0,0, 0,28, 0,50, 0,0])
            + Data("icns".utf8) + Data([0,0, 0,10, 0xbf,0xb9, 0xff,0xff, 0,0,0,0, 0,0,0,0])
        let art = Artwork(fork: header + Data(repeating: 0, count: 240) + payload + map,
                          signature: Icon(custom: true, file: digest(Data()) + digest(payload)))
        artwork[number] = art
        return art
    }

    private func writeAttribute(_ name: String, bytes: Data, at url: URL) throws {
        let status = bytes.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        guard status == 0 else { throw posixOr(.icon) }
    }

    private func install(_ art: Artwork, id: String, in folder: URL, replacing before: Icon) throws {
        let temporary = folder.appendingPathComponent(".snowfall-icon-" + UUID().uuidString)
        try Data().write(to: temporary, options: .withoutOverwriting)
        defer { try? files.removeItem(at: temporary) }
        try writeAttribute("com.apple.ResourceFork", bytes: art.fork, at: temporary)
        var hidden = Data(repeating: 0, count: 32)
        hidden[8] = 0x40  // Finder's invisible bit on the icon file, never on the directory.
        try writeAttribute("com.apple.FinderInfo", bytes: hidden, at: temporary)
        guard try identity(folder) == id, try currentIcon(folder) == before else { throw Issue.conflict }
        guard rename(temporary.path, iconFile(folder).path) == 0 else { throw posixOr(.folder) }
        // Notify views caching an older custom icon about the directory itself as well as Icon\r.
        try setFlag(true, on: folder, refresh: true)
        guard try currentIcon(folder) == art.signature else { throw Issue.folder }
        NSWorkspace.shared.noteFileSystemChanged(folder.path)
        NSWorkspace.shared.noteFileSystemChanged(folder.deletingLastPathComponent().path)
    }

    private func variant(for id: String) -> Int {
        if let prior = ledger.variants[id] { return prior }
        var counts = [Int](repeating: 0, count: 7)
        ledger.entries.values.forEach { counts[$0.variant] += 1 }
        let minimum = counts[1...6].min()!
        let choices = (1...6).filter { counts[$0] == minimum }
        return choices[Int(UInt32(id.prefix(8), radix: 16) ?? 0) % choices.count]
    }

    private func iconFile(_ folder: URL) -> URL { folder.appendingPathComponent("Icon\r", isDirectory: false) }
    private func backup(_ id: String) -> URL { copies.appendingPathComponent(id + ".icon", isDirectory: false) }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private func attribute(_ key: String, at url: URL) throws -> Data? {
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw posixOr(.icon)
        }
        guard size > 0 else { return Data() }
        var bytes = Data(count: size)
        let n = bytes.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard n == size else { throw posixOr(.icon) }
        return bytes
    }

    private func currentIcon(_ folder: URL) throws -> Icon {
        let info = try attribute("com.apple.FinderInfo", at: folder)
        let custom = (info.flatMap { $0.count >= 10 ? $0[8] : nil } ?? 0) & 4 != 0
        let file = iconFile(folder)
        var st = stat()
        if lstat(file.path, &st) != 0 {
            guard errno == ENOENT else { throw posixOr(.icon) }
            return Icon(custom: custom, file: nil)
        }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { throw Issue.icon }
        let dataFork = try Data(contentsOf: file, options: .mappedIfSafe)
        let resource = try attribute("com.apple.ResourceFork", at: file) ?? Data()
        // Resource maps contain transient file references even for identical artwork.
        // Hash the complete payload region; the backup retains the *entire* original fork.
        func word(_ offset: Int) -> Int { resource[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
        var payload = resource
        if resource.count >= 16 {
            let start = word(0), length = word(8)
            if start >= 16 && start <= resource.count && length <= resource.count - start {
                payload = resource.subdata(in: start..<start + length)
            }
        }
        return Icon(custom: custom, file: digest(dataFork) + digest(payload))
    }

    private func setFlag(_ custom: Bool, on folder: URL, refresh: Bool = false) throws {
        var bytes = try attribute("com.apple.FinderInfo", at: folder) ?? Data(repeating: 0, count: 32)
        guard bytes.count == 32 else { throw Issue.icon }
        let old = bytes[8]
        bytes[8] = custom ? old | 4 : old & ~4
        if bytes[8] == old && !refresh { return }
        let status = bytes.withUnsafeBytes { setxattr(folder.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
        guard status == 0 else { throw posixOr(.icon) }
    }

    private func copyIcon(_ source: URL, to target: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, target.path, nil, flags) == 0 else { throw posixOr(.icon) }
    }

    private func rawDigest(_ file: URL) throws -> String {
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { throw Issue.icon }
        return digest(try Data(contentsOf: file, options: .mappedIfSafe)) +
            digest(try attribute("com.apple.ResourceFork", at: file) ?? Data()) +
            digest(try attribute("com.apple.FinderInfo", at: file) ?? Data())
    }

    private func remember(_ url: URL, variant: Int, original: Icon, expected: Icon) -> Entry {
        let bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        return Entry(path: url.path, bookmark: bookmark, variant: variant, original: original, expected: expected)
    }

    private func reconcile(_ current: [String: URL]) throws {
        var firstIssue: Error?
        for (id, url) in current.sorted(by: { $0.key < $1.key }) {
            do { try applyOne(id, url: url) }
            catch { if firstIssue == nil { firstIssue = error } }
        }
        // A folder moved off the Desktop gets its original icon back when its own bookmark resolves.
        for (id, entry) in Array(ledger.entries) where current[id] == nil {
            do {
                if let url = try resolve(id: id, entry: entry, current: current) { try undo(id: id, entry: entry, folder: url) }
            } catch { if firstIssue == nil { firstIssue = error } }
        }
        try report(current)
        if let error = firstIssue { throw error }
    }

    private func applyOne(_ id: String, url: URL) throws {
        guard try identity(url) == id else { return }
        let current = try currentIcon(url)
        var entry: Entry
        if var saved = ledger.entries[id] {
            if saved.restoring == true {
                try undo(id: id, entry: saved, folder: url)
                try applyOne(id, url: url)
                return
            }
            if saved.path != url.path {
                saved.path = url.path
                saved.bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                ledger.entries[id] = saved
                try persist()
            }
            if saved.overridden { return }
            let target = try houseArt(saved.variant).signature
            if let installed = saved.installed {
                guard current == installed else {
                    saved.overridden = true
                    ledger.entries[id] = saved
                    try persist()
                    return
                }
                if installed == target { return }
            } else if current == target {
                // The previous process completed the filesystem write before committing its ledger.
                saved.expected = target
                saved.installed = current
                saved.upgradingFrom = nil
                ledger.entries[id] = saved
                try persist()
                return
            } else {
                guard current == saved.original || current == saved.upgradingFrom ||
                      current.file == saved.expected.file else { throw Issue.conflict }
            }
            saved.upgradingFrom = current
            saved.expected = target
            saved.installed = nil
            ledger.entries[id] = saved
            try persist()   // Keep the older managed signature recognizable until the new one is verified.
            entry = saved
        } else {
            guard !current.custom || current.file != nil else { throw Issue.icon }
            let number = variant(for: id)
            let target = try houseArt(number).signature
            var preserved: String?
            if current.file != nil {
                try files.createDirectory(at: copies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let temp = copies.appendingPathComponent(UUID().uuidString + ".tmp")
                defer { try? files.removeItem(at: temp) }
                try copyIcon(iconFile(url), to: temp)
                let copied = try rawDigest(temp)
                guard try rawDigest(iconFile(url)) == copied else { throw Issue.icon }
                preserved = copied
                guard rename(temp.path, backup(id).path) == 0 else { throw posixOr(.registry) }
            }
            entry = remember(url, variant: number, original: current, expected: target)
            entry.backupDigest = preserved
            ledger.entries[id] = entry
            ledger.variants[id] = number
            try persist()     // Record the precise original and expected result before touching Finder.
        }
        let art = try houseArt(entry.variant)
        try install(art, id: id, in: url, replacing: current)
        entry.installed = art.signature
        entry.upgradingFrom = nil
        ledger.entries[id] = entry
        try persist()
    }

    private func undo(id: String, entry: Entry, folder: URL) throws {
        guard try identity(folder) == id else { throw Issue.missing }
        let live = try currentIcon(folder)
        let ours = live == (entry.installed ?? entry.expected) || live == entry.upgradingFrom
        let pendingWrite = entry.installed == nil && live.file == entry.expected.file
        let pendingFlag = entry.restoring == true && live.file == entry.original.file
        if !entry.overridden && live != entry.original && (ours || pendingWrite || pendingFlag) {
            if entry.restoring != true {
                var restoring = entry
                restoring.restoring = true
                ledger.entries[id] = restoring
                try persist()  // A restart can distinguish a restored icon file awaiting its flag.
            }
            if pendingFlag {
                try setFlag(entry.original.custom, on: folder)
            } else if entry.original.file != nil {
                let original = backup(id)
                guard files.fileExists(atPath: original.path) else { throw Issue.registry }
                if let checksum = entry.backupDigest, try rawDigest(original) != checksum { throw Issue.registry }
                let replacement = folder.appendingPathComponent(".snowfall-restore-" + UUID().uuidString)
                defer { try? files.removeItem(at: replacement) }
                try copyIcon(original, to: replacement)
                if let checksum = entry.backupDigest, try rawDigest(replacement) != checksum { throw Issue.icon }
                guard try identity(folder) == id, try currentIcon(folder) == live else { throw Issue.conflict }
                guard rename(replacement.path, iconFile(folder).path) == 0 else { throw posixOr(.folder) }
                try setFlag(entry.original.custom, on: folder)
                NSWorkspace.shared.noteFileSystemChanged(folder.path)
            } else {
                guard NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: []) else { throw Issue.folder }
            }
            guard try currentIcon(folder) == entry.original else { throw Issue.folder }
        } else if !entry.overridden && (entry.installed == nil || entry.restoring == true) && live != entry.original {
            // Ambiguous interrupted write. Keep the backup instead of guessing.
            throw Issue.conflict
        }
        // An icon installed by the visitor after ours wins.
        ledger.entries.removeValue(forKey: id)
        try persist()
        try? files.removeItem(at: backup(id))
    }

    private func report(_ current: [String: URL]) throws {
        var result: [House] = []
        for (id, url) in current {
            guard let entry = ledger.entries[id], !entry.overridden,
                  try currentIcon(url) == (entry.installed ?? entry.expected) else { continue }
            result.append(House(id: id, name: url.lastPathComponent, variant: entry.variant, url: url))
        }
        let sorted = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let changed = eligibleCount != current.count || enabled != ledger.enabled ||
            houses.map(\.id) != sorted.map(\.id) || houses.map(\.name) != sorted.map(\.name)
        eligibleCount = current.count
        houses = sorted
        enabled = ledger.enabled
        if changed { onChange?() }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let fd = open(desktop.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { onError?(posixOr(.folder)); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
    }

    private func scheduleRefresh() {
        changes?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            do { try self.refresh() }
            catch Issue.busy { self.scheduleRefresh() }
            catch { self.onError?(error) }
        }
        changes = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func stopWatching() { changes?.cancel(); changes = nil; watcher?.cancel(); watcher = nil }

    private func posixOr(_ fallback: Issue) -> Issue { errno == EACCES || errno == EPERM ? .denied : fallback }
    private func safe(_ error: Error, fallback: Issue = .folder) -> Issue {
        if let issue = error as? Issue { return issue }
        let detail = error as NSError
        if (detail.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(detail.code)) ||
            (detail.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(detail.code)) {
            return .denied
        }
        if let cause = detail.userInfo[NSUnderlyingErrorKey] as? NSError { return safe(cause, fallback: fallback) }
        return fallback
    }
}
