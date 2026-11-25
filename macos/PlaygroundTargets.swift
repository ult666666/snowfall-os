import AppKit

/// The wallpaper web view passes clicks through. Only painted playground controls
/// receive a native target, with its frame supplied by that display's own renderer.
@MainActor final class PlaygroundTargets {
    typealias Input = (_ display: NSNumber, _ id: String, _ phase: String, _ point: CGPoint) -> Void
    var onInput: Input?
    private var controls: [NSNumber: [String: Panel]] = [:]
    private var sites: [NSNumber: CGRect] = [:]
    private var states: [NSNumber: [String:Any]] = [:]
    private(set) var actions = 0
    var count: Int { controls.values.reduce(0) { $0 + $1.count } }
    var frames: [CGRect] { controls.values.flatMap { $0.values.map(\.frame) } }
    private let ids: Set<String> = ["build","reset","fight","throw","dodge","dodge-left","dodge-right",
                                    "plow","plow-left","plow-right","back","replay"]
    func state(on display: NSNumber) -> [String:Any] { states[display] ?? [:] }

    static func normalized(_ rect: CGRect, in frame: CGRect) -> [String:Double] {
        ["x":(rect.minX-frame.minX)/frame.width, "y":(rect.minY-frame.minY)/frame.height,
         "width":rect.width/frame.width, "height":rect.height/frame.height]
    }

    func setSite(_ site: CGRect?, on display: NSNumber) {
        if sites[display] == site { return }
        clear(display)
        sites[display] = site
    }

    func clear(_ display: NSNumber) {
        controls.removeValue(forKey:display)?.values.forEach { $0.close() }
        states.removeValue(forKey:display)
        sites.removeValue(forKey:display)
    }
    func stop() { for id in Array(sites.keys) { clear(id) } }

    func update(_ layout: [String:Any], display: NSNumber, screen: NSScreen, testing: Bool) {
        guard let site = sites[display], let targets = layout["targets"] as? [[String:Any]],
              targets.count <= 12 else { return }
        let full = CGDisplayBounds(display.uint32Value)
        let cocoa = screen.frame
        var active = controls[display] ?? [:]
        var accepted = Set<String>()
        for target in targets {
            guard let id = target["id"] as? String, ids.contains(id), !accepted.contains(id),
                  let label = (target["label"] ?? target["name"]) as? String, !label.isEmpty,
                  let x = target["x"] as? Double, let y = target["y"] as? Double,
                  let w = target["width"] as? Double, let h = target["height"] as? Double,
                  [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 else { continue }
            let quartz = CGRect(x:full.minX+x*full.width, y:full.minY+y*full.height,
                                width:w*full.width, height:h*full.height)
            // Clip decorative bleed before mapping the button back to AppKit coordinates.
            let rect = quartz.intersection(site.insetBy(dx:-2,dy:-2)).intersection(full)
            guard !rect.isNull, rect.width >= 5, rect.height >= 5 else { continue }
            let bounds = CGRect(x:cocoa.minX+(rect.minX-full.minX)/full.width*cocoa.width,
                                y:cocoa.maxY-(rect.maxY-full.minY)/full.height*cocoa.height,
                                width:rect.width/full.width*cocoa.width, height:rect.height/full.height*cocoa.height)
            let panel = active[id] ?? Panel()
            let button = panel.button
            button.setAccessibilityLabel(String(label.prefix(100)))
            button.toolTip = String(label.prefix(100))
            button.draggable = id == "plow"
            button.input = { [weak self, weak panel] phase, point in
                guard let self, let panel else { return }
                let anchor = panel.convertPoint(toScreen:point)
                let hit = CGPoint(x:(anchor.x-cocoa.minX)/cocoa.width, y:(cocoa.maxY-anchor.y)/cocoa.height)
                if phase != "drag" { self.actions += 1 }
                self.onInput?(display,id,phase,hit)
            }
            if panel.frame != bounds { panel.setFrame(bounds, display:false) }
            panel.quartzOrigin = CGPoint(x:rect.midX,y:rect.midY)
            if !panel.isVisible {
                if testing { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
            }
            accepted.insert(id)
            active[id] = panel
        }
        for id in Array(active.keys) where !accepted.contains(id) { active.removeValue(forKey:id)?.close() }
        controls[display] = active
        states[display] = layout["state"] as? [String:Any] ?? [:]
    }

    func hitPoint(_ id: String) -> [String:Any] {
        let matches = controls.values.compactMap { $0[id] }
        func exposed(_ panel: Panel) -> Bool {
            NSWindow.windowNumber(at:CGPoint(x:panel.frame.midX,y:panel.frame.midY),
                                  belowWindowWithWindowNumber:0) == panel.windowNumber
        }
        guard let panel = matches.first(where:exposed) ?? matches.first else { return [:] }
        return ["x":Int(panel.quartzOrigin.x),"y":Int(panel.quartzOrigin.y),"window":panel.windowNumber,
                "exposed":exposed(panel)]
    }

    /// Exercise AppKit's normal event dispatch using this specific fixture window,
    /// without posting global mouse events or moving the visitor's pointer.
    func checkMouse(on display: NSNumber, id: String, drag: Bool = false) -> Bool {
        guard let panel = controls[display]?[id] else { return false }
        let mid = CGPoint(x:panel.frame.width/2, y:panel.frame.height/2)
        guard panel.button.hitTest(mid) === panel.button else { return false }
        let events: [NSEvent.EventType] = drag ? [.leftMouseDown,.leftMouseDragged,.leftMouseUp] : [.leftMouseDown,.leftMouseUp]
        for (index,type) in events.enumerated() {
            let point = drag && index > 0 ? CGPoint(x:mid.x+52, y:mid.y) : mid
            guard let event = NSEvent.mouseEvent(with:type, location:point, modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime, windowNumber:panel.windowNumber, context:nil,
                eventNumber:index, clickCount:1, pressure:1) else { return false }
            panel.sendEvent(event)
        }
        return true
    }

    private final class Panel: NSPanel {
        let button = Button(frame:.zero)
        var quartzOrigin = CGPoint.zero
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        init() {
            super.init(contentRect:.zero, styleMask:[.borderless,.nonactivatingPanel], backing:.buffered, defer:false)
            title = "Snow playground"
            level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopIconWindow))+1)
            collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle]
            isOpaque = false
            // The WindowServer treats completely transparent pixels as click-through.
            backgroundColor = NSColor(calibratedWhite:0.92,alpha:0.018)
            hasShadow = false
            isReleasedWhenClosed = false
            isExcludedFromWindowsMenu = true
            hidesOnDeactivate = false
            canHide = false
            isMovable = false
            animationBehavior = .none
            contentView = button
        }
        override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
    }

    private final class Button: NSView {
        var input: ((String,CGPoint) -> Void)?
        var draggable = false
        private var start: CGPoint?
        private var moved = false
        private var last = -Double.infinity
        override init(frame: NSRect) {
            super.init(frame:frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor:.pointingHand)
        }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            moved = false
            last = -.infinity
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            moved = moved || hypot(point.x-start.x,point.y-start.y) > 4
            guard draggable, moved, event.timestamp-last >= 1.0/30.0 else { return }
            last = event.timestamp
            input?("drag",point)
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            if moved {
                if draggable { input?("end",event.locationInWindow) }
            } else if bounds.contains(convert(event.locationInWindow, from:nil)) {
                input?("activate",event.locationInWindow)
            }
        }
        override func accessibilityPerformPress() -> Bool {
            input?("activate",CGPoint(x:bounds.midX,y:bounds.midY)); return true
        }
    }
}
