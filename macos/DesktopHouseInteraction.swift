import AppKit
import Carbon

/// Clicks go to Finder. Snowfall only decorates a completed single click within
/// a known house on Finder's desktop surface; it creates no input windows.
@MainActor final class DesktopHouseInteraction {
    struct Plot: Equatable {
        let id: String
        let center: CGPoint       // Quartz global points, origin at the upper left
        let size: CGFloat
        let display: CGDirectDisplayID
        let frame: CGRect

        var payload: [String: Any] {
            ["id": id, "x": (center.x - frame.minX) / frame.width,
             "y": min(1, (center.y + size * 0.38 - frame.minY) / frame.height), "size": size]
        }
        func contains(_ pt: CGPoint) -> Bool {
            CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size).contains(pt)
        }
    }

    struct Gesture {
        private(set) var down: (plot: Plot, point: CGPoint)?
        mutating func begin(_ plot: Plot?, at point: CGPoint, single: Bool, desktop: Bool) {
            down = nil
            if let plot, single, desktop, plot.contains(point) { down = (plot, point) }
        }
        mutating func moved(to point: CGPoint) {
            if let down, hypot(point.x - down.point.x, point.y - down.point.y) > 4 { self.down = nil }
        }
        mutating func end(at point: CGPoint, single: Bool, desktop: Bool) -> Plot? {
            moved(to: point)
            defer { down = nil }
            guard let down, single, desktop, down.plot.contains(point) else { return nil }
            return down.plot
        }
    }

    var onLayout: (() -> Void)?
    var onTap: ((Plot) -> Void)?
    private(set) var plots: [Plot] = []
    private(set) var size: CGFloat = 64
    private var names: [String: String] = [:]
    private var gesture = Gesture()
    private var pending: DispatchWorkItem?
    private var observer: Any?
    var observing: Bool { observer != nil }
    private var timer: Timer?
    private var fileEvents: DispatchSourceFileSystemObject?
    private var dragged: (plot: Plot, start: CGPoint)?
    private var waitingForWrite: String?
    private var lastStamp: Date?
    private var lastBytes = -1
    private var lastMode = ""
    private let finder = UserDefaults(suiteName: "com.apple.finder")
    private let store = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(".DS_Store")

    func setHouses(_ houses: [FolderVillage.House], observe: Bool = true) {
        let next = Dictionary(uniqueKeysWithValues: houses.map { ($0.name, $0.id) })
        if !observe { names = next; refresh(force: true); return }
        if next == names, observer != nil { return }
        names = next
        if next.isEmpty { stop(); return }
        refresh(force: true)
        watchStore()
        guard observer == nil else { return }
        // A mouse-only monitor needs no keyboard or Accessibility permission and
        // cannot suppress, modify, synthesize, or redirect Finder's events.
        observer = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
        let watch = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        watch.tolerance = 0.75
        RunLoop.main.add(watch, forMode: .common)
        timer = watch
    }

    func stop() {
        if let observer { NSEvent.removeMonitor(observer) }
        observer = nil
        timer?.invalidate(); timer = nil
        fileEvents?.cancel(); fileEvents = nil
        dragged = nil; waitingForWrite = nil
        pending?.cancel(); pending = nil
        gesture = Gesture()
        names = [:]
        update([])
    }

    private func watchStore() {
        guard fileEvents == nil, !names.isEmpty else { return }
        let fd = open(store.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete], queue: .main)
        watcher.setCancelHandler { close(fd) }
        watcher.setEventHandler { [weak self] in
            guard let self, let source = self.fileEvents else { return }
            if !source.data.intersection([.rename, .delete]).isEmpty {
                source.cancel(); self.fileEvents = nil
            }
            self.refresh()
            self.watchStore()
        }
        fileEvents = watcher
        watcher.resume()
    }

    func refresh(force: Bool = false, checkFinder: Bool = false) {
        guard !names.isEmpty else { update([]); return }
        let desktop = finder?.dictionary(forKey: "DesktopViewSettings")
        let settings = desktop?["IconViewSettings"] as? [String: Any]
        let iconSize = CGFloat((settings?["iconSize"] as? NSNumber)?.doubleValue ?? 64)
        let arrangement = settings?["arrangeBy"] as? String ?? "none"
        let groups = desktop?["GroupBy"] as? String ?? "None"
        let screens: [(id: CGDirectDisplayID, frame: CGRect)] = NSScreen.screens.compactMap {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, CGDisplayBounds(number.uint32Value))
        }
        guard (16...256).contains(iconSize), !screens.isEmpty, groups.lowercased() == "none" else { update([]); lastMode = ""; return }
        let attr = try? FileManager.default.attributesOfItem(atPath: store.path)
        let stamp = attr?[.modificationDate] as? Date, bytes = (attr?[.size] as? NSNumber)?.intValue ?? 0
        let mode = "\(groups)/\(arrangement)/\(screens.map { "\($0.id):\($0.frame)" })"
        if observeStoreNeedsRetry { watchStore() }
        let layoutChanged = stamp != lastStamp || bytes != lastBytes || mode != lastMode
        if layoutChanged { waitingForWrite = nil }
        if !force, !layoutChanged, iconSize == size { return }
        lastStamp = stamp; lastBytes = bytes; size = iconSize; lastMode = mode
        var centers: [String: CGPoint] = [:]
        if screens.count == 1, ["none", "grid"].contains(arrangement.lowercased()), bytes > 0, bytes <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: store, options: .mappedIfSafe) {
            centers = FinderLayout.points(in: data, for: Set(names.keys), screen: screens[0].frame.size)
        }
        // Finder is authoritative for arranged layouts, multi-display desktops
        // and future file formats, but we only contact it with existing consent.
        if checkFinder || centers.count != names.count, let verified = Self.authorizedFinderPositions() {
            centers = verified
            waitingForWrite = nil
        }
        let new = names.compactMap { name, id -> Plot? in
            guard id != waitingForWrite, let center = centers[name], let screen = screens.first(where: { $0.frame.contains(center) }) else { return nil }
            return Plot(id: id, center: center, size: iconSize, display: screen.id, frame: screen.frame)
        }.sorted { $0.id < $1.id }
        update(new)
    }

    private var observeStoreNeedsRetry: Bool { observer != nil && fileEvents == nil }

    static func authorizedFinderPositions() -> [String: CGPoint]? {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else { return nil }
        let source = """
        with timeout of 1 second
            tell application id "com.apple.finder" to get {name, desktop position} of every item of desktop
        end timeout
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let names = result.atIndex(1), let points = result.atIndex(2),
              names.numberOfItems == points.numberOfItems else { return nil }
        guard names.numberOfItems > 0 else { return [:] }
        var output: [String: CGPoint] = [:]
        for i in 1...names.numberOfItems {
            guard let name = names.atIndex(i)?.stringValue, let pair = points.atIndex(i),
                  let list = pair.coerce(toDescriptorType: typeAEList),
                  let x = list.atIndex(1), let y = list.atIndex(2) else { continue }
            output[name] = CGPoint(x: Int(x.int32Value), y: Int(y.int32Value))
        }
        return output
    }

    private func update(_ next: [Plot]) {
        guard next != plots else { return }
        plots = next
        onLayout?()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown { pending?.cancel(); pending = nil; dragged = nil }
        if gesture.down == nil, dragged == nil, event.type != .leftMouseDown { return }
        guard let cg = event.cgEvent else { gesture = Gesture(); dragged = nil; return }
        let point = cg.location
        if event.type == .leftMouseDragged {
            let initial = gesture.down
            gesture.moved(to: point)
            if let initial, gesture.down == nil {
                dragged = (initial.plot, initial.point)
                waitingForWrite = initial.plot.id
                update(plots.filter { $0.id != initial.plot.id })
            }
            return
        }
        if event.type == .leftMouseUp, let drag = dragged {
            dragged = nil
            if drag.plot.contains(point) { waitingForWrite = nil }
            refresh(force: true, checkFinder: true)
            return
        }
        let single = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        if event.type == .leftMouseDown {
            let plot = single ? plots.first(where: { $0.contains(point) }) : nil
            gesture.begin(plot, at: point, single: single, desktop: plot != nil && Self.isFinderDesktop(event, at: point))
        } else if event.type == .leftMouseUp {
            guard let plot = gesture.end(at: point, single: single, desktop: Self.isFinderDesktop(event, at: point)) else { return }
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.plots.contains(plot) else { return }
                self.onTap?(plot)
            }
            pending = task
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: task)
        }
    }

    private static func isFinderDesktop(_ event: NSEvent, at point: CGPoint) -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier else { return false }
        let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))
        let cg = event.cgEvent
        let receiving = cg?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
        // Quartz supplies the window that can actually handle the click,
        // including clicks through Snowfall's transparent overlays.
        for number in [receiving, Int64(event.windowNumber)] where number > 0 && number <= Int64(UInt32.max) {
            guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
                  let row = rows.first else { continue }
            if (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
                return (row[kCGWindowLayer as String] as? NSNumber)?.intValue == desktop
            }
            // A click-through overlay may be the AppKit window-under-pointer.
            if number == receiving { return false }
        }
        let recipient = cg?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
        if recipient > 0 && recipient != Int64(pid) { return false }
        if recipient == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return false }
        // On versions that omit the destination, require a visible Finder
        // desktop surface at this point. Skip only our own fully click-through
        // background/effects; ordinary overlapping windows cover the house.
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows {
            guard let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let level = (w[kCGWindowLayer as String] as? NSNumber)?.intValue, level >= desktop,
                  (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            if owner == ProcessInfo.processInfo.processIdentifier,
               let n = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
               NSApp.window(withWindowNumber: n)?.ignoresMouseEvents == true { continue }
            if recipient == Int64(pid), owner != pid { continue }
            return owner == pid && level == desktop
        }
        return false
    }

    static let statusRequest = Notification.Name("com.snowfallos.desktop.requestPorchStatus")
    static let statusReply = Notification.Name("com.snowfallos.desktop.porchStatus")

    /// An opt-in command-line check of the running wallpaper. No coordinates,
    /// house IDs, names, interaction times, or counters are written to disk.
    static func printSessionStatus(hitPoint: Bool = false, office: Bool = false, playground: String? = nil, ground: CGPoint? = nil) -> Int32 {
        let bus = DistributedNotificationCenter.default(), id = UUID().uuidString
        var answer: String?
        let observer = bus.addObserver(forName: statusReply, object: id, queue: .main) { note in
            guard let info = note.userInfo else { return }
            let keys = hitPoint ? ["x","y","window","exposed","passiveExposed"] :
                ["observing","animatedClicks","located","nativeTargets","localClicks","finderDrawing","feedbackVisible",
                 "composedFolders","unplacedFolders","widgets","files","letterTargets","civicTargets","deskVisible",
                 "playgroundTargets","playgroundInputs","playgroundStage","playgroundThrows","playgroundDodges","playgroundPasses",
                 "playgroundMode","playgroundIncoming","groundObserving","groundFinderMapped","groundPassiveInputs","groundInputs","groundActive","groundSnowmen","groundFight","groundShots","groundReturns"]
            var filtered: [String: NSNumber] = [:]
            for name in keys { if let value = info[name] as? NSNumber { filtered[name] = value } }
            if !filtered.isEmpty, let bytes = try? JSONSerialization.data(withJSONObject:filtered,options:[.sortedKeys]) {
                answer = String(data:bytes,encoding:.utf8)
            }
        }
        defer { bus.removeObserver(observer) }
        var request: [String:Any] = ["hitPoint":hitPoint,"office":office]
        if let playground { request["playground"] = playground }
        if let ground { request["groundX"] = ground.x; request["groundY"] = ground.y }
        bus.postNotificationName(statusRequest, object:id, userInfo:request, deliverImmediately:true)
        let end = Date(timeIntervalSinceNow: 2)
        while answer == nil, end.timeIntervalSinceNow > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04)) }
        print(answer ?? "{\"error\":\"Running wallpaper did not respond\"}")
        return answer == nil ? 1 : 0
    }

    static func checkGestures() -> Bool {
        let pt = CGPoint(x: -70, y: 140)
        let plot = Plot(id: "fixture", center: pt, size: 64, display: 2, frame: CGRect(x: -1440, y: -100, width: 1440, height: 900))
        var g = Gesture()
        g.begin(plot, at: pt, single: true, desktop: true)
        guard g.end(at: pt, single: true, desktop: true) == plot else { return false }
        g.begin(plot, at: pt, single: false, desktop: true)
        guard g.end(at: pt, single: false, desktop: true) == nil else { return false }
        g.begin(plot, at: pt, single: true, desktop: true)
        g.moved(to: CGPoint(x: pt.x + 22, y: pt.y - 1))
        guard g.end(at: pt, single: true, desktop: true) == nil else { return false }
        g.begin(plot, at: pt, single: true, desktop: false)
        guard g.end(at: pt, single: true, desktop: true) == nil else { return false }
        g.begin(plot, at: pt, single: true, desktop: true)
        return g.end(at: pt, single: true, desktop: false) == nil
    }
}
