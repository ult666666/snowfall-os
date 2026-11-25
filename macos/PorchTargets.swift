import AppKit

/// Real native buttons at the cottage doors. They sit above Finder's icons,
/// below widgets and regular windows, and never activate the wallpaper app.
@MainActor final class PorchTargets {
    typealias Plot = DesktopHouseInteraction.Plot
    struct Letter: Equatable {
        let id: String
        let name: String
    }
    enum Civic: Equatable {
        case postOffice([Letter])
        case clock
    }
    struct Door: Equatable {
        let plot: Plot
        let drawHouse: Bool
        let folder: URL?
        let title: String
        var civic: Civic?
        var paintedBounds: CGRect?

        var target: CGRect {
            if let paintedBounds { return paintedBounds }
            let s = plot.size
            return CGRect(x: plot.center.x - s / 2, y: plot.center.y - s / 2, width: s, height: s)
        }
    }
    var ambientEnabled = true {
        didSet {
            if !ambientEnabled { for (_, panel) in windows.values { panel.button.clearGlint() } }
        }
    }
    private var lastGlint: TimeInterval = -.infinity
    var onTap: ((Plot) -> Void)?
    var onOpen: ((String) -> Void)?
    var onRoom: ((String) -> Void)?
    var onOffice: (() -> Void)?
    var onLetter: ((String) -> Void)?
    var onClock: (() -> Void)?
    var onHover: ((CGDirectDisplayID, String?) -> Void)?
    private var windows: [String: (Door, DoorPanel)] = [:]
    var count: Int { windows.count }
    var occupiedFrames: [CGRect] { windows.values.map { $0.1.frame } }
    var onVisibility: (() -> Void)?
    private(set) var finderDisplays = Set<CGDirectDisplayID>()
    private(set) var displayedPlots: [Plot] = []
    var composedCount: Int { displayedPlots.filter { !finderDisplays.contains($0.display) }.count }
    var unplacedCount: Int { max(0, houses.count - displayedPlots.count) }
    var civicCount: Int { windows.values.filter { $0.0.civic != nil }.count }
    var letterCount: Int {
        windows.values.reduce(0) { count, entry in
            if case let .postOffice(letters) = entry.0.civic { return count + letters.count }
            return count
        }
    }
    private var watch: Timer?
    private var spaceToken: NSObjectProtocol?
    private var appToken: NSObjectProtocol?
    private var plots: [Plot] = []
    private var houses: [String: FolderVillage.House] = [:]
    private var showScenery = true
    private var renderedDisplays = Set<CGDirectDisplayID>()
    var plan: VillageComposition?
    private var widgets: [NSNumber: WidgetFrames.Frames] = [:]
    private var letters: [Letter] = []
    private var addresses = UserDefaults.standard.dictionary(forKey: "VillageParcelAddresses") as? [String: Int] ?? [:]

    func configure(plots: [Plot], houses: [FolderVillage.House], scenery: Bool,
                   widgets: [NSNumber: WidgetFrames.Frames], files: [[String: String]]) {
        self.plots = plots
        self.houses = Dictionary(houses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = addresses
        addresses = addresses.filter { self.houses[$0.key] != nil && $0.value >= 0 }
        var allAddresses = Set(addresses.values), next = 0
        for id in self.houses.keys.sorted() where addresses[id] == nil {
            while allAddresses.contains(next) { next += 1 }
            addresses[id] = next
            allAddresses.insert(next)
        }
        if addresses != previous { UserDefaults.standard.set(addresses, forKey: "VillageParcelAddresses") }
        showScenery = scenery
        self.widgets = widgets
        letters = files.prefix(2).compactMap { item in
            guard let id = item["id"], let name = item["name"] else { return nil }
            return Letter(id: id, name: name)
        }
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
        let screens: [(id: CGDirectDisplayID, frame: CGRect, usable: CGRect)] = NSScreen.screens.compactMap {
            guard let n = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let frame = CGDisplayBounds(n.uint32Value)
            let visible = $0.visibleFrame
            let usable = CGRect(x: frame.minX + visible.minX - $0.frame.minX,
                                y: frame.minY + $0.frame.maxY - visible.maxY,
                                width: visible.width, height: visible.height)
            return (n.uint32Value, frame, usable)
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
        let previousPlots = displayedPlots
        let changed = visible != finderDisplays
        finderDisplays = visible
        renderedDisplays = all
        var doors: [Door] = []
        let assignments = Dictionary(plots.map { ($0.id, $0.display) }, uniquingKeysWith: { first, _ in first })
        let primary = screens.first?.id
        displayedPlots = []
        for screen in screens {
            let widgetRects = (widgets[NSNumber(value: screen.id)] ?? []).compactMap { spec -> CGRect? in
                guard let x = spec["x"], let y = spec["y"], let w = spec["width"], let h = spec["height"] else { return nil }
                return CGRect(x: screen.frame.minX + x * screen.frame.width, y: screen.frame.minY + y * screen.frame.height,
                              width: w * screen.frame.width, height: h * screen.frame.height)
            }
            let finderDraws = visible.contains(screen.id)
            let layout: [Plot]
            if !finderDraws, let plan {
                let ids = houses.keys.filter { (assignments[$0] ?? primary) == screen.id }
                layout = plan.plots(ids: ids, display: screen.id, frame: screen.frame, usable: screen.usable,
                                    widgets: widgetRects, preferred: addresses)
            } else {
                layout = plots.filter { $0.display == screen.id && houses[$0.id] != nil }
            }
            displayedPlots.append(contentsOf: layout)
            doors += layout.compactMap { plot in
                guard let folder = houses[plot.id],
                      !finderDraws || !widgetRects.contains(where: { $0.contains(plot.center) }) else { return nil }
                return Door(plot: plot, drawHouse: !finderDraws, folder: folder.url, title: folder.name)
            }
            guard showScenery, let plan else { continue }
            let art = VillageComposition.Projection(screen.frame, width: plan.width, height: plan.height)
            func civic(_ key: String, _ title: String, _ kind: Civic, _ rect: CGRect) {
                // Only the visible painted building can accept clicks. Native modules take precedence.
                guard screen.usable.contains(rect), !widgetRects.contains(where: { $0.intersects(rect) }),
                      !doors.contains(where: { $0.target.intersects(rect) }) else { return }
                let plot = Plot(id: "scenery-\(key)-\(screen.id)", center: CGPoint(x: rect.midX, y: rect.midY),
                                size: rect.width, display: screen.id, frame: screen.frame)
                doors.append(Door(plot: plot, drawHouse: false, folder: nil, title: title, civic: kind, paintedBounds: rect))
            }
            civic("office", "Village post office", .postOffice(letters), art.postOffice)
            civic("clock", "Village clock", .clock, art.clockFace)
        }
        update(doors)
        if changed || previousPlots != displayedPlots { onVisibility?() }
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
            button.allowGlint = { [weak self] in
                guard let self, self.ambientEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastGlint > 2.8 else { return false }
                self.lastGlint = now
                return true
            }
            button.onTap = { [weak self] in
                switch door.civic {
                case .postOffice: self?.onOffice?()
                case .clock: self?.onClock?()
                case nil: self?.onTap?(door.plot)
                }
            }
            button.onOpen = { [weak self] in self?.onOpen?(id) }
            button.onRoom = { [weak self] in self?.onRoom?(id) }
            button.onHover = { [weak self] entered in
                if door.drawHouse { self?.onHover?(door.plot.display, entered ? id : nil) }
            }
            button.onLetter = { [weak self] id in self?.onLetter?(id) }
            button.setAccessibilityLabel(door.title)
            button.setAccessibilityHelp(door.folder != nil ? "Click to play catch. Double-click to open the folder." :
                                        door.civic == .clock ? "Open Clock." : "Browse files on the Desktop.")
            panel.setFrame(rect, display: false)
            button.configureLetters()
            panel.orderFrontRegardless()
            windows[id] = (door, panel)
        }
    }

    /// Returns an anonymous point and window ID for a physical native test.
    /// Prefer a real folder door that is exposed on this Space.
    func testPoint(office: Bool = false) -> [String: Any] {
        let candidates = windows.values.filter { entry in
            guard entry.1.isVisible else { return false }
            if case .postOffice = entry.0.civic { return office }
            return !office && entry.0.folder != nil
        }
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

    static func checkLetterRouting() -> Bool {
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: 160, height: 134)
        let panel = DoorPanel()
        defer { panel.retire() }
        panel.setFrame(rect, display: false)
        let button = panel.button
        let plot = Plot(id: "office", center: CGPoint(x: 80, y: 67), size: 160, display: 1, frame: rect)
        let letters = [Letter(id: "a", name: "Picture"), Letter(id: "b", name: "Document")]
        button.door = Door(plot: plot, drawHouse: false, folder: nil, title: "", civic: .postOffice(letters), paintedBounds: rect)
        var opened: [String] = []
        button.onLetter = { opened.append($0) }
        button.configureLetters()
        for x in [0.29, 0.73] {
            guard let paper = button.hitTest(CGPoint(x: rect.width * x, y: rect.height * 0.21)) as? NSButton else { return false }
            paper.performClick(nil)
        }
        return opened == ["a", "b"] && button.hitTest(CGPoint(x: rect.midX, y: rect.midY)) === button
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
            backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 0.018)
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
        var onHover: ((Bool) -> Void)?
        var onLetter: ((String) -> Void)?
        var allowGlint: (() -> Bool)?
        private var tracking: NSTrackingArea?
        private var glint: CAGradientLayer?
        private var lastGlint: TimeInterval = -.infinity
        private var delayed: DispatchWorkItem?
        private var pressed: CGPoint?
        private var paperButtons: [NSButton] = []
        override init(frame: NSRect) {
            super.init(frame:frame)
            wantsLayer = true
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityHelp("Click to exchange snowballs. Double-click a folder cottage to open its files.")
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect:.zero, options:[.inVisibleRect,.mouseEnteredAndExited,.activeAlways], owner:self, userInfo:nil)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) {
            guard let door, door.folder != nil, let layer, NSEvent.pressedMouseButtons == 0 else { return }
            onHover?(true)
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastGlint > 9, allowGlint?() == true else { return }
            lastGlint = now
            clearGlint()
            // This little side window occurs on every house design. Its warm light
            // blooms at the pane and fades back into the original painted glass.
            let s = door.plot.size
            let glow = CAGradientLayer()
            glow.name = "CottageWindowLight"
            glow.type = .radial
            glow.startPoint = CGPoint(x:0.5, y:0.5)
            glow.endPoint = CGPoint(x:1, y:1)
            let light = NSColor(calibratedRed:1, green:0.78, blue:0.38, alpha:1)
            glow.colors = [light.withAlphaComponent(0.86).cgColor, light.withAlphaComponent(0.32).cgColor,
                           light.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.38, 1]
            let x = bounds.midX + s * (door.folder == nil ? 0.12 : 0.20)
            let y = bounds.maxY - s * (door.folder == nil ? 0.55 : 0.61)
            glow.frame = CGRect(x:x-s*0.14,y:y-s*0.15,width:s*0.28,height:s*0.30)
            glow.opacity = 0
            layer.addSublayer(glow)
            glint = glow
            let pulse = CAKeyframeAnimation(keyPath:"opacity")
            pulse.values = [0, 0.85, 0.5, 0]
            pulse.keyTimes = [0, 0.24, 0.53, 1]
            pulse.duration = 1.35
            glow.add(pulse, forKey:"lantern")
        }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        func configureLetters() {
            paperButtons.forEach { $0.removeFromSuperview() }
            paperButtons = []
            guard case let .postOffice(letters) = door?.civic else { return }
            for (index, letter) in letters.enumerated() {
                let button = NSButton(title: "", target: self, action: #selector(openLetter(_:)))
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.isTransparent = true
                button.identifier = NSUserInterfaceItemIdentifier(letter.id)
                button.setAccessibilityLabel("Open " + letter.name)
                button.toolTip = letter.name
                let x = index == 0 ? 0.29 : 0.73
                button.frame = CGRect(x: bounds.width * (x - 0.155), y: bounds.height * 0.09,
                                      width: bounds.width * 0.31, height: bounds.height * 0.24)
                addSubview(button)
                paperButtons.append(button)
            }
        }
        @objc private func openLetter(_ sender: NSButton) {
            if let id = sender.identifier?.rawValue { onLetter?(id) }
        }
        func clearGlint() { glint?.removeFromSuperlayer(); glint = nil }
        override func accessibilityPerformPress() -> Bool { cancel(); onTap?(); return true }
        override func mouseDown(with event: NSEvent) {
            delayed?.cancel(); delayed = nil
            if event.clickCount > 1 {
                pressed = nil
                if event.clickCount == 2 {
                    if door?.folder != nil { onOpen?() } else { onTap?() }
                }
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
            if door?.civic != nil { onTap?(); return }
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
            if let civic = door?.civic {
                add(civic == .clock ? "Open Clock" : "Browse Desktop Files", #selector(play))
            } else { add("Play Snowballs", #selector(play)) }
            if door?.folder != nil {
                add("Open Folder in Finder", #selector(open))
                add("Open House Widgets", #selector(room))
            }
            NSMenu.popUpContextMenu(menu, with:event, for:self)
        }
        @objc private func play() { onTap?() }
        @objc private func open() { onOpen?() }
        @objc private func room() { onRoom?() }
        func cancel() { delayed?.cancel(); delayed = nil; pressed = nil; clearGlint() }
    }
}
