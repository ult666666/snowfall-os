import AppKit
import CoreGraphics

/// Changes the actual desktop picture only on explicit request. The normal live layer needs no preference change.
@MainActor final class SystemVillagePicture {
    private struct Record: Codable {
        let previousURL: URL
        let previousOptions: Data
    }
    private let files = FileManager.default
    private let workspace = NSWorkspace.shared
    private let directory: URL
    private var ledger: URL { directory.appendingPathComponent("previous.json") }
    private var village: URL { directory.appendingPathComponent("Frostpine Hollow.jpg") }
    private var previousEdition: URL { directory.appendingPathComponent("Frostpine Village.jpg") }

    private func isManagedPicture(_ url: URL) -> Bool {
        same(url, village) || same(url, previousEdition)
    }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.snowfallos.desktop/SystemPicture", isDirectory: true)
    }

    var hasBackup: Bool { files.fileExists(atPath: ledger.path) }

    private func records() throws -> [String:Record] {
        if !hasBackup { return [:] }
        return try JSONDecoder().decode([String:Record].self, from: Data(contentsOf: ledger))
    }

    private func save(_ records: [String:Record]) throws {
        if records.isEmpty {
            if hasBackup { try files.removeItem(at: ledger) }
            return
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: ledger, options: .atomic)
    }

    private func key(_ screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func same(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    private func error(_ text: String) -> NSError {
        NSError(domain:"Snowfall.SystemPicture",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }

    func apply(scene: URL) throws -> Int {
        var saved = try records()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw error("No display is available.") }
        // Save all original URLs and display options before changing any screen.
        for screen in screens {
            guard let id = key(screen), let before = workspace.desktopImageURL(for: screen),
                  before.isFileURL, files.fileExists(atPath: before.path) else {
                throw error("The previous wallpaper could not be saved. The live village is still available.")
            }
            if isManagedPicture(before) {
                guard saved[id] != nil else { throw error("The previous picture for this display is unavailable.") }
                continue
            }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            let dictionary = Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) })
            let archive = try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: true)
            saved[id] = Record(previousURL: before, previousOptions: archive)
        }
        let data = try Data(contentsOf: scene)
        guard NSImage(data: data) != nil else { throw error("The village picture could not be opened.") }
        try save(saved)
        let changed = !files.contentsEqual(atPath: scene.path, andPath: village.path)
        if changed { try data.write(to: village, options: .atomic) }
        var count = 0
        for screen in screens {
            if changed || !same(workspace.desktopImageURL(for: screen),village) {
                try workspace.setDesktopImageURL(village, for: screen, options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                    .allowClipping: true
                ])
            }
            count += 1
        }
        return count
    }

    func restore() throws -> Int {
        var saved = try records()
        var count = 0
        for screen in NSScreen.screens {
            guard let id = key(screen), let record = saved[id] else { continue }
            guard let current = workspace.desktopImageURL(for: screen) else {
                throw error("macOS could not report this display’s current wallpaper. Try restoring again.")
            }
            // Respect a newer picture chosen outside Snowfall.
            if isManagedPicture(current) {
                guard files.fileExists(atPath: record.previousURL.path) else {
                    throw error("The previous picture is unavailable. Its saved reference has been kept.")
                }
                var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
                let allowed: [AnyClass] = [NSDictionary.self,NSString.self,NSNumber.self,NSColor.self,NSColorSpace.self,
                                           NSData.self,NSArray.self]
                guard let dictionary = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowed, from: record.previousOptions) as? [String:Any] else {
                    throw error("The previous picture’s saved display options could not be read.")
                }
                for (key, value) in dictionary { options[NSWorkspace.DesktopImageOptionKey(rawValue: key)] = value }
                try workspace.setDesktopImageURL(record.previousURL, for: screen, options: options)
                count += 1
            }
            saved.removeValue(forKey:id)
            try save(saved)
        }
        return count
    }
}
