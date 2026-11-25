import AppKit

/// Keeps Finder paths in the native process. The local preview receives opaque IDs.
@MainActor final class HouseRooms: NSObject {
    let model: FolderVillage
    let menu = NSMenu(title: "Folder Houses")
    var openPicker: (() -> Void)?
    var openRoom: ((String) -> Void)?
    var sendState: (([String: Any]) -> Void)?
    var showError: ((String) -> Void)?
    var openDirectory: (URL) -> Void = { url in
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: .init(), completionHandler: nil)
    }

    private var lastError: String?
    private var updating = false

    init(desktop: URL? = nil, storage: URL? = nil, assets: URL) {
        model = FolderVillage(desktop: desktop, storage: storage, assets: assets)
        super.init()
        menu.autoenablesItems = false
        rebuildMenu()
        model.onChange = { [weak self] in
            guard let self = self, !self.updating else { return }
            self.lastError = nil
            self.publish()
        }
        model.onError = { [weak self] error in self?.record(error) }
    }

    var state: [String: Any] {
        let houses: [[String: Any]] = model.houses.map { ["id": $0.id, "name": $0.name, "variant": $0.variant] }
        var result: [String: Any] = ["enabled": model.enabled, "houses": houses]
        if let lastError = lastError { result["error"] = lastError }
        return result
    }

    static func safeMessage(_ error: Error) -> String {
        var current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let problem = current else { break }
            if (problem.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(problem.code)) ||
                (problem.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(problem.code)) {
                return "macOS denied access. Allow Snowfall OS to access the Desktop folder in Privacy & Security → Files & Folders, then try again."
            }
            current = problem.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        return "Snowfall OS could not update the folder houses. Check that the Desktop and its folders are available and writable, then try again."
    }

    func start(applyRequested: Bool) {
        if applyRequested { apply(nil) }
        else if model.enabled { perform({ try model.refresh() }, alertOnFailure: true) }
    }

    func list() {
        if lastError != nil { perform({ try model.inspect() }, alertOnFailure: false) }
        else { sendState?(state) }
    }

    // The picker can request a fresh view of styled folders. Fresh installs
    // stay opt-in and never enumerate the Desktop merely to draw the menu.
    @objc func pick(_ sender: Any?) {
        if model.enabled { perform({ try model.inspect() }, alertOnFailure: false) }
        openPicker?()
    }

    @objc func apply(_ sender: Any?) { perform({ try model.apply() }, alertOnFailure: true) }
    @objc func restore(_ sender: Any?) { perform({ try model.restore() }, alertOnFailure: true) }

    func openFolder(id: String) {
        guard let house = model.houses.first(where: { $0.id == id }), model.currentHouse(at: house.url)?.id == id else { return }
        openDirectory(house.url)
    }

    @objc(openHouseWidgets:userData:error:)
    func openHouseWidgets(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count == 1, let id = model.currentHouse(at: urls[0])?.id else {
            error.pointee = "Select one styled Desktop folder to open its house widgets."
            return
        }
        openRoom?(id)
    }

    @objc private func chooseRoom(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let house = model.houses.first(where: { $0.id == id }),
              model.currentHouse(at: house.url)?.id == id else { return }
        openRoom?(id)
    }

    private func perform(_ work: () throws -> Void, alertOnFailure: Bool) {
        updating = true
        defer { updating = false }
        do { try work(); lastError = nil; publish() }
        catch { record(error, alert: alertOnFailure) }
    }

    private func record(_ error: Error, alert: Bool = false) {
        let text = Self.safeMessage(error)
        lastError = text
        publish()
        if alert { showError?(text) }
    }

    private func publish() {
        rebuildMenu()
        sendState?(state)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        @discardableResult func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        add("Style Desktop Folders as Houses", #selector(apply(_:))).state = model.enabled ? .on : .off
        add("Restore Original Folder Icons", #selector(restore(_:)))
        menu.addItem(.separator())
        add("Open a House…", #selector(pick(_:)))
        if !model.houses.isEmpty {
            let rooms = NSMenu(title: "House Rooms")
            let entry = menu.addItem(withTitle: "House Rooms", action: nil, keyEquivalent: "")
            entry.submenu = rooms
            for house in model.houses {
                let room = rooms.addItem(withTitle: house.name, action: #selector(chooseRoom(_:)), keyEquivalent: "")
                room.target = self
                room.representedObject = house.id
            }
        }
    }

    /// This CLI reads current Finder state and emits only aggregate counts.
    static func printStatus(assets: URL) -> Int32 {
        let model = FolderVillage(assets: assets)
        var output: [String: Any] = [:]
        var code: Int32 = 0
        do {
            try model.inspect()
            output = ["enabled": model.enabled, "styled": model.houses.count, "eligible": model.eligibleCount]
        } catch {
            output = ["enabled": model.enabled, "error": safeMessage(error)]
            code = 1
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print(json) }
        return code
    }
}
