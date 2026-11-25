import AppKit
import QuartzCore

@MainActor private final class DoorstepPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Only the snowman and mitten accept input, and only for the lifetime of the exchange.
@MainActor private final class SnowballSpot: NSView {
    var action: (() -> Void)?
    var onGlide: (() -> Void)?
    var ignoreInitialHover = false
    private var tracking: NSTrackingArea?
    private var pressed: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard onGlide != nil else { return }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero, options:[.inVisibleRect,.mouseEnteredAndExited,.activeAlways], owner:self, userInfo:nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        if !ignoreInitialHover && NSEvent.pressedMouseButtons == 0 { onGlide?() }
    }
    override func mouseExited(with event: NSEvent) { ignoreInitialHover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor:.openHand) }
    override func mouseDown(with event: NSEvent) { pressed = convert(event.locationInWindow, from:nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed else { return }
        let point = convert(event.locationInWindow, from:nil)
        if hypot(start.x-point.x, start.y-point.y) > 5 { pressed = nil }
    }
    override func mouseUp(with event: NSEvent) {
        let tapped = pressed != nil && bounds.contains(convert(event.locationInWindow, from:nil))
        pressed = nil
        if tapped { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// A short-lived game above Finder's icon layer and below widgets and ordinary windows.
@MainActor final class DoorstepFeedback {
    private enum Phase { case serving, ready, returning, finished }
    private let assets: URL
    private var pictures: [String: CGImage] = [:]
    private var panel: DoorstepPanel?
    private var spots: [DoorstepPanel] = []
    var occupiedDoorFrames: (() -> [CGRect])?
    private var plot: DesktopHouseInteraction.Plot?
    private var phase = Phase.serving
    private var pending = false
    private var catches = 0
    private var step: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    private var spaceChange: NSObjectProtocol?
    private var snowman = CALayer()
    private var ball = CALayer()
    private var glove = CALayer()
    private var hand = CGPoint.zero
    private var mitten = CGPoint.zero
    private var arc: CGFloat = 35

    var reduceMotion = false
    var isVisible: Bool { panel?.isVisible == true }
    private var still: Bool { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(assets: URL) { self.assets = assets }

    @discardableResult func tap(_ next: DesktopHouseInteraction.Plot) -> Bool {
        if let current = plot, current.id == next.id, current.display == next.display,
           hypot(next.center.x - current.center.x, next.center.y - current.center.y) < 8, isVisible {
            toss()
            return true
        }
        dismiss()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == next.display
        }), next.frame.width > 0, next.frame.height > 0 else { return false }
        if pictures.isEmpty {
            for name in ["snowman", "yard-mitten", "yard-ball"] {
                let url = assets.appendingPathComponent("props").appendingPathComponent(name + ".png")
                guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    pictures.removeAll(); return false
                }
                pictures[name] = image
            }
        }

        let bounds = screen.visibleFrame.insetBy(dx: 3, dy: 3)
        guard bounds.width >= 156, bounds.height >= 92 else { return false }
        let point = CGPoint(x: screen.frame.minX + (next.center.x - next.frame.minX) * screen.frame.width / next.frame.width,
                            y: screen.frame.maxY - (next.center.y - next.frame.minY) * screen.frame.height / next.frame.height)
        let icon = next.size * screen.frame.width / next.frame.width
        let size = min(78, max(48, icon * 0.78))
        let width = min(bounds.width, max(169, size * 2.88))
        let height = min(bounds.height, size + 36)
        let leftX = max(28, size * 0.55), rightX = width - leftX
        let feet: CGFloat = 12
        let obstacles = occupiedDoorFrames?() ?? []
        func placement(right: Bool, offsetY: CGFloat) -> (rect: CGRect, flurry: CGRect, mitt: CGRect, score: CGFloat) {
            let originX = right ? point.x + icon * 0.5 : point.x - icon * 0.5 - width
            let originY = point.y - icon * 0.37 - 14 + offsetY
            let rect = NSRect(x:min(max(bounds.minX,originX),bounds.maxX-width).rounded(),
                              y:min(max(bounds.minY,originY),bounds.maxY-height).rounded(), width:width, height:height)
            let flurryX = right ? leftX : rightX, mittX = right ? rightX : leftX
            let target = max(36, size * 0.72)
            let flurry = CGRect(x:rect.minX + flurryX - size * 0.47,y:rect.minY+feet-1,width:size*0.94,height:size+2)
            let mitt = CGRect(x:rect.minX + mittX - target / 2,y:rect.minY+feet-4,width:target,height:target)
            var covered: CGFloat = 0
            for obstacle in obstacles {
                for box in [flurry,mitt] {
                    let overlap = box.intersection(obstacle)
                    if !overlap.isNull { covered += overlap.width * overlap.height }
                }
            }
            return (rect,flurry,mitt,covered)
        }
        let preferred = point.x < bounds.midX
        let tries = [(preferred,CGFloat.zero),(!preferred,0),(preferred,size*0.65),(!preferred,size*0.65)]
        let choices = tries.map { (side, y) in (side, placement(right:side,offsetY:y)) }
        guard let (right, position) = choices.min(by: { $0.1.score < $1.1.score }) else { return false }
        let rect = position.rect
        let window = DoorstepPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("SnowfallDoorstepGame")
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.setFrame(rect, display: false)

        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        let scene = CALayer()
        view.layer = scene
        view.wantsLayer = true
        scene.frame = view.bounds
        scene.backgroundColor = NSColor.clear.cgColor
        scene.contentsScale = screen.backingScaleFactor
        window.contentView = view

        let flurryX = right ? leftX : rightX
        let mittX = right ? rightX : leftX
        hand = CGPoint(x: flurryX + (right ? 1 : -1)*size*0.22, y: feet + size*0.49)
        mitten = CGPoint(x: mittX, y: feet + size*0.21)
        arc = min(size*0.72, max(18, height - max(hand.y, mitten.y) - 35))
        snowman = sprite("snowman", frame: CGRect(x: flurryX-size*0.46, y: feet, width: size*0.92, height: size),
                         scene: scene)
        glove = sprite("yard-mitten", frame: CGRect(x: mittX-size*0.25, y: feet-2, width: size*0.5, height: size*0.58),
                   scene: scene)
        let diameter = max(10, size * 0.20)
        ball = sprite("yard-ball", frame: CGRect(x: 0, y: 0, width: diameter, height: diameter), scene: scene)
        ball.opacity = 0
        panel = window
        plot = next
        catches = 0
        pending = false
        phase = .serving
        window.orderFrontRegardless()
        if !obstacles.contains(where: { $0.intersects(position.flurry.insetBy(dx:3,dy:3)) }) {
            addSpot(frame:position.flurry, mitt:false)
        }
        if !obstacles.contains(where: { $0.intersects(position.mitt.insetBy(dx:3,dy:3)) }) {
            addSpot(frame:position.mitt, mitt:true)
        }
        spaceChange = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        if !still {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0.25; appear.toValue = 1; appear.duration = 0.16
            snowman.add(appear, forKey: "appear")
        }
        schedule(after: still ? 0.04 : 0.23) { $0.serve() }
        refreshTimeout()
        return window.isVisible
    }

    private func sprite(_ name: String, frame: CGRect, scene: CALayer) -> CALayer {
        let layer = CALayer()
        layer.contents = pictures[name]
        layer.contentsGravity = .resizeAspect
        layer.frame = frame
        scene.addSublayer(layer)
        return layer
    }

    private func addSpot(frame: CGRect, mitt: Bool) {
        let window = DoorstepPanel(contentRect: frame, styleMask:[.borderless,.nonactivatingPanel], backing:.buffered, defer:false)
        window.identifier = NSUserInterfaceItemIdentifier(mitt ? "SnowfallMitten" : "SnowfallFlurry")
        window.backgroundColor = NSColor(calibratedWhite:0.94, alpha:0.018)
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle]
        window.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopIconWindow))+1)
        let view = SnowballSpot(frame:CGRect(origin:.zero,size:frame.size))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(mitt ? "Toss the snowball back" : "Throw to Flurry")
        view.action = { [weak self] in self?.toss() }
        if mitt {
            // Appearing under a stationary pointer must never play the game by itself.
            view.ignoreInitialHover = frame.contains(NSEvent.mouseLocation)
            view.onGlide = { [weak self] in
                guard let self, !self.still else { return }
                self.toss()
            }
        }
        window.contentView = view
        window.setFrame(frame,display:false)
        window.orderFrontRegardless()
        spots.append(window)
    }

    private func toss() {
        if phase == .ready { returnBall() }
        else if phase != .finished { pending = true }
    }

    private func serve() {
        phase = .serving
        lob(from: hand, to: mitten, keepBall: true) { game in
            game.phase = .ready
            if !game.still {
                let settle = CAKeyframeAnimation(keyPath:"transform.rotation.z")
                settle.values = [0, -0.16, 0.045, 0]; settle.duration = 0.28
                game.glove.add(settle, forKey:"settle")
            }
            if game.pending { game.pending = false; game.returnBall() }
        }
    }

    private func returnBall() {
        phase = .returning
        refreshTimeout()
        lob(from: mitten, to: hand) { game in
            game.catches += 1
            if !game.still {
                let bob = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                bob.values = [0, -0.11, 0]; bob.duration = 0.25
                game.snowman.add(bob, forKey: "catch")
            }
            if game.catches == 3 {
                game.phase = .finished; game.pending = false
                if !game.still {
                    let wave = CAKeyframeAnimation(keyPath:"transform.rotation.z")
                    wave.values = [0, -0.13, 0.10, -0.06, 0]; wave.duration = 0.65
                    game.snowman.add(wave, forKey:"wave")
                }
                game.closeSpots()
                game.schedule(after: 1.25) { $0.dismiss() }
            } else {
                game.schedule(after: 0.49) { $0.serve() }
            }
        }
    }

    private func lob(from: CGPoint, to: CGPoint, keepBall: Bool = false, arrived: @escaping (DoorstepFeedback) -> Void) {
        let duration: TimeInterval = still ? 0.11 : 0.545
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ball.position = to; ball.opacity = 1
        if !still {
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: (from.x+to.x)/2, y: max(from.y,to.y) + arc*1.7))
            let flight = CAKeyframeAnimation(keyPath: "position")
            flight.path = path
            flight.duration = duration
            flight.timingFunction = CAMediaTimingFunction(name: .linear)
            ball.add(flight, forKey: "flight")
        }
        CATransaction.commit()
        schedule(after: duration) { game in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            game.ball.opacity = keepBall ? 1 : 0; game.ball.removeAnimation(forKey: "flight")
            CATransaction.commit()
            arrived(game)
        }
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping (DoorstepFeedback) -> Void) {
        step?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.panel != nil else { return }
            action(self)
        }
        step = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func refreshTimeout() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.8, execute: item)
    }

    private func closeSpots() {
        for window in spots { window.orderOut(nil); window.close() }
        spots.removeAll()
    }

    func dismiss() {
        closeSpots()
        step?.cancel(); step = nil
        idle?.cancel(); idle = nil
        if let spaceChange { NSWorkspace.shared.notificationCenter.removeObserver(spaceChange) }
        spaceChange = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil; plot = nil
        snowman = CALayer(); ball = CALayer(); glove = CALayer()
    }
}
