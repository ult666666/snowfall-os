import AppKit
import WebKit

private let appName = "Snowfall OS"
private let smokeTest = CommandLine.arguments.contains("--smoke-test")

private final class CabinWindow: NSWindow {
    // Desktop mode uses a borderless window that still needs key events for notes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class CabinApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    private var window: CabinWindow!
    private var webView: WKWebView!
    private let standardStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    private var desktopMode = false
    private var windowedFrame = NSRect.zero
    private var webRoot: URL!
    private var smokeDeadline: Timer?
    private var smokeBridgeReceived = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Desktop", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            fail("Missing the bundled desktop page.")
            return
        }
        webRoot = root.standardizedFileURL
        NSApp.mainMenu = buildMenu()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = smokeTest ? .nonPersistent() : .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "snowfallWindow")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0, width: min(1240, visible.width * 0.94), height: min(810, visible.height * 0.91))
        window = CabinWindow(contentRect: frame, styleMask: standardStyle, backing: .buffered, defer: false)
        window.title = appName
        window.contentMinSize = NSSize(width: 380, height: 520)
        window.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.19, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = webView
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.center()

        if smokeTest {
            smokeDeadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                self?.fail("Timed out waiting for the native web view.")
            }
        } else {
            _ = window.setFrameUsingName("CabinWindow")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if !smokeTest && !desktopMode { window?.saveFrame(usingName: "CabinWindow") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = target
        return entry
    }

    private func submenu(_ title: String, in bar: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        bar.addItem(parent)
        return menu
    }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()
        let app = submenu(appName, in: bar)
        app.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        let edit = submenu("Edit", in: bar)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                    ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                    ("Select All", "selectAll:", "a")] {
            if title == "Cut" || title == "Select All" { edit.addItem(.separator()) }
            edit.addItem(item(title, NSSelectorFromString(action), key))
        }

        let view = submenu("View", in: bar)
        view.addItem(item("Use as Desktop", #selector(toggleDesktop(_:)), "\r", [.command, .option], target: self))
        view.addItem(item("Enter Full Screen", #selector(fullScreen(_:)), "f", [.command, .control], target: self))
        let windows = submenu("Window", in: bar)
        windows.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windows.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windows.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        NSApp.windowsMenu = windows
        return bar
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dock = NSMenu()
        dock.addItem(item(desktopMode ? "Return to Window" : "Use as Desktop", #selector(toggleDesktop(_:)), target: self))
        return dock
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDesktop(_:)) {
            menuItem.title = desktopMode ? "Return to Window" : "Use as Desktop"
            return window != nil && !window.styleMask.contains(.fullScreen)
        }
        if menuItem.action == #selector(fullScreen(_:)) {
            menuItem.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return window != nil && !desktopMode
        }
        return true
    }

    @objc private func fullScreen(_ sender: Any?) {
        if desktopMode { toggleDesktop(nil) }
        window.toggleFullScreen(sender)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let index = webRoot.appendingPathComponent("index.html").standardizedFileURL
        guard message.name == "snowfallWindow", message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == index,
              message.body as? String == "fullscreen" else { return }
        if smokeTest {
            // Exercise the real button and bridge without switching the user's active Space.
            smokeBridgeReceived = true
            return
        }
        fullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { notifyFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { notifyFullScreen(false) }

    private func notifyFullScreen(_ enabled: Bool) {
        let detail = enabled ? "true" : "false"
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('snowfall-native-fullscreen', {detail: \(detail)}))")
    }

    @objc private func toggleDesktop(_ sender: Any?) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        if desktopMode {
            desktopMode = false
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
            window.styleMask = standardStyle
            window.title = appName
            window.hasShadow = true
            let restored = window.constrainFrameRect(windowedFrame, to: window.screen ?? NSScreen.main)
            window.setFrame(restored, display: true)
            if !smokeTest { window.makeKeyAndOrderFront(nil) }
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowedFrame = window.frame
            if !smokeTest { window.saveFrame(usingName: "CabinWindow") }
            desktopMode = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.styleMask = .borderless
            window.hasShadow = false
            // Sit just above Finder's icons to receive clicks, below ordinary app windows.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.setFrame(screen.visibleFrame, display: true)
            if !smokeTest { window.orderFront(nil) }
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if desktopMode, let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.isFileURL,
              url.standardizedFileURL.path.hasPrefix(webRoot.path + "/") else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("The cabin page could not open. \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("The cabin page could not load. \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard smokeTest else { return }
        toggleDesktop(nil)
        guard desktopMode, window.level.rawValue < NSWindow.Level.normal.rawValue else {
            fail("Desktop mode did not lower the cabin below regular windows.")
            return
        }
        toggleDesktop(nil)
        guard !desktopMode, window.level == .normal, window.styleMask == standardStyle else {
            fail("Window mode did not restore the title bar and window level.")
            return
        }
        // This ephemeral session never opens the user's persistent notes or timer.
        let check = """
        const assert = (condition, message) => { if (!condition) throw new Error(message); };
        assert(document.title && document.body.querySelector('button'), 'Desktop controls missing');
        const scene = new Image();
        scene.src = 'assets/winter.webp';
        await scene.decode();
        assert(scene.naturalWidth > 500, 'Winter scene could not be decoded');
        for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
            assert(link.sheet, 'Missing stylesheet: ' + link.getAttribute('href'));
        }
        for (const family of ['Pixelify Sans', 'DM Sans']) {
            const result = await document.fonts.load('16px "' + family + '"');
            assert(result.length > 0 && result[0].status === 'loaded', 'Missing font: ' + family);
        }
        const openApp = name => document.querySelector('#dock [data-open="' + name + '"]').click();
        assert(document.querySelector('[data-kind="radio"]'), 'Radio did not open on startup');
        openApp('notes');
        const note = document.querySelector('[data-kind="notes"] textarea');
        note.value = 'Hello from the Mac cabin';
        note.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('[data-kind="notes"] .close').click();
        openApp('notes');
        assert(document.querySelector('[data-kind="notes"] textarea').value === note.value, 'Note did not reopen');
        assert(JSON.parse(localStorage.getItem('snowfall-os.notes')) === note.value, 'Local storage failed');
        openApp('focus');
        document.querySelector('[data-kind="focus"] [data-mode="break"]').click();
        assert(document.querySelector('[data-kind="focus"] [role="timer"]').textContent === '05:00', 'Break timer switch failed');
        openApp('yard');
        assert(!document.querySelector('.yard-field').hidden, 'Snow yard did not open');
        document.querySelector('#back-to-desk').click();
        assert(document.querySelector('.yard-field').hidden, 'Snow yard did not close');
        document.querySelector('#fullscreen').click();
        return 'Loaded ' + document.title + ' with its scene and fonts. Notes, timer, yard, desktop mode and native window controls passed.';
        """
        webView.callAsyncJavaScript(check, arguments: [:], in: nil, in: .page) { [weak self] result in
            self?.smokeDeadline?.invalidate()
            switch result {
            case .success(let message):
                guard self?.smokeBridgeReceived == true else {
                    self?.fail("The app's full-screen button did not reach the native window bridge.")
                    return
                }
                print(message)
                NSApp.terminate(nil)
            case .failure(let error):
                let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self?.fail(detail ?? String(describing: error))
            }
        }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if smokeTest { exit(1) }
        let alert = NSAlert()
        alert.messageText = "Snowfall OS could not start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
private let delegate = CabinApp()
app.setActivationPolicy(smokeTest ? .accessory : .regular)
app.delegate = delegate
app.run()
