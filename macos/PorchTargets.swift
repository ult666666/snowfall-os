import AppKit

/// Real native buttons at the cottage doors. They sit above Finder's icons,
/// below widgets and regular windows, and never activate the wallpaper app.
@MainActor final class PorchTargets {
    typealias Plot = DesktopHouseInteraction.Plot
    struct Door: Equatable {
        let plot: Plot
        let drawHouse: Bool
        let folder: URL?
        let title: String

        var target: CGRect {
            let s = plot.size
            let width = s * (drawHouse ? 1 : 0.72)
            let height = s * (drawHouse ? 1 : 0.72)
            return CGRect(x: plot.center.x - width / 2, y: plot.center.y - height / 2 + (drawHouse ? 0 : s * 0.05),
                          width: width, height: height)
        }
    }
    var onTap: ((Plot) -> Void)?
    var onOpen: ((String) -> Void)?
    var onRoom: ((String) -> Void)?
    private var windows: [String: (Door, DoorPanel)] = [:]
    var count: Int { windows.count }
    var onVisibility: (() -> Void)?
    private(set) var finderDisplays = Set<CGDirectDisplayID>()
    private var watch: Timer?
    private var spaceToken: NSObjectProtocol?
    private var appToken: NSObjectProtocol?
    private var plots: [Plot] = []
    private var houses: [String: FolderVillage.House] = [:]
    private var showScenery = true
    private var renderedDisplays = Set<CGDirectDisplayID>()

    func configure(plots: [Plot], houses: [FolderVillage.House], scenery: Bool) {
        self.plots = plots
        self.houses = Dictionary(houses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        showScenery = scenery
        if watch == nil {
            // A Space switch or Show Desktop can hide Finder's icon layer even
            // while the wallpaper and Mac folders themselves remain available.
            let bus = NSWorkspace.shared.notificationCenter
            let change: @Sendable (Notification) -> Void = { [weak self] _ in
                Task { @MainActor in self?.refreshVisibility(force: false) }
            }
            spaceToken = bus.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main,using:change)
            appToken = bus.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main,using:change)
            let timer = Timer(timeInterval:0.9,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.refreshVisibility(force:false) }
            }
            timer.tolerance = 0.12
            RunLoop.main.add(timer, forMode:.common)
            watch = timer
        }
        refreshVisibility(force:true)
    }

    func stop() {
        if let spaceToken { NSWorkspace.shared.notificationCenter.removeObserver(spaceToken) }
        if let appToken { NSWorkspace.shared.notificationCenter.removeObserver(appToken) }
        spaceToken = nil; appToken = nil
        watch?.invalidate(); watch = nil
        update([])
    }

    private func refreshVisibility(force: Bool) {
        let screens: [(id: CGDirectDisplayID, frame: CGRect)] = NSScreen.screens.compactMap {
            guard let n = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, CGDisplayBounds(n.uint32Value))
        }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first?.processIdentifier
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        var visible = Set<CGDirectDisplayID>()
        for row in rows {
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == iconLevel,
                  let box = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation:box as CFDictionary),
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01 else { continue }
            for screen in screens where bounds.contains(CGPoint(x:screen.frame.midX,y:screen.frame.midY)) { visible.insert(screen.id) }
        }
        let all = Set(screens.map { $0.id })
        guard force || visible != finderDisplays || all != renderedDisplays else { return }
        let changed = visible != finderDisplays
        finderDisplays = visible
        renderedDisplays = all
        var doors = plots.compactMap { plot -> Door? in
            guard let folder = houses[plot.id] else { return nil }
            return Door(plot:plot, drawHouse:!visible.contains(plot.display), folder:folder.url, title:folder.name)
        }
        if showScenery {
            for screen in screens where !visible.contains(screen.id) {
                for plot in ScenicCottages.plots(for:screen.id, frame:screen.frame) {
                    let door = Door(plot:plot, drawHouse:true, folder:nil, title:"village")
                    if !doors.contains(where: { $0.target.intersects(door.target) }) { doors.append(door) }
                }
            }
        }
        update(doors)
        if changed { onVisibility?() }
    }

    func update(_ doors: [Door]) {
        let incoming = Set(doors.map { $0.plot.id })
        for id in Array(windows.keys) where !incoming.contains(id) {
            if let removed = windows.removeValue(forKey: id) { removed.1.retire() }
        }
        let screens = NSScreen.screens
        for door in doors {
            let id = door.plot.id
            guard windows[id]?.0 != door,
                  let screen = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == door.plot.display })
                  else { continue }
            let target = door.target, display = door.plot.frame
            let sx = screen.frame.width / display.width, sy = screen.frame.height / display.height
            let rect = CGRect(x: screen.frame.minX + (target.minX - display.minX) * sx,
                              y: screen.frame.maxY - (target.maxY - display.minY) * sy,
                              width: target.width * sx, height: target.height * sy)
            let panel = windows[id]?.1 ?? DoorPanel()
            let button = panel.button
            button.door = door
            button.onTap = { [weak self] in self?.onTap?(door.plot) }
            button.onOpen = { [weak self] in self?.onOpen?(id) }
            button.onRoom = { [weak self] in self?.onRoom?(id) }
            button.setAccessibilityLabel("Play catch at a cottage")
            panel.setFrame(rect, display: false)
            panel.orderFrontRegardless()
            windows[id] = (door, panel)
        }
    }

    /// Returns an anonymous point and window ID for a physical native test.
    /// Prefer a real folder door that is exposed on this Space.
    func testPoint() -> [String: Any] {
        let candidates = windows.values.filter { $0.0.folder != nil && $0.1.isVisible }
        guard !candidates.isEmpty else { return [:] }
        let stack = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        func exposed(_ entry: (Door, DoorPanel)) -> Bool {
            let pt = CGPoint(x:entry.0.target.midX,y:entry.0.target.midY)
            let number = entry.1.windowNumber
            for row in stack {
                guard let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation:bounds as CFDictionary), rect.contains(pt),
                      let n = (row[kCGWindowNumber as String] as? NSNumber)?.intValue,
                      (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.001 else { continue }
                if n == number { return true }
                if let window = NSApp.window(withWindowNumber:n), window.ignoresMouseEvents { continue }
                return false
            }
            return false
        }
        let hit = candidates.first(where:exposed) ?? candidates[0]
        return ["x": Int(hit.0.target.midX), "y": Int(hit.0.target.midY), "window": hit.1.windowNumber, "exposed": exposed(hit)]
    }

    private final class DoorPanel: NSPanel {
        let button = DoorButton(frame:.zero)
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            title = "Cottage door"
            isOpaque = false
            // Fully transparent pixels are click-through on macOS. A faint tint
            // keeps the actual painted door receptive without a visible tile.
            backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 0.03)
            hasShadow = false
            canHide = false
            hidesOnDeactivate = false
            isReleasedWhenClosed = false
            isExcludedFromWindowsMenu = true
            isMovable = false
            animationBehavior = .none
            contentView = button
        }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        func retire() { button.cancel(); orderOut(nil); close() }
    }

    private final class DoorButton: NSView, NSDraggingSource {
        var door: Door?
        var onTap: (() -> Void)?
        var onOpen: (() -> Void)?
        var onRoom: (() -> Void)?
        private var delayed: DispatchWorkItem?
        private var pressed: CGPoint?
        override init(frame: NSRect) {
            super.init(frame:frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityHelp("Click to exchange snowballs. Double-click a folder cottage to open its files.")
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func accessibilityPerformPress() -> Bool { cancel(); onTap?(); return true }
        override func mouseDown(with event: NSEvent) {
            delayed?.cancel(); delayed = nil
            if event.clickCount > 1 {
                pressed = nil
                if door?.folder != nil { onOpen?() } else { onTap?() }
            } else { pressed = convert(event.locationInWindow, from:nil) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = pressed else { return }
            let pt = convert(event.locationInWindow, from:nil)
            guard hypot(pt.x - start.x, pt.y - start.y) > 4 else { return }
            pressed = nil
            guard let url = door?.folder else { return }
            let item = NSDraggingItem(pasteboardWriter:url as NSURL)
            item.setDraggingFrame(bounds, contents:NSWorkspace.shared.icon(forFile:url.path))
            beginDraggingSession(with:[item], event:event, source:self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .move, .link]
        }
        override func mouseUp(with event: NSEvent) {
            guard pressed != nil else { return }
            pressed = nil
            guard bounds.contains(convert(event.locationInWindow, from:nil)) else { return }
            let job = DispatchWorkItem { [weak self] in self?.onTap?() }
            delayed = job
            DispatchQueue.main.asyncAfter(deadline:.now() + NSEvent.doubleClickInterval, execute:job)
        }
        override func rightMouseDown(with event: NSEvent) {
            cancel()
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector) {
                let item = menu.addItem(withTitle:title, action:action, keyEquivalent:""); item.target = self
            }
            add("Play Snowballs", #selector(play))
            if door?.folder != nil {
                add("Open Folder in Finder", #selector(open))
                add("Open House Widgets", #selector(room))
            }
            NSMenu.popUpContextMenu(menu, with:event, for:self)
        }
        @objc private func play() { onTap?() }
        @objc private func open() { onOpen?() }
        @objc private func room() { onRoom?() }
        func cancel() { delayed?.cancel(); delayed = nil; pressed = nil }
    }
}
