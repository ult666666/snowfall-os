import AppKit
import CoreGraphics

/// Matches desktop widget surfaces using public process, layer and bounds metadata.
@MainActor final class WidgetFrames: NSObject {
    struct Candidate {
        let bounds: CGRect
        let layer: Int
        let belongsToHost: Bool
        let visible: Bool
    }

    typealias Frames = [[String: Double]]

    private let onChange: (CGDirectDisplayID, Frames) -> Void
    private var lastFrames: [CGDirectDisplayID: Frames] = [:]
    private var timer: Timer?
    private var running = false
    private var systemAsleep = false
    private var screensAsleep = false
    private var lastMove: TimeInterval = -.infinity

    init(onChange: @escaping (CGDirectDisplayID, [[String: Double]]) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        systemAsleep = false
        screensAsleep = false
        lastMove = -.infinity
        let old = lastFrames
        lastFrames.removeAll()
        for (id, frames) in old where !frames.isEmpty { onChange(id, []) }
    }

    /// A newly created wallpaper view needs a snapshot even when nothing has moved.
    func refresh() {
        poll(force: true)
    }

    @objc private func environmentChanged(_ note: Notification) {
        switch note.name {
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        default: break
        }
        refresh()
    }

    private func poll(force: Bool) {
        timer?.invalidate()
        timer = nil
        guard !systemAsleep, !screensAsleep else { return }
        var displays: [CGDirectDisplayID: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            displays[id] = CGDisplayBounds(id)
        }
        let latest = Self.normalizedFrames(Self.candidates(), displays: displays)
        let previous = lastFrames
        lastFrames = latest
        for id in previous.keys where latest[id] == nil { onChange(id, []) }
        for (id, frames) in latest where force || previous[id] != frames { onChange(id, frames) }
        guard running else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force && latest != previous { lastMove = now }
        let dragging = NSEvent.pressedMouseButtons & 1 != 0 || now - lastMove < 0.65
        let interval: TimeInterval = dragging ? 0.14 : 0.9
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.poll(force: false)
            }
        }
        next.tolerance = dragging ? 0.012 : 0.10
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private static func desktopLayer(_ value: Int) -> Bool {
        let base = Int(CGWindowLevelForKey(.desktopIconWindow))
        return (base + 1 ... base + 3).contains(value)
    }

    private static func widgetSize(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            (80...850).contains(rect.width) && (80...650).contains(rect.height)
    }

    static func matchesHost(_ bundle: String?) -> Bool {
        bundle?.caseInsensitiveCompare("com.apple.notificationcenterui") == .orderedSame
    }

    private static func candidates() -> [Candidate] {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        // Resolve owners only after checking layer and size. Do not access titles or window contents.
        var ownerCache: [pid_t: Bool] = [:]
        return windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, desktopLayer(layer),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), widgetSize(rect),
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            if ownerCache[pid] == nil {
                ownerCache[pid] = matchesHost(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            guard ownerCache[pid] == true else { return nil }
            return Candidate(bounds: rect, layer: layer, belongsToHost: true, visible: true)
        }
    }

    /// Quartz uses global top-left coordinates, including for displays left of or above the main one.
    /// A surface crossing a seam belongs to its largest visible slice. Mirror ties use the lowest display ID.
    static func normalizedFrames(_ candidates: [Candidate], displays: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: Frames] {
        let sortedIDs = displays.keys.sorted()
        var result = displays.mapValues { _ in Frames() }
        for item in candidates {
            guard item.visible, item.belongsToHost, desktopLayer(item.layer), widgetSize(item.bounds) else { continue }
            var chosen: (id: CGDirectDisplayID, screen: CGRect, visible: CGRect)?
            var largestArea: CGFloat = 0
            for id in sortedIDs {
                guard let screen = displays[id], !screen.isEmpty else { continue }
                let rect = item.bounds.intersection(screen)
                guard !rect.isNull, !rect.isEmpty else { continue }
                // A fullscreen surface can still fit the nominal widget bounds on a small display.
                if item.bounds.insetBy(dx: -1, dy: -1).contains(screen) { continue }
                let area = rect.width * rect.height
                if area > largestArea { largestArea = area; chosen = (id, screen, rect) }
            }
            guard let match = chosen else { continue }
            let screen = match.screen, visible = match.visible
            func unit(_ value: CGFloat) -> Double {
                (min(1, max(0, Double(value))) * 1_000_000).rounded() / 1_000_000
            }
            let left = unit((visible.minX - screen.minX) / screen.width)
            let top = unit((visible.minY - screen.minY) / screen.height)
            let right = unit((visible.maxX - screen.minX) / screen.width)
            let bottom = unit((visible.maxY - screen.minY) / screen.height)
            let frame = ["x": left, "y": top, "width": right-left, "height": bottom-top]
            if result[match.id]?.contains(frame) == false { result[match.id]?.append(frame) }
        }
        for id in sortedIDs {
            result[id]?.sort { a, b in
                for key in ["y", "x", "height", "width"] where a[key] != b[key] {
                    return (a[key] ?? 0) < (b[key] ?? 0)
                }
                return false
            }
        }
        return result
    }
}
