import CoreGraphics
import Foundation

/// All coordinates in the plan are feet on the painted ground. A single projection
/// places the house, its native door, and the civic buildings on each display.
struct VillageComposition: Decodable {
    struct Parcel: Decodable {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
    }
    let width: CGFloat
    let height: CGFloat
    let streets: [[Parcel]]

    struct Projection {
        let frame: CGRect
        let scale: CGFloat
        let origin: CGPoint
        let size: CGSize

        init(_ frame: CGRect, width: CGFloat, height: CGFloat) {
            self.frame = frame
            scale = max(frame.width / width, frame.height / height)
            size = CGSize(width: width * scale, height: height * scale)
            let narrow = frame.width <= 580
            origin = CGPoint(x: frame.minX + (frame.width - size.width) * (narrow ? 0.49 : 0.57),
                             y: frame.minY + (frame.height - size.height) * (narrow ? 0.50 : 0.56))
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + size.width * x, y: origin.y + size.height * y)
        }
        func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: width * size.width, height: height * size.height))
        }
        var postOffice: CGRect {
            let center = point(0.2222, 0.5285)
            let w = size.width * 0.12, h = w * 0.84
            return CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h)
        }
        var clockFace: CGRect {
            let center = point(0.09, 0.372)
            let side = max(28, size.width * 0.040)
            return CGRect(x: center.x - side/2, y: center.y - side/2, width: side, height: side)
        }
    }

    static func load(from url: URL) throws -> VillageComposition {
        let plan = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard plan.width > 0, plan.height > 0, !plan.streets.isEmpty,
              plan.streets.allSatisfy({ !$0.isEmpty && $0.allSatisfy({
                  (0...1).contains($0.x) && (0...1).contains($0.y) && $0.size > 0
              }) }) else { throw CocoaError(.fileReadCorruptFile) }
        return plan
    }

    /// Fixed-size foreground props stay legible on large displays. Choose one clear
    /// patch of ground before assigning any cottage addresses.
    static func playgroundSite(usable: CGRect, obstacles: [CGRect]) -> CGRect? {
        let edge: CGFloat = 10
        let width = min(464, max(325, usable.width * 0.36), usable.width - edge * 2)
        let height = min(122, max(95, usable.height * 0.14), usable.height * 0.28)
        guard width >= 185, height >= 72 else { return nil }
        let left = usable.minX + edge, right = usable.maxX - edge - width
        for lift: CGFloat in [0, height * 0.65, height * 1.3] {
            for center: CGFloat in [0.5, 0.76, 0.24, 1, 0] {
                let x = min(right, max(left, usable.minX + center * usable.width - width / 2))
                let rect = CGRect(x:x, y:usable.maxY - edge - height - lift, width:width, height:height)
                if usable.contains(rect), !obstacles.contains(where: { $0.intersects(rect.insetBy(dx:-3, dy:-3)) }) {
                    return rect
                }
            }
        }
        return nil
    }

    /// Pack in art coordinates first. On cropped displays, fill visible stretches of
    /// the same terrain before resorting to the folder directory in the menu bar.
    func plots(ids: [String], display: CGDirectDisplayID, frame: CGRect,
               usable: CGRect, widgets: [CGRect], preferred: [String: Int] = [:]) -> [DesktopHouseInteraction.Plot] {
        guard !ids.isEmpty, !frame.isEmpty else { return [] }
        let art = Projection(frame, width: width, height: height)
        var obstacles = widgets.map { $0.insetBy(dx: -6, dy: -5) }
        if let field = Self.playgroundSite(usable:usable, obstacles:widgets) { obstacles.append(field.insetBy(dx:-4,dy:-4)) }
        obstacles.append(art.rect(x: 0, y: 0.32, width: 0.303, height: 0.318))
        let bounds = usable.insetBy(dx: 4, dy: 4)
        var placed: [DesktopHouseInteraction.Plot] = []
        let names = ids.sorted()
        func place(_ id: String, ground: CGPoint, size: CGFloat) -> Bool {
            let center = CGPoint(x: ground.x, y: ground.y - size * 0.38)
            let box = CGRect(x: center.x - size/2, y: center.y - size/2, width: size, height: size)
            guard bounds.contains(box), !obstacles.contains(where: { $0.intersects(box) }) else { return false }
            obstacles.append(box.insetBy(dx: -4, dy: -2))
            placed.append(.init(id: id, center: center, size: size, display: display, frame: frame))
            return true
        }
        // Distribute even a handful of houses between near and far streets.
        var parcels: [Parcel] = []
        for column in [2, 3, 5, 0, 4, 1] {
            for (row, street) in streets.enumerated() {
                parcels.append(street[(column + row) % street.count])
            }
        }
        func use(_ parcel: Parcel, for id: String) -> Bool {
            place(id, ground: art.point(parcel.x, parcel.y), size: min(145, max(38, parcel.size * art.scale)))
        }
        // Reserve everyone's own address before rehoming a cottage covered by a widget.
        var waiting: [String] = []
        if !widgets.isEmpty {
            // Resolve everyone's permanent address first, including houses that had
            // to leave a parcel to make room for the foreground meadow. One new
            // widget can then displace only the neighbors it actually covers.
            let baseline = plots(ids:ids, display:display, frame:frame, usable:usable,
                                 widgets:[], preferred:preferred)
            for home in baseline {
                let feet = CGPoint(x:home.center.x,y:home.center.y+home.size*0.38)
                if !place(home.id,ground:feet,size:home.size) { waiting.append(home.id) }
            }
            let assigned = Set(baseline.map(\.id))
            waiting += names.filter { !assigned.contains($0) }
        } else {
            for (index, id) in names.enumerated() {
                let address = preferred[id] ?? index
                if !parcels.indices.contains(address) || !use(parcels[address], for: id) { waiting.append(id) }
            }
        }
        var next = 0
        for parcel in parcels where next < waiting.count {
            if use(parcel, for: waiting[next]) { next += 1 }
        }
        guard next < waiting.count else { return placed }
        let horizon = max(bounds.minY, art.point(0.5, 0.37).y)
        let bottom = min(bounds.maxY, art.point(0.5, 0.93).y)
        guard bottom > horizon else { return placed }
        for row in 0..<7 {
            let depth = CGFloat(row) / 6
            let feetY = horizon + (bottom - horizon) * depth
            let side = max(36, min(66, frame.width * 0.043 + 12 * depth))
            let span = side * 1.40
            var x = bounds.minX + side * 0.55 + (row.isMultiple(of: 2) ? 0 : span/2)
            while x < bounds.maxX && next < waiting.count {
                let bend = sin((x - frame.minX) / frame.width * 3 * .pi + depth) * side * 0.17
                if place(waiting[next], ground: CGPoint(x: x, y: feetY + bend), size: side) { next += 1 }
                x += span
            }
        }
        return placed
    }

    @MainActor func checkGeometry() -> Bool {
        let ids = (1...18).map { "cottage-" + String($0) }
        for size in [CGSize(width: 1470, height: 956), CGSize(width: 1280, height: 720),
                     CGSize(width: 768, height: 1024), CGSize(width: 2560, height: 1080)] {
            let frame = CGRect(origin: CGPoint(x: -1536, y: -210), size: size)
            let usable = frame.insetBy(dx: 0, dy: 35)
            let widget = CGRect(x: frame.minX + 12, y: frame.minY + 42, width: 330, height: 150)
            let placed = plots(ids: ids, display: 2, frame: frame, usable: usable, widgets: [widget])
            let repeated = plots(ids: Array(ids.reversed()), display: 2, frame: frame, usable: usable, widgets: [widget])
            guard Set(placed.map(\.id)) == Set(ids), placed == repeated else { return false }
            guard let field = Self.playgroundSite(usable:usable,obstacles:[widget]), usable.contains(field) else { return false }
            var occupied = [widget, field]
            for plot in placed {
                let door = PorchTargets.Door(plot: plot, drawHouse: true, folder: nil, title: "")
                guard usable.contains(door.target), !occupied.contains(where: { $0.intersects(door.target) }),
                      let groundX = plot.payload["x"] as? CGFloat, let groundY = plot.payload["y"] as? CGFloat,
                      abs(frame.minX + groundX * size.width - door.target.midX) < 0.01,
                      abs(frame.minY + groundY * size.height - (door.target.minY + plot.size * 0.88)) < 0.01
                else { return false }
                occupied.append(door.target)
            }
            if size.width == 1470, let first = placed.first {
                let covering = CGRect(x: first.center.x - 4, y: first.center.y - 4, width: 8, height: 8)
                let shifted = plots(ids: ids, display: 2, frame: frame, usable: usable, widgets: [widget, covering])
                guard shifted.count == ids.count, !shifted.contains(first),
                      placed.dropFirst().allSatisfy(shifted.contains) else { return false }
            }
            guard plots(ids: ids, display: 2, frame: frame, usable: usable, widgets: [frame]).isEmpty else { return false }
        }
        return true
    }
}
