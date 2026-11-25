import AppKit
import QuartzCore

@MainActor private final class DoorstepPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A short-lived game above Finder's icon layer and below widgets and ordinary windows.
/// Finder still receives every click, including clicks through the snowman and its bubble.
@MainActor final class DoorstepFeedback {
    private enum Phase { case serving, ready, returning, finished }
    private let assets: URL
    private var pictures: [String: CGImage] = [:]
    private var panel: DoorstepPanel?
    private var plot: DesktopHouseInteraction.Plot?
    private var phase = Phase.serving
    private var pending = false
    private var catches = 0
    private var step: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    private var spaceChange: NSObjectProtocol?
    private var snowman = CALayer()
    private var ball = CALayer()
    private var bubble = CATextLayer()
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
            if phase == .ready { returnBall() }
            else if phase != .finished { pending = true }
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
        let height = min(bounds.height, size + 50)
        let right = point.x < bounds.midX
        let originX = right ? point.x + icon * 0.43 : point.x - icon * 0.43 - width
        let originY = point.y - icon * 0.37 - 14
        let rect = NSRect(x: min(max(bounds.minX, originX), bounds.maxX-width).rounded(),
                          y: min(max(bounds.minY, originY), bounds.maxY-height).rounded(),
                          width: width, height: height)
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

        let leftX = max(28, size*0.55), rightX = width - leftX
        let flurryX = right ? leftX : rightX
        let mittX = right ? rightX : leftX
        let feet: CGFloat = 12
        hand = CGPoint(x: flurryX + (right ? 1 : -1)*size*0.22, y: feet + size*0.49)
        mitten = CGPoint(x: mittX, y: feet + size*0.21)
        arc = min(size*0.72, max(18, height - max(hand.y, mitten.y) - 35))
        snowman = sprite("snowman", frame: CGRect(x: flurryX-size*0.46, y: feet, width: size*0.92, height: size),
                         scene: scene)
        _ = sprite("yard-mitten", frame: CGRect(x: mittX-size*0.25, y: feet-2, width: size*0.5, height: size*0.58),
                   scene: scene)
        let diameter = max(10, size * 0.20)
        ball = sprite("yard-ball", frame: CGRect(x: 0, y: 0, width: diameter, height: diameter), scene: scene)
        ball.opacity = 0
        bubble = CATextLayer()
        bubble.contentsScale = screen.backingScaleFactor
        bubble.alignmentMode = .center
        bubble.foregroundColor = NSColor(calibratedRed: 0.19, green: 0.26, blue: 0.26, alpha: 1).cgColor
        bubble.backgroundColor = NSColor(calibratedRed: 1, green: 0.965, blue: 0.88, alpha: 0.98).cgColor
        bubble.borderColor = NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.46, alpha: 0.85).cgColor
        bubble.borderWidth = 0.8
        bubble.cornerRadius = 10
        bubble.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        bubble.fontSize = 12
        bubble.frame = CGRect(x: 8, y: height-24, width: width-16, height: 20)
        scene.addSublayer(bubble)
        panel = window
        plot = next
        catches = 0
        pending = false
        phase = .serving
        say("Catch!")
        window.orderFrontRegardless()
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

    private func say(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.string = text
        // Match the bubble to the short phrase, keeping it centered over the two characters.
        if let scene = bubble.superlayer {
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
            let width = min(scene.bounds.width - 8, textWidth + 19)
            bubble.frame = CGRect(x: (scene.bounds.width-width)/2, y: bubble.frame.minY, width: width, height: bubble.frame.height)
        }
        CATransaction.commit()
    }

    private func serve() {
        phase = .serving
        lob(from: hand, to: mitten) { game in
            game.phase = .ready
            game.say("Click house to throw")
            if game.pending { game.pending = false; game.returnBall() }
        }
    }

    private func returnBall() {
        phase = .returning
        say("Your throw!")
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
                game.say("Three in a row!")
                game.schedule(after: 1.9) { $0.dismiss() }
            } else {
                game.say("\(game.catches) / 3")
                game.schedule(after: 0.49) { $0.serve() }
            }
        }
    }

    private func lob(from: CGPoint, to: CGPoint, arrived: @escaping (DoorstepFeedback) -> Void) {
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
            game.ball.opacity = 0; game.ball.removeAnimation(forKey: "flight")
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

    func dismiss() {
        step?.cancel(); step = nil
        idle?.cancel(); idle = nil
        if let spaceChange { NSWorkspace.shared.notificationCenter.removeObserver(spaceChange) }
        spaceChange = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil; plot = nil
        snowman = CALayer(); ball = CALayer(); bubble = CATextLayer()
    }
}
