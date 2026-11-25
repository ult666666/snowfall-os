import AppKit
import QuartzCore

private struct SnowWindow {
    let bounds: CGRect
    let level: Int
    let owner: Int
}

private struct SnowEdge: Equatable {
    var start: CGFloat
    var end: CGFloat
    var top: CGFloat
}

private enum SnowGeometry {
    // WindowServer returns front-to-back order and a top-left global origin.
    static func visibleEdges(windows: [SnowWindow], screen: CGRect, usable: CGRect) -> [SnowEdge] {
        var foreground: [CGRect] = []
        var edges: [SnowEdge] = []
        for (index, window) in windows.enumerated() {
            let rect = window.bounds
            guard rect.intersects(screen), window.level >= 0 else { continue }
            let fillsScreen = rect.insetBy(dx: -2, dy: -2).contains(screen)
            // WindowServer can report transparent, display-sized system
            // surfaces. Higher levels composite above our floating panel
            // natively, including the actual opaque pixels of any such HUD.
            if fillsScreen && window.level > Int(CGWindowLevelForKey(.floatingWindow)) { continue }
            defer { foreground.append(rect) }

            if fillsScreen && window.level == 0 { break }
            guard window.level == 0, rect.width >= 300, rect.height >= 170,
                  rect.width >= 490 || rect.height >= 235,
                  rect.minY > usable.minY + 5, rect.minY < usable.maxY - 4 else { continue }

            // A small centered child within a window of the same process is
            // usually a sheet or dialog. Treat it only as an occluder.
            let likelySheet = rect.width < 760 && rect.height < 560 &&
                windows[(index + 1)...].contains { back in
                    back.level == 0 && back.owner == window.owner &&
                    back.bounds.width > rect.width * 1.2 && back.bounds.height > rect.height * 1.35 &&
                    back.bounds.insetBy(dx: -3, dy: -3).contains(rect) &&
                    abs(back.bounds.midX - rect.midX) < max(22, rect.width * 0.08)
                }
            guard !likelySheet else { continue }

            let left = max(usable.minX, rect.minX + 10)
            let right = min(usable.maxX, rect.maxX - 10)
            guard right - left >= 48 else { continue }

            // Include the whole falling-mote band. A front panel can occlude
            // the drift even when the cap itself is just below that panel.
            let band = CGRect(x: left, y: rect.minY - 25, width: right - left, height: 26)
            var spans = [left...right]
            for other in foreground where other.intersects(band) {
                spans = spans.flatMap { span -> [ClosedRange<CGFloat>] in
                    if other.maxX <= span.lowerBound || other.minX >= span.upperBound { return [span] }
                    var pieces: [ClosedRange<CGFloat>] = []
                    if other.minX > span.lowerBound { pieces.append(span.lowerBound...other.minX) }
                    if other.maxX < span.upperBound { pieces.append(other.maxX...span.upperBound) }
                    return pieces
                }
                if spans.isEmpty { break }
            }
            for span in spans where span.upperBound - span.lowerBound >= 48 {
                edges.append(SnowEdge(start: span.lowerBound, end: span.upperBound, top: rect.minY))
            }
        }
        return edges
    }

    // Each display uses its own pair of coordinate rectangles. This works
    // for displays above or left of the main display and mixed scale factors.
    static func local(_ edge: SnowEdge, screen: CGRect, size: CGSize) -> SnowEdge {
        let sx = size.width / screen.width, sy = size.height / screen.height
        return SnowEdge(start: (edge.start - screen.minX) * sx, end: (edge.end - screen.minX) * sx,
                        top: (screen.maxY - edge.top) * sy)
    }
}

@MainActor private final class SnowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class SnowScreen {
    let panel: NSPanel
    let bounds: CGRect
    let usable: CGRect
    private let root = CALayer()
    private let caps = CAShapeLayer()
    private let particles = CALayer()
    private var last: [SnowEdge] = []

    init?(_ screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let cg = CGDisplayBounds(id.uint32Value)
        let frame = screen.frame, visible = screen.visibleFrame
        guard cg.width > 0, cg.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        bounds = cg
        usable = CGRect(x: cg.minX + (visible.minX - frame.minX) * cg.width / frame.width,
                        y: cg.minY + (frame.maxY - visible.maxY) * cg.height / frame.height,
                        width: visible.width * cg.width / frame.width,
                        height: visible.height * cg.height / frame.height)
        panel = SnowPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.level = .floating
        panel.setFrame(frame, display: false)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        root.frame = view.bounds
        root.masksToBounds = true
        caps.frame = root.bounds
        caps.contentsScale = screen.backingScaleFactor
        caps.fillColor = NSColor(calibratedRed: 0.88, green: 0.94, blue: 1, alpha: 0.78).cgColor
        particles.frame = root.bounds
        root.addSublayer(caps)
        root.addSublayer(particles)
    }

    func update(_ global: [SnowEdge]) -> Bool {
        let edges = global.map { SnowGeometry.local($0, screen: bounds, size: root.bounds.size) }
        guard edges != last else { return false }
        last = edges
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGMutablePath()
        for edge in edges {
            let length = edge.end - edge.start
            let count = max(1, Int(length / 140))
            let section = length / CGFloat(count)
            for i in 0..<count {
                let start = edge.start + CGFloat(i) * section + min(8, section * 0.06)
                let end = start + section * (i % 3 == 1 ? 0.59 : 0.82)
                let width = end - start, y = edge.top + 0.35
                path.move(to: CGPoint(x: start, y: y))
                path.addCurve(to: CGPoint(x: start + width * 0.53, y: y + 2.3),
                              control1: CGPoint(x: start + width * 0.12, y: y + 0.3),
                              control2: CGPoint(x: start + width * 0.22, y: y + 3.8))
                path.addCurve(to: CGPoint(x: end, y: y),
                              control1: CGPoint(x: start + width * 0.71, y: y + 1.0),
                              control2: CGPoint(x: start + width * 0.86, y: y + 2.8))
                path.closeSubpath()
            }
        }
        caps.path = path
        // Keep existing animations alive while a window moves. Reposition
        // their anchor layers; animate only a mote's transform and opacity.
        let anchors = Array(edges.filter { $0.end - $0.start > 95 }.prefix(8))
        while (particles.sublayers?.count ?? 0) > anchors.count { particles.sublayers?.last?.removeFromSuperlayer() }
        for (i, edge) in anchors.enumerated() {
            let mote: CALayer
            if let existing = particles.sublayers, i < existing.count { mote = existing[i] }
            else { mote = makeMote(i); particles.addSublayer(mote) }
            let fraction = [0.34, 0.65, 0.43, 0.77][i % 4]
            mote.position = CGPoint(x: edge.start + (edge.end - edge.start) * CGFloat(fraction), y: edge.top + 2)
        }
        if edges.isEmpty { panel.orderOut(nil) }
        else if !panel.isVisible { panel.orderFrontRegardless() }
        return true
    }

    private func makeMote(_ i: Int) -> CALayer {
        let mote = CALayer()
        mote.bounds = CGRect(x: 0, y: 0, width: 1.8, height: 1.8)
        mote.cornerRadius = 0.9
        mote.opacity = 0
        mote.backgroundColor = NSColor(calibratedRed: 0.92, green: 0.96, blue: 1, alpha: 1).cgColor
        let drift = CAKeyframeAnimation(keyPath: "transform.translation")
        drift.values = [NSValue(size: NSSize(width: -3, height: 21)),
                        NSValue(size: NSSize(width: 1.5, height: 12)),
                        NSValue(size: NSSize(width: 0, height: 0))]
        drift.keyTimes = [0, 0.5, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.60, 0.64, 0]; fade.keyTimes = [0, 0.18, 0.78, 1]
        let duration = 2.8 + Double(i % 3) * 0.3
        drift.duration = duration; fade.duration = duration
        let group = CAAnimationGroup()
        group.animations = [drift, fade]
        group.duration = duration + 3.1 + Double(i % 4) * 0.6
        group.timeOffset = Double(i) * 1.43
        group.repeatCount = .infinity
        mote.add(group, forKey: "drift")
        return mote
    }

    func close() {
        particles.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor final class WindowSnow: NSObject {
    private var enabled = false
    private var displayAsleep = false
    private var systemAsleep = false
    private var finished = false
    private var screens: [SnowScreen] = []
    private var timer: Timer?
    private var lastChange: TimeInterval = 0

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(preferencesChanged(_:)), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(powerChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(powerChanged(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(powerChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(powerChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func setEnabled(_ flag: Bool) { enabled = flag; reconcile() }

    func shutdown() {
        finished = true
        stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func powerChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification: displayAsleep = true
        case NSWorkspace.screensDidWakeNotification: displayAsleep = false
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        default: break
        }
        reconcile()
    }
    @objc private func preferencesChanged(_ note: Notification) { reconcile() }
    @objc private func displayChanged(_ note: Notification) { stop(); reconcile() }
    @objc private func spaceChanged(_ note: Notification) {
        timer?.invalidate(); timer = nil
        reconcile()
    }

    private func reconcile() {
        guard !finished, enabled, !displayAsleep, !systemAsleep, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop(); return }
        if screens.isEmpty { screens = NSScreen.screens.compactMap(SnowScreen.init) }
        if timer == nil && !screens.isEmpty { refresh() }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        screens.forEach { $0.close() }
        screens.removeAll()
    }

    @objc private func refresh() {
        let overlayIDs = Set(screens.map { $0.panel.windowNumber })
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = records.compactMap { row -> SnowWindow? in
            guard let id = row[kCGWindowNumber as String] as? Int, !overlayIDs.contains(id),
                  let level = row[kCGWindowLayer as String] as? Int, level >= 0,
                  let owner = row[kCGWindowOwnerPID as String] as? Int,
                  let values = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
                  !rect.isEmpty, (row[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.02 else { return nil }
            return SnowWindow(bounds: rect, level: level, owner: owner)
        }
        var changed = false
        for screen in screens {
            let edges = SnowGeometry.visibleEdges(windows: windows, screen: screen.bounds, usable: screen.usable)
            if screen.update(edges) { changed = true }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if changed { lastChange = now }
        let visible = screens.contains { $0.panel.isVisible }
        let tracking = now - lastChange < 0.65
        let interval = tracking ? 1.0 / 30.0 : (visible ? 0.20 : 0.85)
        let next = Timer(timeInterval: interval, target: self, selector: #selector(refresh), userInfo: nil, repeats: false)
        next.tolerance = interval * (tracking ? 0.04 : 0.12)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}
