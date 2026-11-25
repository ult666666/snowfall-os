import CoreGraphics

/// Doorways in the bundled village painting. Coordinates use the image's
/// upper-left origin. The caller owns desktop visibility, occlusion and input.
enum ScenicCottages {
    private struct Cottage {
        let id: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    private static let cottages = [
        Cottage(id: "scenery-bakery", x: 0.2222, y: 0.5285, width: 0.1200),
        Cottage(id: "scenery-lantern", x: 0.0967, y: 0.5053, width: 0.0611)
    ]

    static func plots(for display: CGDirectDisplayID, frame: CGRect) -> [DesktopHouseInteraction.Plot] {
        guard frame.width > 0, frame.height > 0, !frame.isInfinite, !frame.isNull else { return [] }
        // Match #wallpaper's object-fit: cover and object-position at both CSS breakpoints.
        let scale = max(frame.width / 2560, frame.height / 1600)
        let width = 2560 * scale, height = 1600 * scale
        let narrow = frame.width <= 580
        let x = frame.minX + (frame.width - width) * (narrow ? 0.49 : 0.57)
        let y = frame.minY + (frame.height - height) * (narrow ? 0.5 : 0.56)
        return cottages.compactMap { cottage in
            let point = CGPoint(x: x + width * cottage.x, y: y + height * cottage.y)
            guard frame.contains(point) else { return nil }
            // A visible door near a cropped edge should never take clicks on a different display.
            let edge = min(point.x - frame.minX, frame.maxX - point.x, point.y - frame.minY, frame.maxY - point.y)
            let size = min(100, width * cottage.width, 2 * edge)
            guard size >= 20 else { return nil }
            return DesktopHouseInteraction.Plot(id: cottage.id, center: point, size: size, display: display, frame: frame)
        }
    }
}
