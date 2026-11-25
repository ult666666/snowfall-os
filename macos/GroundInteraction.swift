import AppKit

/// Routes open snow gestures below native desktop controls. Mouse observation
/// leaves Finder in charge of its own selection, menu and drag gestures.
@MainActor final class GroundInteraction {
    struct Surface {
        let id: NSNumber
        let frame: CGRect       // Global Quartz coordinates, positive y down.
        let usable: CGRect
        let finderVisible: Bool
        let blocked: [CGRect]
    }
    var surfaces: () -> [Surface] = { [] }
    var onInput: ((NSNumber, String, CGPoint, TimeInterval?) -> Void)?
    var canReadDesktop: () -> Bool = { false }
    private(set) var passiveInputs = 0
    private(set) var finderMapped = false
    private var receivers: [NSNumber: Receiver] = [:]
    private var globalMouse: Any?
    private var localMouse: Any?
    private var moveMouse: Any?
    private var environmentalObservers: [NSObjectProtocol] = []
    private var active: (display: NSNumber, point: CGPoint, pressedAt: TimeInterval)?
    private var fighting: Set<NSNumber> = []
    private var lastMove = -Double.infinity
    private var finderUpdated = -Double.infinity
    private var finderItems: [CGPoint]?
    private(set) var gestures = 0
    var observing: Bool { globalMouse != nil }

    func start() {
        guard globalMouse == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown,.leftMouseUp,.leftMouseDragged]
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.observe($0) }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // A click delivered to an ordinary Snowfall window belongs to that window.
            if event.type == .leftMouseDown { self?.cancel() }
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        environmentalObservers.append(workspace.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = activated?.bundleIdentifier, !["com.apple.finder","com.apple.dock","com.apple.WindowManager"].contains(id) {
                Task { @MainActor in self?.cancel() }
            }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification,NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            environmentalObservers.append(workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            })
        }
    }
    func stop() {
        cancel()
        for observer in [globalMouse,localMouse,moveMouse].compactMap({$0}) { NSEvent.removeMonitor(observer) }
        environmentalObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        environmentalObservers.removeAll()
        receivers.values.forEach { $0.close() }
        receivers.removeAll()
        globalMouse = nil; localMouse = nil; moveMouse = nil; fighting.removeAll()
    }
    func cancel() {
        if let press = active { onInput?(press.display,"cancel",press.point,nil) }
        active = nil
    }
    func setFighting(_ enabled: Bool, display: NSNumber) {
        if enabled { fighting.insert(display) } else { fighting.remove(display) }
        receivers[display]?.trackPointer(enabled)
        if !fighting.isEmpty, globalMouse != nil, moveMouse == nil {
            moveMouse = NSEvent.addGlobalMonitorForEvents(matching:.mouseMoved) { [weak self] in self?.observe($0) }
        } else if fighting.isEmpty, let moveMouse {
            NSEvent.removeMonitor(moveMouse); self.moveMouse = nil
        }
    }

    /// On a desktop with Finder icons hidden there may be no application window
    /// to receive an empty click. Supply a receiver behind the system wallpaper.
    /// Finder, widgets, Dock, and even the system wallpaper's own controls sit
    /// above it. Its pixels never alter the visible artwork.
    func syncReceivers(testing: Bool) {
        let available = surfaces()
        let ids = Set(available.map(\.id))
        for id in Array(receivers.keys) where !ids.contains(id) {
            if active?.display == id { cancel() }
            receivers.removeValue(forKey:id)?.close()
        }
        for surface in available {
            guard let screen = NSScreen.screens.first(where:{ $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == surface.id }) else { continue }
            let panel = receivers[surface.id] ?? Receiver()
            if panel.frame != screen.visibleFrame { panel.setFrame(screen.visibleFrame,display:false) }
            panel.input = { [weak self, weak panel] event in
                guard let self, let panel else { return }
                let cocoa = panel.convertPoint(toScreen:event.locationInWindow)
                let point = CGPoint(x:surface.frame.minX+(cocoa.x-screen.frame.minX)*surface.frame.width/screen.frame.width,
                                    y:surface.frame.minY+(screen.frame.maxY-cocoa.y)*surface.frame.height/screen.frame.height)
                self.route(event,at:point) { candidate in
                    guard candidate.id == surface.id else { return false }
                    if event.type == .leftMouseDragged || event.type == .leftMouseUp,
                       let previous = self.active?.point {
                        let fix = CGPoint(x:surface.frame.minX+previous.x*surface.frame.width,y:surface.frame.minY+previous.y*surface.frame.height)
                        if hypot(fix.x-point.x,fix.y-point.y)>4 && !testing {
                            let above = NSWindow.windowNumber(at:cocoa,belowWindowWithWindowNumber:0)
                            return above == 0 || above == panel.windowNumber
                        }
                    }
                    return true
                }
            }
            panel.trackPointer(fighting.contains(surface.id))
            if !panel.isVisible {
                if testing { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
            }
            receivers[surface.id] = panel
        }
    }
    func hitPoint(_ p: CGPoint) -> [String:Any] {
        for s in surfaces() {
            let q = CGPoint(x:s.frame.minX+p.x*s.frame.width,y:s.frame.minY+p.y*s.frame.height)
            guard let panel = receivers[s.id], panel.isVisible, s.usable.contains(q),
                  !s.blocked.contains(where:{$0.contains(q)}),
                  let screen = NSScreen.screens.first(where:{ $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == s.id }) else {continue}
            let cocoa = CGPoint(x:screen.frame.minX+p.x*screen.frame.width,y:screen.frame.maxY-p.y*screen.frame.height)
            guard !s.finderVisible || outsideFinderItems(q) else {continue}
            let top = NSWindow.windowNumber(at:cocoa,belowWindowWithWindowNumber:0)
            let rows = top > 0 ? CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(top)) as? [[String:Any]] : nil
            let passive = rows?.first.map { desktopOwner($0,point:q,surface:s) } ?? false
            return ["x":Int(q.x),"y":Int(q.y),"window":panel.windowNumber,
                    "exposed":top == panel.windowNumber,"passiveExposed":passive]
        }
        return [:]
    }

    private final class Receiver: NSPanel {
        var input: ((NSEvent) -> Void)?
        private var pointerTracking: NSTrackingArea?
        func trackPointer(_ enabled: Bool) {
            guard let contentView, enabled != (pointerTracking != nil) else { return }
            acceptsMouseMovedEvents = enabled
            if enabled {
                let tracking = NSTrackingArea(rect:.zero,options:[.activeAlways,.mouseMoved,.inVisibleRect],owner:contentView,userInfo:nil)
                contentView.addTrackingArea(tracking); pointerTracking = tracking
            } else if let tracking = pointerTracking {
                contentView.removeTrackingArea(tracking); pointerTracking = nil
            }
        }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        init() {
            super.init(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            // Two levels under the public desktop layer, ahead of WindowServer's
            // permanent backing window and behind macOS's own wallpaper windows.
            level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopWindow))-2)
            collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle]
            isOpaque=false; backgroundColor=NSColor(white:0.95,alpha:0.018); hasShadow=false
            isReleasedWhenClosed=false; isExcludedFromWindowsMenu=true; hidesOnDeactivate=false
            canHide=false; isMovable=false; animationBehavior = .none
            title = "Open snow"
        }
        override func constrainFrameRect(_ rect:NSRect,to screen:NSScreen?) -> NSRect { rect }
        override func sendEvent(_ event:NSEvent) {
            switch event.type {
            case .leftMouseDown,.leftMouseDragged,.leftMouseUp,.mouseMoved: input?(event)
            default: super.sendEvent(event)
            }
        }
    }

    /// Use the WindowServer's receiver when available. Some versions report a
    /// targetless desktop click; inspect the visible window stack in that case.
    private func desktopOwner(_ row: [String:Any], point:CGPoint, surface:Surface) -> Bool {
        guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let level = row[kCGWindowLayer as String] as? Int,
              let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation:raw as CFDictionary),bounds.contains(point) else { return false }
        let bundle = NSRunningApplication(processIdentifier:pid)?.bundleIdentifier
        return Self.isBackgroundWindow(bundle:bundle,level:level,bounds:bounds,usable:surface.usable)
    }

    static func isBackgroundWindow(bundle: String?, level: Int, bounds: CGRect, usable: CGRect) -> Bool {
        // The wallpaper agent on macOS Tahoe also uses desktopWindow - 2.
        // A small window at the very same level may be a widget or Dock control.
        guard bounds.contains(usable.insetBy(dx:2,dy:2)) else { return false }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        if level == iconLevel { return bundle == "com.apple.finder" || bundle == "com.apple.WindowManager" }
        let firstWallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow)) - 2
        return (firstWallpaperLevel..<iconLevel).contains(level)
            && ["com.apple.dock","com.apple.wallpaper.agent","com.apple.WindowManager"].contains(bundle ?? "")
    }

    private func clickThrough(_ row: [String:Any]) -> Bool {
        guard row[kCGWindowOwnerPID as String] as? Int32 == ProcessInfo.processInfo.processIdentifier,
              let number = row[kCGWindowNumber as String] as? Int else { return false }
        return NSApp.window(withWindowNumber:number)?.ignoresMouseEvents == true
    }

    private func isDesktop(_ event: NSEvent, at point: CGPoint, surface: Surface) -> Bool {
        if let cg = event.cgEvent {
            for n in [cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
                      Int64(event.windowNumber)] where n > 0 && n <= Int64(UInt32.max) {
                if let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(n)) as? [[String:Any]],
                   let row = rows.first, row[kCGWindowNumber as String] as? Int64 == n {
                    // Desktop composition can change between down and up. Quartz
                    // may name our visible but click-through wallpaper on either
                    // event; keep looking for the window that actually receives it.
                    if clickThrough(row) { continue }
                    return desktopOwner(row,point:point,surface:surface)
                }
            }
            let pid = cg.getIntegerValueField(.eventTargetUnixProcessID)
            if pid > 0, pid <= Int64(Int32.max),
               let app = NSRunningApplication(processIdentifier: Int32(pid)),
               let bundle = app.bundleIdentifier,
               !["com.apple.finder","com.apple.dock","com.apple.wallpaper.agent","com.apple.WindowManager"].contains(bundle) {
                return false
            }
        }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        for row in rows {
            guard let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation:raw as CFDictionary), rect.contains(point),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            if clickThrough(row) { continue }
            return desktopOwner(row,point:point,surface:surface)
        }
        return false
    }

    private func localFinderPositions() -> [CGPoint]? {
        let finder = UserDefaults(suiteName:"com.apple.finder")
        let desktop = finder?.dictionary(forKey:"DesktopViewSettings")
        let view = desktop?["IconViewSettings"] as? [String:Any]
        guard canReadDesktop(), NSScreen.screens.count == 1,
              (desktop?["GroupBy"] as? String ?? "None").lowercased() == "none",
              ["none","grid"].contains((view?["arrangeBy"] as? String ?? "none").lowercased()) else { return nil }
        let files = FileManager.default, root = files.urls(for:.desktopDirectory,in:.userDomainMask)[0]
        guard let entries = try? files.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles) else {return nil}
        let names = Set(entries.map(\.lastPathComponent))
        let frame = CGDisplayBounds(CGMainDisplayID())
        let volumeRecords = finder?.dictionary(forKey:"FXDesktopVolumePositions") ?? [:]
        var volumes: [CGPoint] = []
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey,.volumeIsInternalKey,.volumeIsRemovableKey,.volumeNameKey]
        for url in files.mountedVolumeURLs(includingResourceValuesForKeys:Array(keys),options:.skipHiddenVolumes) ?? [] {
            guard let v = try? url.resourceValues(forKeys:keys), let name=v.volumeName else { return nil }
            let key = v.volumeIsLocal == false ? "ShowMountedServersOnDesktop" :
                v.volumeIsRemovable == true ? "ShowRemovableMediaOnDesktop" :
                v.volumeIsInternal == true ? "ShowHardDrivesOnDesktop" : "ShowExternalHardDrivesOnDesktop"
            guard finder?.bool(forKey:key) == true else {continue}
            // Mounted volumes use separate Finder preferences. Multiple dated
            // entries can match a volume title; protect all plausible positions.
            let candidates = volumeRecords.filter { $0.key.hasPrefix(name+"_") }
            guard !candidates.isEmpty else {return nil}
            for value in candidates.values {
                guard let r = value as? [String:Any], let a = r["AnchorRelativeTo"] as? Int, (0...4).contains(a),
                      let dx = r["xRelative"] as? Double, let dy = r["yRelative"] as? Double else {return nil}
                let x = (a == 0 ? frame.midX : dx<0 ? frame.maxX : frame.minX) + dx
                let y = (a == 0 ? frame.midY : dy<0 ? frame.maxY : frame.minY) + dy
                volumes.append(CGPoint(x:x,y:y))
            }
        }
        if names.isEmpty { return volumes }
        let store = root.appendingPathComponent(".DS_Store")
        guard let size = try? store.resourceValues(forKeys:[.fileSizeKey]).fileSize, size<=16*1024*1024,
              let data = try? Data(contentsOf:store,options:.mappedIfSafe) else { return nil }
        let points = FinderLayout.points(in:data,for:names,screen:CGDisplayBounds(CGMainDisplayID()).size)
        return points.count == names.count ? Array(points.values) + volumes : nil
    }

    private func outsideFinderItems(_ point: CGPoint) -> Bool {
        // This is only used when Finder actually draws its desktop layer. Ask
        // for authoritative item positions only with previously granted access.
        // If the layout is unknown, preserve Finder's entire surface.
        let time = ProcessInfo.processInfo.systemUptime
        if time - finderUpdated > 1 {
            finderUpdated = time
            finderItems = localFinderPositions() ?? DesktopHouseInteraction.authorizedFinderPositions().map { Array($0.values) }
            finderMapped = finderItems != nil
        }
        guard let finderItems else { return false }
        let defaults = UserDefaults(suiteName:"com.apple.finder")?.dictionary(forKey:"DesktopViewSettings")
        let view = defaults?["IconViewSettings"] as? [String:Any]
        guard (defaults?["GroupBy"] as? String ?? "None").lowercased() == "none" else { return false }
        let icon = CGFloat(view?["iconSize"] as? Double ?? 64)
        return !finderItems.contains { center in
            // Includes both underneath and right-hand labels, enlarged icons,
            // and the selection halo surrounding each item.
            CGRect(x:center.x-max(76,icon*0.65),y:center.y-icon*0.6,
                   width:max(190,icon*1.6+105),height:icon*1.2+42).contains(point)
        }
    }

    private func observe(_ event: NSEvent) {
        guard let point = event.cgEvent?.location else { cancel(); return }
        let before = gestures
        route(event, at:point) { self.isDesktop(event,at:point,surface:$0) }
        if gestures != before { passiveInputs += 1 }
    }

    private func route(_ event: NSEvent, at point: CGPoint, desktop: (Surface) -> Bool) {
        let kind = event.type
        if kind == .leftMouseDown { cancel() }
        if kind != .leftMouseDown && active == nil && !(kind == .mouseMoved && !fighting.isEmpty) { return }
        if kind == .mouseMoved || kind == .leftMouseDragged {
            if event.timestamp-lastMove < 0.065 { return }
            lastMove = event.timestamp
        }
        guard event.modifierFlags.intersection([.control,.option,.shift,.command]).isEmpty,
              let surface = surfaces().first(where:{ $0.usable.contains(point) }),
              active == nil || active?.display == surface.id,
              kind != .mouseMoved || fighting.contains(surface.id),
              !surface.blocked.contains(where:{ $0.contains(point) }), desktop(surface),
              !surface.finderVisible || outsideFinderItems(point) else { cancel(); return }
        let p = CGPoint(x:(point.x-surface.frame.minX)/surface.frame.width,
                        y:(point.y-surface.frame.minY)/surface.frame.height)
        switch kind {
        case .leftMouseDown:
            active = (surface.id,p,event.timestamp)
            gestures += 1
            onInput?(surface.id,"down",p,nil)
        case .leftMouseDragged:
            active?.point = p
            onInput?(surface.id,"move",p,nil)
        case .mouseMoved:
            onInput?(surface.id,"move",p,nil)
        case .leftMouseUp:
            guard let press = active else { return }
            active = nil
            onInput?(surface.id,"up",p,max(0,event.timestamp - press.pressedAt))
        default: break
        }
    }

    /// Feed the passive monitor a hardware-shaped event for a real system
    /// desktop receiver. This never posts input to Finder or moves the pointer.
    func checkObservedEvent(_ type: NSEvent.EventType, point: CGPoint, surface: Surface,
                            timestamp: TimeInterval, clickThroughWindow: NSWindow? = nil) -> Bool {
        let q = CGPoint(x:surface.frame.minX+point.x*surface.frame.width,
                        y:surface.frame.minY+point.y*surface.frame.height)
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        guard let row = rows.first(where:{desktopOwner($0,point:q,surface:surface)}),
              let number = row[kCGWindowNumber as String] as? Int,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let event = NSEvent.mouseEvent(with:type,location:.zero,modifierFlags:[],timestamp:timestamp,
                  windowNumber:number,context:nil,eventNumber:0,clickCount:1,pressure:1),
              let cg = event.cgEvent else {return false}
        cg.location = q
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                value:Int64(clickThroughWindow?.windowNumber ?? number))
        cg.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        guard let reconstructed = NSEvent(cgEvent:cg) else {return false}
        observe(reconstructed)
        return true
    }

    /// Deliver AppKit mouse events only to this process's isolated test windows.
    func checkEvent(_ type: NSEvent.EventType, point: CGPoint, surface: Surface,
                    window: NSWindow, modifiers: NSEvent.ModifierFlags = [], desktop: Bool = true) -> Bool {
        guard let panel = receivers[surface.id],
              let screen = NSScreen.screens.first(where:{ $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == surface.id }) else {return false}
        let target = desktop ? panel : window
        let cocoa = CGPoint(x:screen.frame.minX+point.x*screen.frame.width,y:screen.frame.maxY-point.y*screen.frame.height)
        guard let event = NSEvent.mouseEvent(with:type,location:target.convertPoint(fromScreen:cocoa),modifierFlags:modifiers,
            timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:target.windowNumber,
            context:nil,eventNumber:0,clickCount:1,pressure:1) else {return false}
        target.sendEvent(event)
        return true
    }
}
