import AppKit
import WebKit
import UniformTypeIdentifiers

private let appName = "Snowfall OS"
private let freeSnowCheck = CommandLine.arguments.contains("--check-free-snow") || CommandLine.arguments.contains("--check-playground")
private let smokeTest = CommandLine.arguments.contains("--smoke-test") || freeSnowCheck
private let snowPreference = "SnowOnAppWindows"
private let framesPreference = "FrameDesktopWidgets"

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private enum Route: String { case scene, yard, tools, houses }

@MainActor
private final class CabinApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    private struct Background {
        let window: WallpaperWindow
        let view: WKWebView
        var ready = false
        var pendingActions: [String] = []
        var villageSignature: Data?
        var paintedCottages = 0
    }
    private var backgrounds: [NSNumber: Background] = [:]
    private var preview: NSWindow?
    private var previewView: WKWebView?
    private var previewReady = false
    private var previewGroundKey: String?
    private var previewResize: DispatchWorkItem?
    private var desiredRoute: Route = .scene
    private var routeRevision = 0
    private var desiredHouseID: String?
    private var rooms: HouseRooms!
    private let porches = DesktopHouseInteraction()
    private var animatedPorchClicks = 0
    private var localPorchClicks = 0
    private let doors = PorchTargets()
    private let ground = GroundInteraction()
    private var groundStates: [NSNumber: [String:Any]] = [:]
    private var groundClock: Timer?
    private let postOffice = VillagePostOffice()
    private var hasFileIndex = false
    private var mailRequestedWhileLoading = false
    private var ending = false
    private var pendingPictures: [NSNumber: DispatchWorkItem] = [:]
    private lazy var doorstep = DoorstepFeedback(assets:webRoot.appendingPathComponent("assets", isDirectory:true))
    private var regularFrame: NSRect?
    private var smokeOpenedFolders = 0
    private var status: NSStatusItem!
    private var snowOption: NSMenuItem!
    private var frameOption: NSMenuItem!
    private var cachedFrames: [NSNumber: [[String: Double]]] = [:]
    private lazy var widgetFrames = WidgetFrames { [weak self] id, rectangles in
        self?.setWidgetFrames(rectangles, display: NSNumber(value: id))
    }
    private let picture = WallpaperImage(temporary: smokeTest)
    private lazy var systemPicture = SystemVillagePicture()
    private var alpineChoice: NSMenuItem!
    private var imageRevision = 0
    private var picker: NSOpenPanel?
    private var webRoot: URL!
    private lazy var snow = WindowSnow()
    private let store: WKWebsiteDataStore = smokeTest ? .nonPersistent() : .default()
    private var clockPulse: Timer?
    private var smokeDeadline: Timer?
    private var smokeBegan = false
    private var smokeBridgeReceived = false
    private var failing = false
    // Wait for the local scene to report its saved snowfall setting on launch.
    private var webEffectsEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Desktop", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            fail("The bundled cabin scene is missing.")
            return
        }
        webRoot = root.standardizedFileURL
        do { doors.plan = try VillageComposition.load(from: webRoot.appendingPathComponent("assets/village-plan.json")) }
        catch { fail("The bundled village street plan could not be read."); return }
        UserDefaults.standard.register(defaults: [snowPreference: true, framesPreference: true])
        do { try setUpRooms() }
        catch { fail("Could not initialize the folder houses."); return }
        installMenus()
        porches.onLayout = { [weak self] in self?.syncPorchTargets() }
        porches.onTap = { [weak self] plot in
            guard let self, self.doors.finderDisplays.contains(plot.display) else { return }
            self.playAtDoor(plot)
        }
        doors.onVisibility = { [weak self] in self?.sendAllPlots() }
        doorstep.occupiedDoorFrames = { [weak self] in self?.doors.occupiedFrames ?? [] }
        ground.canReadDesktop = { [weak self] in self?.rooms.model.enabled == true && self?.rooms.canCompose == true }
        ground.surfaces = { [weak self] in self?.groundSurfaces() ?? [] }
        ground.onInput = { [weak self] id, phase, point, heldSeconds in
            guard let surface = self?.backgrounds[id], surface.ready else { return }
            var input: [String:Any] = ["phase":phase,"x":point.x,"y":point.y]
            if let heldSeconds { input["heldMs"] = heldSeconds * 1000 }
            surface.view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-ground-input',{detail:input}));",
                arguments:["input":input],in:nil,in:.page)
        }
        if !smokeTest { ground.start() }
        doors.onTap = { [weak self] plot in
            self?.localPorchClicks += 1
            self?.playAtDoor(plot)
        }
        doors.onOpen = { [weak self] id in
            self?.doorstep.dismiss()
            self?.rooms.openFolder(id:id)
        }
        doors.onRoom = { [weak self] id in self?.show(.houses, houseID:id) }
        doors.onClock = { [weak self] in self?.openNativeApp("clock") }
        doors.onOffice = { [weak self] in self?.showPostOffice(nil) }
        doors.onLetter = { [weak self] id in self?.postOffice.openItem(id: id) }
        doors.onHover = { [weak self] display, id in
            guard let surface = self?.backgrounds[NSNumber(value: display)], surface.ready else { return }
            surface.view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-house-hover', {detail:{id}}));",
                arguments: ["id": id as Any? ?? NSNull()], in: nil, in: .page)
        }
        postOffice.onChange = { [weak self] in
            guard let self else { return }
            self.syncPorchTargets()
            if self.previewReady, let view = self.previewView { self.sendFiles(to: view) }
        }
        if !smokeTest {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(reportPorchStatus(_:)),
                                                               name: DesktopHouseInteraction.statusRequest, object: nil)
        }
        NSApp.servicesProvider = rooms
        rooms.start(applyRequested: !smokeTest && CommandLine.arguments.contains("--apply-houses"))
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applySnowPreference),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        applySnowPreference()
        if smokeTest {
            smokeDeadline = Timer.scheduledTimer(timeInterval: 55, target: self, selector: #selector(smokeTimeout), userInfo: nil, repeats: false)
        }
        syncScreens()
        if !smokeTest {
            syncPorchTargets()
            // WebKit may mark a desktop-level view hidden while its artwork is visible.
            // One native minute boundary updates every display, including after sleep.
            let minute = floor(Date().timeIntervalSince1970 / 60) + 1
            let clock = Timer(fireAt:Date(timeIntervalSince1970:minute * 60 + 0.06), interval:60,
                              target:self, selector:#selector(pulseClock(_:)), userInfo:nil, repeats:true)
            clock.tolerance = 0.25
            RunLoop.main.add(clock,forMode:.common)
            clockPulse = clock
            NSWorkspace.shared.notificationCenter.addObserver(self, selector:#selector(pulseClock(_:)),
                name:NSWorkspace.didWakeNotification, object:nil)
        }
        applyFramePreference()
        if !smokeTest && CommandLine.arguments.contains("--set-village-wallpaper") { setVillagePicture(nil) }
        if !smokeTest && (CommandLine.arguments.contains("--open-village") ||
            !CommandLine.arguments.contains(where: { ["--wallpaper-only", "--set-village-wallpaper", "--apply-houses"].contains($0) })) {
            show(.scene)
        }
    }

    @objc private func pulseClock(_ sender: Any?) {
        for surface in backgrounds.values where surface.ready {
            surface.view.evaluateJavaScript("window.dispatchEvent(new Event('snowfall-clock-tick'));")
        }
    }

    private func setUpRooms() throws {
        let assets = webRoot.appendingPathComponent("assets/houses", isDirectory: true)
        if smokeTest {
            let desktop = picture.directory.appendingPathComponent("FixtureDesktop", isDirectory: true)
            let storage = picture.directory.appendingPathComponent("FixtureRegistry", isDirectory: true)
            let fixture = desktop.appendingPathComponent("Example Cottage", isDirectory: true)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            rooms = HouseRooms(desktop: desktop, storage: storage, assets: assets)
            rooms.openDirectory = { [weak self] url in
                if url.standardizedFileURL.path == fixture.standardizedFileURL.path { self?.smokeOpenedFolders += 1 }
                else { self?.fail("A folder request escaped the smoke fixture.") }
            }
        } else {
            rooms = HouseRooms(assets: assets)
        }
        rooms.openPicker = { [weak self] in self?.show(.houses) }
        rooms.openRoom = { [weak self] id in self?.show(.houses, houseID: id) }
        rooms.sendState = { [weak self] state in
            guard let self else { return }
            if !smokeTest {
                if self.rooms.model.enabled && self.rooms.canCompose { self.startFileIndex() }
                if self.mailRequestedWhileLoading && !self.rooms.waitingForAccess {
                    self.mailRequestedWhileLoading = false
                    if state["error"] == nil { self.showPostOffice(nil) }
                    else if let message = state["error"] as? String { self.tellUser(message) }
                }
                self.porches.setHouses(self.rooms.model.houses)
                self.syncPorchTargets()
            }
            self.populatePlayableVillage()
            guard let view = self.previewView, self.previewReady else { return }
            view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-houses', {detail: state}));",
                                     arguments: ["state": state], in: nil, in: .page)
        }
        rooms.showError = { [weak self] text in
            if smokeTest { self?.fail(text) } else { self?.tellUser(text) }
        }
    }

    private func installMenus() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            if let icon = NSImage(systemSymbolName: "snowflake", accessibilityDescription: appName) {
                icon.isTemplate = true
                button.image = icon
            } else { button.title = "❄" }
            button.toolTip = appName
        }
        let actions = NSMenu()
        actions.addItem(item("Open Playable Village", #selector(returnToPreview(_:)), target: self))
        actions.addItem(.separator())
        actions.addItem(item("Play in Snow", #selector(play(_:)), target: self))
        actions.addItem(item("Roll a Snowball", #selector(rollSnow(_:)), target: self))
        actions.addItem(item("Send the Snowplow", #selector(sendPlow(_:)), target: self))
        actions.addItem(item("Tools", #selector(tools(_:)), target: self))
        let houseLink = actions.addItem(withTitle: "Folder Houses", action: nil, keyEquivalent: "")
        houseLink.submenu = rooms.menu
        actions.addItem(item("Village Post Office…", #selector(showPostOffice(_:)), target: self))
        actions.addItem(.separator())
        actions.addItem(item("Use as Live Wallpaper", #selector(useWallpaper(_:)), target: self))
        snowOption = item("Snow on App Windows", #selector(toggleSnow(_:)), target: self)
        actions.addItem(snowOption)
        frameOption = item("Frame Desktop Widgets", #selector(toggleFrames(_:)), target: self)
        actions.addItem(frameOption)
        let images = submenu("Wallpaper Image", in: actions)
        alpineChoice = item("Storybook Village", #selector(restoreAlpine(_:)), target: self)
        alpineChoice.state = picture.dataURL == nil ? .on : .off
        images.addItem(alpineChoice)
        images.addItem(item("Choose Image…", #selector(chooseImage(_:)), target: self))
        images.addItem(.separator())
        images.addItem(item("Set Village as Mac Wallpaper", #selector(setVillagePicture(_:)), target: self))
        images.addItem(item("Restore Previous Mac Wallpaper and Quit", #selector(restoreSystemPicture(_:)), target: self))
        actions.addItem(.separator())
        let nativeApps = submenu("Open Mac App", in: actions)
        for (label, command) in [("Notes", "notes"), ("Music", "music"), ("Clock", "clock")] {
            let entry = item(label, #selector(openNativeAppFromMenu(_:)), target: self)
            entry.representedObject = command
            nativeApps.addItem(entry)
        }
        actions.addItem(.separator())
        actions.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        status.menu = actions

        let bar = NSMenu()
        let app = submenu(appName, in: bar)
        app.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        let edit = submenu("Edit", in: bar)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
                                    ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            if title == "Cut" { edit.addItem(.separator()) }
            edit.addItem(item(title, NSSelectorFromString(action), key))
        }
        let view = submenu("View", in: bar)
        view.addItem(item("Play in Snow", #selector(play(_:)), target: self))
        view.addItem(item("Tools", #selector(tools(_:)), target: self))
        view.addItem(item("Open a House…", #selector(HouseRooms.pick(_:)), target: rooms))
        view.addItem(item("Open Playable Village", #selector(returnToPreview(_:)), target: self))
        view.addItem(item("Use as Live Wallpaper", #selector(useWallpaper(_:)), target: self))
        view.addItem(.separator())
        view.addItem(item("Toggle Full Screen", #selector(toggleFullscreen(_:)), "f", [.command, .control], target: self))
        let window = submenu("Window", in: bar)
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        NSApp.windowsMenu = window
        NSApp.mainMenu = bar
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = target
        return entry
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let child = NSMenu(title: title)
        let link = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        link.submenu = child
        parent.addItem(link)
        return child
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(restoreSystemPicture(_:)) { return !smokeTest && systemPicture.hasBackup }
        return true
    }

    @objc private func setVillagePicture(_ sender: Any?) {
        guard !smokeTest else { return }
        do {
            _ = try systemPicture.apply(scene: webRoot.appendingPathComponent("assets/scene.jpg"))
            imageRevision += 1
            try picture.restoreAlpine()
            publishImage()
        } catch { tellUser(error.localizedDescription) }
    }

    @objc private func restoreSystemPicture(_ sender: Any?) {
        guard !smokeTest, systemPicture.hasBackup else { return }
        do { _ = try systemPicture.restore(); NSApp.terminate(nil) }
        catch { tellUser(error.localizedDescription) }
    }

    @objc private func chooseImage(_ sender: Any?) {
        if let picker = picker { picker.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose Wallpaper Image"
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        picker = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self = self else { return }
            self.picker = nil
            guard response == .OK, let url = panel?.url else { return }
            self.imageRevision += 1
            let revision = self.imageRevision
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try WallpaperImage.convert(url) }
                DispatchQueue.main.async {
                    guard self.imageRevision == revision else { return }
                    do {
                        let bytes = try result.get()
                        try self.picture.save(bytes)
                        self.publishImage()
                    } catch { self.tellUser(error.localizedDescription) }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = preview { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    @objc private func restoreAlpine(_ sender: Any?) {
        imageRevision += 1
        do { try picture.restoreAlpine(); publishImage() }
        catch { if smokeTest { fail(error.localizedDescription) } else { tellUser(error.localizedDescription) } }
    }

    private func sendImage(to view: WKWebView, completion: (@MainActor @Sendable (Result<Any, Error>) -> Void)? = nil) {
        let detail: Any = picture.dataURL as Any? ?? NSNull()
        let script = """
        window.dispatchEvent(new CustomEvent('snowfall-image', {detail: value}));
        await window.snowfallImageReady;
        const scene = document.querySelector('#wallpaper');
        if (scene) await scene.decode();
        """
        view.callAsyncJavaScript(script, arguments: ["value": detail], in: nil, in: .page, completionHandler: completion)
    }

    private func publishImage() {
        for id in Array(backgrounds.keys) { backgrounds[id]?.villageSignature = nil }
        if !smokeTest { syncPorchTargets() }
        alpineChoice.state = picture.dataURL == nil ? .on : .off
        imageRevision += 1
        for background in backgrounds.values { sendImage(to: background.view) }
        if let view = previewView { sendImage(to: view) }
    }

    @objc private func toggleSnow(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: snowPreference), forKey: snowPreference)
        applySnowPreference()
    }

    @objc private func applySnowPreference() {
        let movement = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let chosen = UserDefaults.standard.bool(forKey: snowPreference)
        snowOption.state = chosen ? .on : .off
        snowOption.toolTip = !movement ? "Paused while Reduce Motion is enabled in macOS."
            : !webEffectsEnabled ? "Paused by your cabin snowfall settings." : nil
        doors.ambientEnabled = movement && webEffectsEnabled
        doorstep.reduceMotion = !movement || !webEffectsEnabled
        snow.setEnabled(!smokeTest && chosen && movement && webEffectsEnabled)
    }

    @objc private func toggleFrames(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: framesPreference), forKey: framesPreference)
        applyFramePreference()
    }

    private func applyFramePreference() {
        let enabled = UserDefaults.standard.bool(forKey: framesPreference)
        frameOption.state = enabled ? .on : .off
        if !smokeTest {
            widgetFrames.start()
            widgetFrames.refresh()
        } else {
            cachedFrames.removeAll()
        }
        for (id, surface) in backgrounds where surface.ready { sendWidgetFrames(cachedFrames[id] ?? [], to: surface.view) }
        if !smokeTest { sendAllPlots() }
    }

    private func setWidgetFrames(_ frames: [[String: Double]], display: NSNumber) {
        let changed = cachedFrames[display] != frames
        cachedFrames[display] = frames
        if changed && !smokeTest { syncPorchTargets() }
        if let background = backgrounds[display], background.ready { sendWidgetFrames(frames, to: background.view) }
    }

    private func sendWidgetFrames(_ frames: [[String: Double]], to view: WKWebView) {
        view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-widget-frames', {detail: frames}));",
                                 arguments: ["frames": UserDefaults.standard.bool(forKey: framesPreference) || smokeTest ? frames : []], in: nil, in: .page)
    }

    private func playAtDoor(_ plot: DesktopHouseInteraction.Plot) {
        if doorstep.tap(plot) { animatedPorchClicks += 1 }
    }

    private func syncPorchTargets() {
        guard !ending else { return }
        doors.configure(plots: porches.plots, houses: rooms.model.houses, scenery: picture.dataURL == nil,
                        widgets: cachedFrames, files: villageFiles)
        sendAllPlots()
    }

    private func startFileIndex() {
        guard !hasFileIndex, !smokeTest else { return }
        hasFileIndex = true
        postOffice.start()
    }

    @objc private func showPostOffice(_ sender: Any?) {
        guard !smokeTest else { return }
        if rooms.waitingForAccess { mailRequestedWhileLoading = true; return }
        startFileIndex()
        postOffice.showDesk()
    }

    private var villageFiles: [[String: String]] {
        let entries = postOffice.items
        func opensDocument(_ entry: [String: String]) -> Bool {
            entry["kind"] == "document" || entry["kind"] == "image"
        }
        return entries.filter(opensDocument) + entries.filter { !opensDocument($0) }
    }

    private func sendFiles(to view: WKWebView) {
        let script = "window.postOfficeItems = items; window.composePostOffice?.(items);"
        view.callAsyncJavaScript(script, arguments: ["items": villageFiles], in: nil, in: .page)
    }

    private func sendAllPlots() {
        for (id, surface) in backgrounds where surface.ready { sendPlots(display:id, to:surface.view) }
    }

    private func sendPlots(display: NSNumber, to view: WKWebView) {
        if !smokeTest || freeSnowCheck { ground.syncReceivers(testing:smokeTest) }
        let drawHouse = !doors.finderDisplays.contains(display.uint32Value)
        let plots = doors.displayedPlots.filter { $0.display == display.uint32Value }.compactMap { plot -> [String: Any]? in
            guard let house = rooms.model.houses.first(where: { $0.id == plot.id }) else { return nil }
            var payload = plot.payload
            payload["drawHouse"] = drawHouse
            payload["name"] = house.name
            payload["variant"] = house.variant
            return payload
        }
        let files = villageFiles
        let widgetSkin = UserDefaults.standard.bool(forKey: framesPreference) ? cachedFrames[display] ?? [] : []
        let snapshot: [String: Any] = ["houses": plots, "files": files, "widgetFrames": widgetSkin, "inventoryReady": rooms.canCompose]
        let signature = try? JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys)
        if let signature, backgrounds[display]?.villageSignature == signature { return }
        backgrounds[display]?.villageSignature = signature
        backgrounds[display]?.paintedCottages = 0
        let paint = """
        window.dispatchEvent(new CustomEvent('snowfall-house-plots', {detail: plots}));
        const cottages = Array.from(document.querySelectorAll('#wallpaper-cottages .wallpaper-cottage'));
        const visible = await Promise.all(cottages.map(async node => {
          const image = node.querySelector('img'), name = node.querySelector('.address-lettering');
          if (!image || !name?.textContent.trim()) return false;
          try { await image.decode(); } catch { return false; }
          return image.naturalWidth > 0 && image.getBoundingClientRect().height > 0 &&
                 name.getBoundingClientRect().width > 0;
        }));
        return visible.filter(Boolean).length;
        """
        view.callAsyncJavaScript(paint, arguments: ["plots": plots], in: nil, in: .page) { [weak self, weak view] result in
            guard let self, let current = self.backgrounds[display], current.view === view,
                  current.villageSignature == signature, case .success(let count) = result else { return }
            self.backgrounds[display]?.paintedCottages = count as? Int ?? 0
        }
        sendFiles(to: view)
        pendingPictures.removeValue(forKey: display)?.cancel()
        guard !smokeTest, rooms.canCompose, picture.dataURL == nil, systemPicture.hasBackup else { return }
        let kinds = villageFiles.compactMap { $0["kind"] }
        let update = DispatchWorkItem { [weak self] in
            guard let self, let screen = NSScreen.screens.first(where: { self.screenID($0) == display }) else { return }
            self.pendingPictures.removeValue(forKey: display)
            do { try self.systemPicture.refreshComposition(on: screen, scene: self.webRoot.appendingPathComponent("assets/scene.jpg"),
                                                           plots: plots, postKinds: kinds, widgetFrames: widgetSkin) }
            catch { NSLog("The offline village picture could not be updated.") }
        }
        pendingPictures[display] = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: update)
    }

    private func sendPorchTap(_ plot: DesktopHouseInteraction.Plot, to view: WKWebView) {
        let script = """
        window.dispatchEvent(new CustomEvent('snowfall-house-tap', {detail: plot}));
        return Boolean(document.querySelector('.porch-flurry'));
        """
        view.callAsyncJavaScript(script, arguments: ["plot": plot.payload], in: nil, in: .page) { [weak self] result in
            if !smokeTest, case .success(let rendered) = result, rendered as? Bool == true { self?.animatedPorchClicks += 1 }
        }
    }

    private func groundSurfaces() -> [GroundInteraction.Surface] {
        guard picture.dataURL == nil else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let id = screenID(screen), backgrounds[id]?.ready == true,
                  groundStates[id]?["groundActive"] as? Bool == true else { return nil }
            let full = CGDisplayBounds(id.uint32Value), cocoa = screen.frame
            func quartz(_ r: CGRect) -> CGRect {
                CGRect(x:full.minX+(r.minX-cocoa.minX)*full.width/cocoa.width,
                       y:full.minY+(cocoa.maxY-r.maxY)*full.height/cocoa.height,
                       width:r.width*full.width/cocoa.width,height:r.height*full.height/cocoa.height)
            }
            var blocked = doors.occupiedFrames.filter(cocoa.intersects).map(quartz)
            blocked += (cachedFrames[id] ?? []).compactMap { r in
                guard let x=r["x"], let y=r["y"], let w=r["width"], let h=r["height"] else { return nil }
                return CGRect(x:full.minX+x*full.width,y:full.minY+y*full.height,width:w*full.width,height:h*full.height)
            }
            return GroundInteraction.Surface(id:id,frame:full,usable:quartz(screen.visibleFrame),
                finderVisible:doors.finderDisplays.contains(id.uint32Value),blocked:blocked)
        }
    }

    private func groundClockActive(_ display: NSNumber) -> Bool {
        let state = groundStates[display]
        return state?["holding"] as? Bool == true || state?["fightActive"] as? Bool == true
    }
    private func syncGroundClock() {
        let playing = backgrounds.keys.contains(where:groundClockActive)
        if !playing {
            groundClock?.invalidate()
            groundClock = nil
        } else if groundClock == nil {
            // WebKit throttles a partly covered wallpaper. Keep time while a
            // snowman is being packed or Flurry is returning a throw.
            let timer = Timer(timeInterval:0.1, repeats:true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for (display,surface) in self.backgrounds where surface.ready && self.groundClockActive(display) {
                        surface.view.evaluateJavaScript("window.dispatchEvent(new Event('snowfall-ground-clock'));",completionHandler:nil)
                    }
                    self.syncGroundClock()
                }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer,forMode:.common)
            groundClock = timer
        }
    }

    @objc private func reportPorchStatus(_ note: Notification) {
        guard let id = note.object as? String, UUID(uuidString: id) != nil else { return }
        let data: [String: Any]
        if let x = note.userInfo?["groundX"] as? Double, let y = note.userInfo?["groundY"] as? Double {
            data = ground.hitPoint(CGPoint(x:x,y:y))
        } else if note.userInfo?["playground"] != nil { data = ["window":0,"exposed":false] }
        else if note.userInfo?["hitPoint"] as? Bool == true { data = doors.testPoint(office: note.userInfo?["office"] as? Bool == true) }
        else {
            let display = activeScreen.flatMap(screenID) ?? backgrounds.keys.first ?? 0
            let free = groundStates[display] ?? [:]
            data = ["groundFinderMapped":ground.finderMapped,"groundPassiveInputs":ground.passiveInputs,"groundObserving":ground.observing,"groundInputs":ground.gestures,"groundActive":free["groundActive"] as? Bool ?? false,
                    "groundSnowmen":free["snowmen"] as? Int ?? 0,"groundFight":free["fightActive"] as? Bool ?? false,
                    "groundShots":free["shots"] as? Int ?? 0,"groundReturns":free["returns"] as? Int ?? 0,"playgroundTargets":0,
                       "observing":porches.observing, "located":doors.displayedPlots.count, "animatedClicks":animatedPorchClicks,
                       "nativeTargets":doors.count, "localClicks":localPorchClicks,
                       "composedFolders":doors.composedCount, "unplacedFolders":doors.unplacedCount,
                       "paintedCottages":backgrounds.values.reduce(0) { $0 + $1.paintedCottages },
                       "widgets":cachedFrames.values.reduce(0) { $0 + $1.count }, "files":postOffice.items.count,
                       "letterTargets":doors.letterCount, "civicTargets":doors.civicCount, "deskVisible":postOffice.deskIsVisible,
                       "finderDrawing":doors.finderDisplays.count, "feedbackVisible":doorstep.isVisible] }
        DistributedNotificationCenter.default().postNotificationName(DesktopHouseInteraction.statusReply, object:id,
                                                                   userInfo:data, deliverImmediately:true)
    }

    private func groundDisplayKey(_ display: NSNumber?) -> String {
        let number = display?.uint32Value ?? CGMainDisplayID()
        return CGDisplayCreateUUIDFromDisplayID(number).map {
            CFUUIDCreateString(nil,$0.takeRetainedValue()) as String
        } ?? String(number)
    }

    private func makeView(surface: String, display: NSNumber? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let controller = config.userContentController
        controller.add(self, name: "snowfallWindow")
        let groundKey = groundDisplayKey(display)
        var startup = """
        window.snowfallNative = true;
        window.snowfallSupportsDesktopWidgets = \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 ? "true" : "false");
        window.snowfallSurface = '\(surface)';
        window.snowfallGroundDisplay = '\(groundKey)';
        const markSurface = () => document.documentElement?.setAttribute('data-surface', window.snowfallSurface);
        if (document.documentElement) markSurface();
        else {
          const rootObserver = new MutationObserver(() => {
            if (document.documentElement) { markSurface(); rootObserver.disconnect(); }
          });
          rootObserver.observe(document, {childList: true});
        }
        """
        if smokeTest {
            startup += """
            ;window.__cabinRoutes = []; window.__cabinActions = []; window.__houseState = null;
            window.addEventListener('snowfall-houses', event => window.__houseState = event.detail);
            window.addEventListener('snowfall-widget-frames', event => window.__widgetFrames = event.detail);
            window.addEventListener('snowfall-action', event => window.__cabinActions.push(event.detail));
            window.addEventListener('snowfall-open', event => window.__cabinRoutes.push(event.detail));
            """
        }
        controller.addUserScript(WKUserScript(source: "(() => {\(startup)})();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.underPageBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.23, alpha: 1)
        return view
    }

    private func load(_ view: WKWebView) {
        view.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
    }

    private func stop(_ view: WKWebView) {
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "snowfallWindow")
        view.stopLoading()
        view.removeFromSuperview()
    }

    private func screenID(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func syncScreens() {
        let live = Set(NSScreen.screens.compactMap(screenID))
        for id in Array(backgrounds.keys) where !live.contains(id) {
            ground.cancel()
            groundStates.removeValue(forKey:id)
            ground.setFighting(false, display:id)
            if let dropped = backgrounds.removeValue(forKey: id) {
                stop(dropped.view)
                dropped.window.close()
            }
        }
        for screen in NSScreen.screens {
            guard let id = screenID(screen) else { continue }
            if let existing = backgrounds[id] {
                existing.window.setFrame(screen.frame, display: true)
                if !smokeTest || freeSnowCheck { ground.syncReceivers(testing:smokeTest) }
                continue
            }
            let window = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.canHide = false
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.setFrame(screen.frame, display: false)
            if smokeTest { window.alphaValue = 0 }
            let view = makeView(surface: "wallpaper", display:id)
            window.contentView = view
            backgrounds[id] = Background(window: window, view: view)
            load(view)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if webRoot != nil {
            syncScreens()
            if !smokeTest { doorstep.dismiss(); porches.refresh(force:true); syncPorchTargets() }
            if !smokeTest { widgetFrames.refresh() }
        }
    }

    private var activeScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    @objc private func rollSnow(_ sender: Any?) { performWallpaperAction("roll") }
    @objc private func sendPlow(_ sender: Any?) { performWallpaperAction("plow") }
    private func performWallpaperAction(_ action: String) {
        guard let screen = activeScreen, let id = screenID(screen), let background = backgrounds[id] else { return }
        if background.ready { send(action, to: background.view) }
        else if background.pendingActions.count < 6 { backgrounds[id]?.pendingActions.append(action) }
    }

    private func send(_ action: String, to view: WKWebView) {
        view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-action', {detail: action}));",
                                 arguments: ["action": action], in: nil, in: .page)
    }

    @objc private func play(_ sender: Any?) { show(.yard) }
    @objc private func tools(_ sender: Any?) { show(.tools) }
    @objc private func returnToPreview(_ sender: Any?) { show(.scene) }
    @objc private func useWallpaper(_ sender: Any?) { preview?.close() }
    @objc private func toggleFullscreen(_ sender: Any?) { preview?.toggleFullScreen(sender) }

    private func show(_ route: Route, houseID: String? = nil) {
        routeRevision += 1
        desiredRoute = route
        desiredHouseID = houseID
        if preview != nil {
            if previewReady { routePreview() }
            return
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0, width: min(1280, visible.width * 0.92), height: min(810, visible.height * 0.91))
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Frostpine Hollow"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 390, height: 475)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        if !smokeTest { _ = window.setFrameUsingName("SnowfallPreview") }
        let view = makeView(surface: "preview", display:window.screen.flatMap(screenID))
        window.contentView = view
        preview = window
        previewView = view
        previewReady = false
        load(view)
    }

    /// The window uses real folder identities and the same street addresses as the desktop.
    /// Re-project from the artwork into the window, whose aspect ratio can differ from the display.
    private func populatePlayableVillage() {
        guard previewReady, desiredRoute == .scene, let view = previewView, let plan = doors.plan else { return }
        let frame = CGRect(origin:.zero,size:view.bounds.size)
        guard frame.width > 0, frame.height > 0 else { return }
        let folders = Dictionary(uniqueKeysWithValues:rooms.model.houses.map { ($0.id,$0) })
        let plots = plan.plots(ids:Array(folders.keys), display:0, frame:frame, usable:frame, widgets:[], preferred:doors.addresses)
        let ink: [[String:Any]] = plots.compactMap { plot in
            guard let folder = folders[plot.id] else { return nil }
            var entry = plot.payload
            entry["name"] = folder.name
            entry["variant"] = folder.variant
            entry["drawHouse"] = true
            return entry
        }
        view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-house-plots', {detail: plots}));",
                                 arguments:["plots":ink], in:nil, in:.page)
    }

    private func syncPreviewGroundDisplay() {
        guard previewReady, let view = previewView, let screen = preview?.screen,
              let id = screenID(screen) else { return }
        let key = groundDisplayKey(id)
        guard previewGroundKey != key else { return }
        previewGroundKey = key
        view.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('snowfall-ground-display',{detail:key}));",
            arguments:["key":key],in:nil,in:.page)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if notification.object as? NSWindow === preview { syncPreviewGroundDisplay() }
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === preview else { return }
        previewResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.populatePlayableVillage() }
        previewResize = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.08,execute:work)
    }

    private func routePreview() {
        guard let window = preview, let view = previewView else { return }
        let route = desiredRoute
        let revision = routeRevision
        if !window.styleMask.contains(.fullScreen) {
            if route == .houses && regularFrame == nil {
                let frame = window.frame
                let usable = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
                regularFrame = frame
                window.setContentSize(NSSize(width: min(420, usable.width), height: min(570, usable.height - 30)))
                let size = window.frame.size
                let x = max(usable.minX, min(frame.midX - size.width / 2, usable.maxX - size.width))
                let y = max(usable.minY, min(frame.midY - size.height / 2, usable.maxY - size.height))
                window.setFrameOrigin(NSPoint(x: x, y: y))
            } else if route != .houses, let frame = regularFrame {
                window.setFrame(frame, display: true)
                regularFrame = nil
            }
        }
        populatePlayableVillage()
        let js = """
        document.documentElement.toggleAttribute('data-room-window', route === 'houses');
        window.dispatchEvent(new CustomEvent('snowfall-surface', {detail: 'preview'}));
        if (route === 'houses') window.dispatchEvent(new CustomEvent('snowfall-houses', {detail: state}));
        if (route !== 'scene') window.dispatchEvent(new CustomEvent('snowfall-open', {detail: route}));
        if (route === 'houses' && house) window.dispatchEvent(new CustomEvent('snowfall-house', {detail: house}));
        """
        let arguments: [String: Any] = ["route": route.rawValue, "state": route == .houses ? rooms.state : [:],
                                         "house": desiredHouseID as Any? ?? NSNull()]
        view.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page) { [weak self, weak window] result in
            guard let self = self, let window = window, self.preview === window, self.routeRevision == revision else { return }
            if case .failure(let error) = result { self.fail(error.localizedDescription); return }
            if smokeTest {
                self.inspectPreview(route, view: view)
            } else {
                NSApp.setActivationPolicy(.regular)
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === preview else { return }
        previewResize?.cancel()
        previewResize = nil
        if !smokeTest && regularFrame == nil && !closed.styleMask.contains(.fullScreen) { closed.saveFrame(usingName: "SnowfallPreview") }
        if let view = previewView { stop(view) }
        closed.contentView = nil
        preview = nil
        regularFrame = nil
        previewView = nil
        previewReady = false
        if !smokeTest { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { notifyFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { notifyFullScreen(false) }
    private func notifyFullScreen(_ enabled: Bool) {
        previewView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('snowfall-native-fullscreen', {detail: \(enabled)}))")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(.scene)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ending = true
        DistributedNotificationCenter.default().removeObserver(self)
        porches.stop()
        doors.stop()
        ground.stop()
        groundClock?.invalidate()
        clockPulse?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self,name:NSWorkspace.didWakeNotification,object:nil)
        postOffice.stop()
        pendingPictures.values.forEach { $0.cancel() }
        doorstep.dismiss()
        snow.shutdown()
        if !smokeTest { widgetFrames.stop() }
        NSApp.servicesProvider = nil
        if smokeTest { try? FileManager.default.removeItem(at: picture.directory) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if !smokeTest, regularFrame == nil, let window = preview, !window.styleMask.contains(.fullScreen) { window.saveFrame(usingName: "SnowfallPreview") }
        for background in backgrounds.values { background.window.orderOut(nil) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "snowfallWindow", let sender = message.webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == webRoot.appendingPathComponent("index.html").standardizedFileURL else { return }
        if let info = message.body as? [String:Any], info["action"] as? String == "freeSnowState" {
            guard !ending, let display = backgrounds.first(where:{ $0.value.view === sender })?.key,
                  let state = info["state"] as? [String:Any] else { return }
            let activeBefore = groundStates[display]?["groundActive"] as? Bool
            groundStates[display] = state
            if activeBefore != state["groundActive"] as? Bool, !smokeTest || freeSnowCheck { ground.syncReceivers(testing:smokeTest) }
            ground.setFighting(state["fightActive"] as? Bool == true,display:display)
            syncGroundClock()
            return
        }
        if let request = message.body as? [String: String], sender === previewView {
            if request["action"] == "postOffice" { showPostOffice(nil) }
            else if request["action"] == "openLetter", let id = request["id"] { postOffice.openItem(id: id) }
            else if request["action"] == "houseRoom", let id = request["id"], rooms.model.houses.contains(where:{ $0.id == id }) {
                show(.houses,houseID:id)
            }
            return
        }
        guard let command = message.body as? String else { return }
        if command == "effectsOn" || command == "effectsOff" {
            guard sender === previewView || backgrounds.values.contains(where: { $0.view === sender }) else { return }
            webEffectsEnabled = command == "effectsOn"
            applySnowPreference()
            return
        }
        guard sender === previewView else { return }
        if command.hasPrefix("openHouseFolder:") {
            rooms.openFolder(id: String(command.dropFirst("openHouseFolder:".count)))
            return
        }
        switch command {
        case "houses": rooms.list()
        case "styleHouses": rooms.apply(nil)
        case "restoreHouses": rooms.restore(nil)
        case "houseWidgets": rooms.pick(nil)
        case "postOffice": showPostOffice(nil)
        case "wallpaper": useWallpaper(nil)
        case "play": show(.yard)
        case "tools": show(.tools)
        case "preview": show(.scene)
        case "fullscreen":
            if smokeTest { smokeBridgeReceived = true } else { toggleFullscreen(nil) }
        case "widgetSettings":
            if #available(macOS 14.0,*), let pane = URL(string:"x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                _ = NSWorkspace.shared.open(pane)
            }
        case "notes", "music", "clock": openNativeApp(command)
        default: break
        }
    }

    @objc private func openNativeAppFromMenu(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { openNativeApp(command) }
    }

    private func openNativeApp(_ command: String) {
        guard !smokeTest, let bundle = ["notes": "com.apple.Notes", "music": "com.apple.Music", "clock": "com.apple.clock"][command] else { return }
        let name = command.capitalized
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            tellUser("\(name) could not be found on this Mac.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async { self?.tellUser("\(name) could not open. \(error.localizedDescription)") }
            }
        }
    }

    private func tellUser(_ message: String) {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = message
        if let window = preview { alert.beginSheetModal(for: window) }
        else { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let index = webRoot.appendingPathComponent("index.html").standardizedFileURL
        decisionHandler(action.request.url?.standardizedFileURL == index ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        initializeImage(in: webView)
    }

    private func initializeImage(in view: WKWebView) {
        let revision = imageRevision
        sendImage(to: view) { [weak self, weak view] result in
            guard let self = self, let view = view,
                  self.previewView === view || self.backgrounds.values.contains(where: { $0.view === view }) else { return }
            if revision != self.imageRevision { self.initializeImage(in: view); return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            self.finishSurface(view)
        }
    }

    private func finishSurface(_ webView: WKWebView) {
        if webView === previewView {
            previewReady = true
            previewGroundKey = nil
            syncPreviewGroundDisplay()
            sendFiles(to: webView)
            routePreview()
            return
        }
        guard let id = backgrounds.first(where: { $0.value.view === webView })?.key else { return }
        // Apply the wallpaper presentation and decode the image before displaying the native window.
        let script = """
        window.dispatchEvent(new CustomEvent('snowfall-surface', {detail: 'wallpaper'}));
        const artwork = document.querySelector('#wallpaper');
        if (!window.snowfallNative || window.snowfallSurface !== 'wallpaper' || !artwork?.naturalWidth)
          throw new Error('The packaged wallpaper is unavailable.');
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self = self, let current = self.backgrounds[id], current.view === webView else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            self.backgrounds[id]?.ready = true
            self.backgrounds[id]?.villageSignature = nil
            self.sendPlots(display: id, to: current.view)
            self.sendWidgetFrames(self.cachedFrames[id] ?? [], to: current.view)
            current.window.orderFrontRegardless()
            self.backgrounds[id]?.pendingActions.removeAll()
            for action in current.pendingActions { self.send(action, to: current.view) }
            if smokeTest { self.inspectBackgrounds() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(error.localizedDescription) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let id = backgrounds.first(where:{ $0.value.view === webView })?.key {
            backgrounds[id]?.ready = false
            ground.cancel()
            groundStates.removeValue(forKey:id)
            ground.setFighting(false, display:id)
        }
        load(webView)
    }

    private func inspectBackgrounds() {
        guard !smokeBegan, !backgrounds.isEmpty, backgrounds.values.allSatisfy({ $0.ready }) else { return }
        smokeBegan = true
        if freeSnowCheck {
            guard let screen = activeScreen, let display = screenID(screen) else { fail("Missing display for open-snow check."); return }
            Task { @MainActor in await self.checkFreeSnow(display) }
            return
        }
        for screen in NSScreen.screens {
            guard let id = screenID(screen), let window = backgrounds[id]?.window,
                  window.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)),
                  window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)),
                  window.ignoresMouseEvents, !window.canBecomeKey, !window.canBecomeMain,
                  window.isVisible, window.frame.equalTo(screen.frame),
                  window.collectionBehavior.contains(.canJoinAllSpaces) else {
                fail("A wallpaper did not cover its display below Finder icons with input passing through.")
                return
            }
        }
        guard let screen = activeScreen, let id = screenID(screen), let view = backgrounds[id]?.view else {
            fail("No display available to test a wallpaper action.")
            return
        }
        guard DesktopHouseInteraction.checkGestures() else { fail("House click or drag filtering failed."); return }
        let frame = CGDisplayBounds(id.uint32Value)
        let testPlot = DesktopHouseInteraction.Plot(id: "fixture-house", center: CGPoint(x:frame.midX, y:frame.midY),
                                                    size:64, display:id.uint32Value, frame:frame)
        sendPorchTap(testPlot, to: view)
        setWidgetFrames([["x": 0.12, "y": 0.15, "width": 0.08, "height": 0.12]], display: id)
        let before = """
        if (!document.querySelector('.porch-flurry')) throw new Error('A native house tap did not start a snowball exchange.');
        if (window.__widgetFrames?.[0]?.x !== 0.12) throw new Error('The synthetic native widget-frame geometry did not arrive.');
        const controls = document.querySelector('#surface-controls');
        if (!controls || controls.getClientRects().length && getComputedStyle(controls).visibility !== 'hidden')
          throw new Error('Interactive controls are visible on the wallpaper.');
        const clockStamp = document.querySelector('#village-time');
        clockStamp.dateTime = '';
        window.dispatchEvent(new Event('snowfall-clock-tick'));
        if (Math.abs(Date.parse(clockStamp.dateTime) - Date.now()) > 2000 || !clockStamp.dateTime)
          throw new Error('The native clock tick did not reach the tower.');
        if (document.querySelector('#wallpaper')?.naturalWidth !== 2560) throw new Error('Full wallpaper asset is missing.');
        if (Number(localStorage.getItem('snowfall-os.snowman') || 0) !== 0) throw new Error('The isolated snow yard did not start empty.');
        """
        view.callAsyncJavaScript(before, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            self.setWidgetFrames([], display: id)
            self.rollSnow(nil)
            self.sendPlow(nil)
            self.checkWallpaperActions(view)
        }
    }

    /// Check native ground gestures, including the former lower-center sign
    /// position, using an isolated WebKit store and a synthetic widget.
    private func checkFreeSnow(_ display: NSNumber) async {
        func wait(_ check: () -> Bool) async -> Bool {
            let until = Date().addingTimeInterval(5)
            repeat {
                if check() { return true }
                try? await Task.sleep(nanoseconds:30_000_000)
            } while Date() < until
            return check()
        }
        setWidgetFrames([["x":0.08,"y":0.11,"width":0.10,"height":0.1]],display:display)
        guard await wait({ self.groundSurfaces().contains(where:{$0.id == display}) }),
              let surface = groundSurfaces().first(where:{$0.id == display}), let window = backgrounds[display]?.window else {
            fail("No native open-snow surface."); return
        }
        let a = CGPoint(x:0.18,y:0.34)
        let b = CGPoint(x:(surface.usable.midX-surface.frame.minX)/surface.frame.width,
                        y:(surface.usable.maxY-32-surface.frame.minY)/surface.frame.height)
        func send(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = [], desktop: Bool = true) {
            _ = ground.checkEvent(type,point:point,surface:surface,window:window,modifiers:flags,desktop:desktop)
        }
        func number(_ key: String) -> Int { groundStates[display]?[key] as? Int ?? -1 }
        func yes(_ key: String) -> Bool { groundStates[display]?[key] as? Bool == true }
        func at(_ p: CGPoint) -> Bool {
            guard let x = groundStates[display]?["lastX"] as? Double, let y = groundStates[display]?["lastY"] as? Double else { return false }
            return abs(x-p.x)<0.002 && abs(y-p.y)<0.002
        }
        let initial = ground.gestures
        send(.leftMouseDown,a,flags:.control)
        send(.leftMouseDown,a,desktop:false)
        guard let block = surface.blocked.first(where: { surface.usable.contains(CGPoint(x:$0.midX,y:$0.midY)) }) else {fail("No painted control to protect.");return}
        let blocked = CGPoint(x:(block.midX-surface.frame.minX)/surface.frame.width,y:(block.midY-surface.frame.minY)/surface.frame.height)
        send(.leftMouseDown,blocked)
        guard ground.gestures == initial else {fail("Open snow accepted a modified, covered or painted-control click.");return}
        send(.leftMouseDown,a)
        guard await wait({yes("holding") && number("holdStage") == 3}) else {fail("Holding at the first spot did not pack all three stages.");return}
        send(.leftMouseUp,a)
        guard await wait({number("snowmen") == 1 && !yes("holding") && at(a)}) else {fail("The first snowman missed its location.");return}
        // Finder and WindowManager can exchange receivers mid-gesture, and a
        // throttled wallpaper may only see both messages after the release.
        let release = ProcessInfo.processInfo.systemUptime
        let passiveBefore = ground.passiveInputs
        guard ground.checkObservedEvent(.leftMouseDown,point:b,surface:surface,timestamp:release-1.6),
              ground.checkObservedEvent(.leftMouseUp,point:b,surface:surface,timestamp:release,clickThroughWindow:window),
              ground.passiveInputs == passiveBefore+1,
              await wait({number("snowmen") == 2 && at(b)}) else {
            fail("A batched real-duration hold did not plant through the passive desktop route.");return
        }
        let baseLevel = Int(CGWindowLevelForKey(.desktopWindow))-2
        guard GroundInteraction.isBackgroundWindow(bundle:"com.apple.wallpaper.agent",level:baseLevel,bounds:surface.frame,usable:surface.usable),
              !GroundInteraction.isBackgroundWindow(bundle:"com.apple.WindowManager",level:baseLevel,bounds:block,usable:surface.usable),
              !GroundInteraction.isBackgroundWindow(bundle:"com.apple.finder",level:0,bounds:surface.frame,usable:surface.usable) else {
            fail("A layered desktop receiver was misclassified.");return
        }
        let c = CGPoint(x:0.51,y:0.55)
        send(.leftMouseDown,c)
        send(.leftMouseDragged,CGPoint(x:c.x,y:-0.02))
        guard await wait({!yes("holding")}) else {fail("Dragging out of the wallpaper failed to cancel the hold.");return}
        send(.leftMouseDown,c)
        send(.leftMouseUp,c)
        guard await wait({yes("fightActive") && number("shots") >= 1 && at(c)}),
              await wait({number("returns") >= 1}) else {fail("A tap on open snow did not start a returning snowball fight.");return}
        smokeDeadline?.invalidate()
        print("PASS: local and passively observed holds planted on open snow, including a delayed hardware-timed release. A tap received return fire. Widgets, ordinary windows and modified clicks were excluded.")
        NSApp.terminate(nil)
    }

    private func checkWallpaperActions(_ view: WKWebView) {
        let script = """
        const ready = () => localStorage.getItem('snowfall-os.snowman') === '1' && document.querySelector('.yard-bank');
        const deadline = Date.now() + 18000;
        while (!ready() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 120));
        if (window.__cabinActions.join(',') !== 'roll,plow') throw new Error('The wallpaper actions did not arrive.');
        if (!ready()) throw new Error('A wallpaper roll or plow did not complete.');
        """
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            do {
                try self.picture.loadTestPicture()
                self.publishImage()
                view.callAsyncJavaScript("await window.snowfallImageReady; const img = document.querySelector('#wallpaper'); await img.decode(); return img.currentSrc.startsWith('data:image/jpeg;base64,') && img.naturalHeight === 4096;",
                                         arguments: [:], in: nil, in: .page) { result in
                    guard case .success(let value) = result, value as? Bool == true else {
                        self.fail("The wallpaper did not display the resized test picture."); return
                    }
                    self.show(.tools)
                }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    private func inspectPreview(_ route: Route, view: WKWebView) {
        guard let window = preview, window.level == .normal, !window.ignoresMouseEvents,
              window.styleMask.contains(.titled), backgrounds.values.allSatisfy({ $0.window.isVisible }) else {
            fail("The interactive window and the live wallpaper did not coexist.")
            return
        }
        let script = """
        if (!window.snowfallNative || window.snowfallSurface !== 'preview' || window.__cabinRoutes[window.__cabinRoutes.length - 1] !== route)
          throw new Error('The interactive surface did not receive its route: ' + route);
        if (!document.querySelector('#wallpaper')?.currentSrc.startsWith('data:image/jpeg;base64,')) throw new Error('The new interactive window did not inherit the chosen photo.');
        if (route === 'yard' && !document.querySelector('.yard-field:not([hidden])')) throw new Error('The snow yard did not open.');
        if (route === 'tools') {
          if (!document.querySelector('#tools-panel:not([hidden])')) throw new Error('The cabin tools did not open.');
          localStorage.setItem('snowfall-native-smoke', 'ok');
          if (localStorage.getItem('snowfall-native-smoke') !== 'ok') throw new Error('Local storage failed.');
          localStorage.removeItem('snowfall-native-smoke');
        }
        for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
          if (!link.sheet) throw new Error('A stylesheet is missing: ' + link.href);
        }
        window.webkit.messageHandlers.snowfallWindow.postMessage('fullscreen');
        """
        view.callAsyncJavaScript(script, arguments: ["route": route.rawValue], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            guard self.smokeBridgeReceived else { self.fail("The local native window bridge did not receive the test action."); return }
            switch route {
            case .tools: self.play(nil)
            case .yard: self.rooms.pick(nil)
            case .houses:
                if let id = self.desiredHouseID { self.checkHouseRoom(id, in: view) }
                else { self.checkHousePicker(in: view) }
            case .scene: self.fail("Unexpected smoke route.")
            }
        }
    }

    private func checkHousePicker(in view: WKWebView) {
        let script = """
        if (!document.querySelector('#house-list') || !document.documentElement.hasAttribute('data-room-window'))
          throw new Error('The compact house picker did not open.');
        const send = value => window.webkit.messageHandlers.snowfallWindow.postMessage(value);
        send('styleHouses');
        const until = Date.now() + 12000;
        while ((!window.__houseState?.enabled || !document.querySelector('[data-house-id]')) && Date.now() < until)
          await new Promise(done => setTimeout(done, 60));
        const entries = window.__houseState?.houses || [];
        if (entries.length !== 1 || !document.querySelector('[data-house-id]')) throw new Error('The synthetic house did not appear.');
        send('openHouseFolder:unknown-id');
        send('openHouseFolder:' + entries[0].id);
        """
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            guard self.smokeOpenedFolders == 1, let house = self.rooms.model.houses.first,
                  self.rooms.model.houses.count == 1, self.preview?.contentView?.bounds.width == 420 else {
                self.fail("The synthetic folder bridge or compact native picker failed."); return
            }
            // A unique pasteboard exercises the Services entry point without
            // ever reading, writing, or clearing the person's clipboard.
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.writeObjects([house.url as NSURL])
            var serviceError: NSString?
            self.rooms.openHouseWidgets(board, userData: nil, error: &serviceError)
            if serviceError != nil || self.desiredHouseID != house.id { self.fail("Finder Services did not route the selected fixture house.") }
        }
    }

    private func checkHouseRoom(_ id: String, in view: WKWebView) {
        let script = """
        const waitFor = async check => {
          const until = Date.now() + 8000;
          while (!check() && Date.now() < until) await new Promise(done => setTimeout(done, 60));
          return check();
        };
        if (!await waitFor(() => document.querySelector('[data-room-id]')?.dataset.roomId === id))
          throw new Error('Finder Services did not open the selected house room.');
        document.querySelector("[data-widget='notes']")?.click();
        const editor = document.querySelector('textarea');
        if (!editor) throw new Error('The fixture house notebook did not open.');
        editor.value = 'Local smoke-test note';
        editor.dispatchEvent(new Event('input', {bubbles:true}));
        window.webkit.messageHandlers.snowfallWindow.postMessage('restoreHouses');
        if (!await waitFor(() => window.__houseState?.enabled === false && window.__houseState?.houses.length === 0))
          throw new Error('The fixture icon did not restore.');
        """
        view.callAsyncJavaScript(script, arguments: ["id": id], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result { self.fail(self.errorMessage(error)); return }
            self.useWallpaper(nil)
            guard self.preview == nil, self.backgrounds.values.allSatisfy({ $0.window.isVisible }) else {
                self.fail("Closing the house room did not return to the live wallpaper."); return
            }
            self.checkImageReset()
        }
    }

    private func checkImageReset() {
        restoreAlpine(nil)
        guard !FileManager.default.fileExists(atPath: picture.file.path), let view = backgrounds.values.first?.view else {
            fail("The bundled wallpaper could not be restored."); return
        }
        let check = "await window.snowfallImageReady; const img = document.querySelector('#wallpaper'); await img.decode(); return new URL(img.currentSrc).pathname.endsWith('/assets/scene.jpg') && img.naturalWidth === 2560;"
        view.callAsyncJavaScript(check, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let value) = result, value as? Bool == true else {
                self.fail("The restored village scene did not appear."); return
            }
            self.smokeDeadline?.invalidate()
            print("PASS: click-through wallpaper on \(self.backgrounds.count) display(s), roll and plow, native tools and play, local storage, trusted bridge, local picture conversion/selection, widget frame delivery, porch click and drag routing, synthetic Finder folder styling/restoration, Finder Services, per-house notebook, and restoring the village scene.")
            NSApp.terminate(nil)
        }
    }

    private func errorMessage(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    @objc private func smokeTimeout() { fail("Timed out waiting for the wallpaper or its interactive window.") }

    private func fail(_ message: String) {
        guard !failing else { return }
        failing = true
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if smokeTest { try? FileManager.default.removeItem(at: picture.directory); exit(1) }
        let alert = NSAlert()
        alert.messageText = "\(appName) could not start"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@main
private enum Snowfall {
    @MainActor static func main() {
        if let i = CommandLine.arguments.firstIndex(of:"--ground-hitpoint"), i+2 < CommandLine.arguments.count,
           let x = Double(CommandLine.arguments[i+1]), let y = Double(CommandLine.arguments[i+2]), (0...1).contains(x), (0...1).contains(y) {
            exit(DesktopHouseInteraction.printSessionStatus(hitPoint:true,ground:CGPoint(x:x,y:y)))
        }
        if CommandLine.arguments.contains("--playground-hitpoint") {
            print("{\"window\":0,\"exposed\":false}")
            exit(0)
        }
        if CommandLine.arguments.contains("--porch-hitpoint") { exit(DesktopHouseInteraction.printSessionStatus(hitPoint:true)) }
        if CommandLine.arguments.contains("--post-office-hitpoint") { exit(DesktopHouseInteraction.printSessionStatus(hitPoint:true, office:true)) }
        if CommandLine.arguments.contains("--porch-session-status") { exit(DesktopHouseInteraction.printSessionStatus()) }
        if CommandLine.arguments.contains("--check-village-plan") {
            guard let file = Bundle.main.resourceURL?.appendingPathComponent("Desktop/assets/village-plan.json"),
                  let plan = try? VillageComposition.load(from: file), plan.checkGeometry(),
                  PorchTargets.checkFinderIconPolicy(), PorchTargets.checkLetterRouting() else {
                print("FAIL: village placement, hit geometry or widget clearance."); exit(1)
            }
            print("PASS: 18 cottages on four display shapes, Finder visibility settings, native hit geometry, widget clearance and both file letters.")
            exit(0)
        }
        if CommandLine.arguments.contains("--porch-layout-status") {
            guard let root = Bundle.main.resourceURL else { print("{\"error\":\"Missing bundled resources\"}"); exit(1) }
            let village = FolderVillage(assets: root.appendingPathComponent("Desktop/assets/houses", isDirectory: true))
            do { try village.inspect() }
            catch { print("{\"error\":\"Finder houses unavailable\"}"); exit(1) }
            let porches = DesktopHouseInteraction()
            porches.setHouses(village.houses, observe: false)
            print("{\"styled\":\(village.houses.count),\"located\":\(porches.plots.count),\"size\":\(Int(porches.size))}")
            exit(0)
        }
        if CommandLine.arguments.contains("--village-status") {
            guard let root = Bundle.main.resourceURL else { print("{\"error\":\"Missing bundled resources\"}"); exit(1) }
            exit(HouseRooms.printStatus(assets: root.appendingPathComponent("Desktop/assets/houses", isDirectory: true)))
        }
        // Direct executable launches bypass Launch Services' normal single-instance
        // behavior. Never stack transparent input panels from two wallpaper agents.
        // Kernel releases this per-user lock even after a crash.
        var sessionFile: Int32 = -1
        if !smokeTest {
            do {
                let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                    .appendingPathComponent("com.snowfallos.desktop", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                sessionFile = Darwin.open(directory.appendingPathComponent("wallpaper.lock").path,
                                          O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard sessionFile >= 0 else { throw POSIXError(.EACCES) }
                if flock(sessionFile, LOCK_EX | LOCK_NB) != 0 {
                    guard errno == EWOULDBLOCK else { throw POSIXError(.EIO) }
                    print("Snowfall OS is already running. Its snowflake menu is available in the menu bar.")
                    exit(0)
                }
            } catch {
                FileHandle.standardError.write(Data("The wallpaper session could not be opened.\n".utf8))
                exit(1)
            }
        }
        defer { if sessionFile >= 0 { Darwin.close(sessionFile) } }
        let app = NSApplication.shared
        let delegate = CabinApp()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
