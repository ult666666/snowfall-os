import CoreGraphics
import Foundation
import ImageIO

/// Reproduce the live station facade beneath native widgets using only their bounds.
enum WidgetStill {
    static func draw(_ rectangles: [CGRect], in ctx: CGContext, frame: CGRect, assets: URL) throws {
        let visible = rectangles.filter { !$0.isEmpty && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite }
        guard !visible.isEmpty, !frame.isEmpty else { return }
        let url = assets.appendingPathComponent("widget-cottage.webp")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let trim = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        var sites = visible.map { CGRect(x: $0.minX * frame.width, y: $0.minY * frame.height,
                                         width: $0.width * frame.width, height: $0.height * frame.height) }
        // Match the contiguous station buildings used in widget-eaves.js.
        var index = 0
        while index < sites.count {
            var neighbor = index + 1
            while neighbor < sites.count {
                let a = sites[index], b = sites[neighbor]
                let across = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                let down = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                let row = abs(a.minY-b.minY) < 14 && abs(a.height-b.height) < 20 && across < 30 && down < 0
                let column = abs(a.minX-b.minX) < 14 && abs(a.width-b.width) < 20 && down < 28 && across < 0
                if row || column {
                    sites[index] = a.union(b)
                    sites.remove(at: neighbor)
                    neighbor = index + 1
                } else { neighbor += 1 }
            }
            index += 1
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        for (index, site) in sites.enumerated() where site.width >= 28 && site.height >= 24 {
            var headroom = site.minY - 2
            for (otherIndex, other) in sites.enumerated() where otherIndex != index && other.minX < site.maxX && other.maxX > site.minX && other.maxY <= site.minY {
                headroom = min(headroom, site.minY - other.maxY)
            }
            drawBuilding(site, roof: max(4, min(headroom, site.width * 0.31, 65)),
                         height: frame.height, trim: trim, in: ctx)
        }
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255,
                blue: CGFloat(rgb & 255)/255, alpha: alpha)
    }

    private static func drawBuilding(_ site: CGRect, roof: CGFloat, height: CGFloat, trim: CGImage, in ctx: CGContext) {
        let x = site.minX, y = site.minY, width = site.width, bottom = site.maxY
        let side = min(14, width * 0.072), sill = min(10, site.height * 0.06)
        let ground = min(height-3, max(bottom+sill+side*1.55, min(height*0.38, bottom+width*0.72)))
        let left = x-side*0.58, right = site.maxX+side*0.4, wing = min(21, max(7, width*0.075))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func fill(_ ink: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            ctx.setFillColor(color(ink))
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        func arch(_ x: CGFloat, _ base: CGFloat, _ width: CGFloat, _ height: CGFloat, _ ink: UInt32) {
            ctx.setFillColor(color(ink))
            ctx.beginPath()
            ctx.move(to: point(x,base))
            ctx.addLine(to: point(x,base-height+width/2))
            ctx.addQuadCurve(to: point(x+width/2,base-height), control: point(x,base-height))
            ctx.addQuadCurve(to: point(x+width,base-height+width/2), control: point(x+width,base-height))
            ctx.addLine(to: point(x+width,base))
            ctx.fillPath()
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let shadow = CGGradient(colorsSpace: space, colors: [color(0x5d7191, alpha: 0.28),color(0x8096ac, alpha: 0)] as CFArray, locations: [0,1]) {
            ctx.saveGState()
            ctx.translateBy(x: x+width*0.56, y: ground+3)
            ctx.scaleBy(x: 1, y: 0.115)
            ctx.drawRadialGradient(shadow, startCenter: .zero, startRadius: width*0.09,
                                   endCenter: .zero, endRadius: width*0.65, options: .drawsBeforeStartLocation)
            ctx.restoreGState()
        }
        ctx.setFillColor(color(0xa28572))
        ctx.beginPath()
        ctx.addLines(between: [point(right,y-4), point(right+wing,y-11), point(right+wing,ground-6), point(right,ground+2)])
        ctx.fillPath()
        if let plaster = CGGradient(colorsSpace: space, colors: [color(0xf3d5a7),color(0xcba77f)] as CFArray, locations: [0,1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: left, y: y-4, width: right-left, height: ground-y+4))
            ctx.drawLinearGradient(plaster,start:point(left,y),end:point(right,ground),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        fill(0xa98970, left+2, bottom, 3, ground-bottom)
        fill(0xa98970, right-5, bottom, 3, ground-bottom)
        fill(0xac9987, left-1, ground-6, right-left+2, 7)
        ctx.beginPath()
        ctx.setStrokeColor(color(0xccbeac))
        ctx.setLineWidth(1)
        ctx.move(to: point(left,ground-3))
        ctx.addLine(to: point(right,ground-3))
        for x in stride(from: left+5, to: right-2, by: 13) {
            ctx.move(to: point(x,ground-5)); ctx.addLine(to: point(x+1,ground-3))
            ctx.move(to: point(x+5,ground-3)); ctx.addLine(to: point(x+4,ground))
        }
        ctx.strokePath()
        let level = ground-bottom-sill
        if level > 21 {
            let doorH = min(level*0.85,width*0.3), doorW = max(9,doorH*0.53), doorX = x+width*0.31
            arch(doorX,ground-3,doorW,doorH,0x96775f)
            arch(doorX+2,ground-3,doorW-4,doorH-2,0x698677)
            ctx.setFillColor(color(0xe7c487))
            ctx.fillEllipse(in:CGRect(x:doorX+doorW*0.76-1.25,y:ground-3-doorH*0.42-1.25,width:2.5,height:2.5))
            for fraction: CGFloat in [0.13,0.68,0.85] {
                let wx = x+width*fraction, wy = ground-doorH*0.32, ww = min(doorW*0.74,15), wh = ww*1.22
                arch(wx,wy,ww,wh,0x96765e); arch(wx+1.5,wy-1.5,ww-3,wh-3,0xf7d38c)
                fill(0x987962,wx+ww*0.47,wy-wh+2,1,wh-2); fill(0x987962,wx,wy-wh*0.43,ww,1)
            }
        }
        // Crop in the original top-left raster coordinates, then orient each slice in the flipped drawing space.
        let sx: [CGFloat] = [0,145,848,1000], sy: [CGFloat] = [0,232,518,667]
        let dx = [x-side,x,site.maxX,site.maxX+side], dy = [y-roof,y,bottom,bottom+sill]
        for row in 0..<3 {
            for col in 0..<3 where row != 1 || col != 1 {
                let src = CGRect(x: sx[col], y: sy[row], width: sx[col+1]-sx[col], height: sy[row+1]-sy[row])
                guard let tile = trim.cropping(to: src) else { continue }
                let dst = CGRect(x: dx[col], y: dy[row], width: dx[col+1]-dx[col]+0.3, height: dy[row+1]-dy[row]+0.3)
                ctx.saveGState()
                ctx.translateBy(x: dst.minX, y: dst.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(tile, in: CGRect(origin: .zero, size: dst.size))
                ctx.restoreGState()
            }
        }
        for (center,radius) in [(left+5,side*1.8),(right-2,side*2.2)] {
            ctx.setFillColor(color(0xbdceda))
            ctx.fillEllipse(in: CGRect(x: center-radius,y: ground-2.7,width: radius*2,height: 7.4))
            ctx.setFillColor(color(0xf6f0e7))
            ctx.beginPath()
            ctx.move(to: point(center-radius,ground))
            ctx.addQuadCurve(to: point(center-radius*0.25,ground-4),control: point(center-radius*0.60,ground-6))
            ctx.addQuadCurve(to: point(center+radius*0.55,ground-5),control: point(center+radius*0.32,ground-11))
            ctx.addQuadCurve(to: point(center+radius,ground),control: point(center+radius*0.86,ground-6))
            ctx.addQuadCurve(to: point(center-radius,ground),control: point(center,ground+5))
            ctx.fillPath()
        }
    }
}
