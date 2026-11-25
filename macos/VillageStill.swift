import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The system wallpaper uses the same ground coordinates as the live surface.
/// It contains no local filenames, widgets' contents, IDs or interactive labels.
struct VillageStill {
    struct House: Equatable {
        let x, feet, side: CGFloat
        let variant: Int
        init?(_ plot: [String: Any]) {
            guard plot["drawHouse"] as? Bool == true, let x = plot["x"] as? CGFloat,
                  let feet = plot["y"] as? CGFloat, let side = plot["size"] as? CGFloat,
                  let variant = plot["variant"] as? Int, (1...6).contains(variant), side > 0 else { return nil }
            self.x = x
            self.feet = feet
            self.side = side
            self.variant = variant
        }
    }
    struct Scene: Equatable {
        let size: CGSize
        let houses: [House]
        let mail: [String]
        let widgets: [CGRect]
        let edition: Date?
    }
    private static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
    static func render(_ scene: Scene, source: URL) throws -> Data {
        let frame = CGRect(origin: .zero, size: scene.size)
        let ratio = min(2, 2560 / max(frame.width,frame.height))
        let w = Int((frame.width * ratio).rounded()), h = Int((frame.height * ratio).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: CGFloat(w)/frame.width, y: CGFloat(h)/frame.height)
        ctx.interpolationQuality = .high
        let landscape = try image(source)
        let art = VillageComposition.Projection(frame,width: CGFloat(landscape.width),height: CGFloat(landscape.height))
        func flipped(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX, y: frame.height-box.maxY, width: box.width, height: box.height)
        }
        ctx.draw(landscape,in: flipped(CGRect(origin:art.origin,size:art.size)))
        let houseFolder = source.deletingLastPathComponent().appendingPathComponent("houses")
        var sprites: [Int:CGImage] = [:]
        for house in scene.houses.sorted(by: { $0.feet < $1.feet }) {
            if sprites[house.variant] == nil {
                sprites[house.variant] = try image(houseFolder.appendingPathComponent("cottage-\(house.variant).png"))
            }
            let side = house.side, cx = house.x*frame.width, feet = house.feet*frame.height
            ctx.saveGState()
            ctx.setShadow(offset:CGSize(width:side * 0.06,height: -side * 0.018), blur:side * 0.07,
                          color:CGColor(red:0.36,green:0.46,blue:0.54,alpha:0.26))
            ctx.setFillColor(red:0.65,green:0.71,blue:0.75,alpha:0.30)
            ctx.fillEllipse(in: flipped(CGRect(x:cx-side*0.38,y:feet-side*0.045,width:side*0.83,height:side*0.09)))
            ctx.restoreGState()
            if let sprite = sprites[house.variant] {
                ctx.draw(sprite,in:flipped(CGRect(x:cx-side/2,y:feet-side*0.88,width:side,height:side)))
            }
        }
        for (index,kind) in scene.mail.prefix(2).enumerated() {
            let office = art.postOffice
            let size = CGSize(width:office.width*0.21,height:office.height*0.14)
            ctx.saveGState()
            ctx.translateBy(x:office.minX+office.width*(index == 0 ? 0.29 : 0.73),y:frame.height-office.minY-office.height*0.79)
            ctx.rotate(by:index == 0 ? 0.1 : -0.12)
            let paper = CGRect(x:-size.width/2,y:-size.height/2,width:size.width,height:size.height)
            ctx.setFillColor(red:0.94,green:0.86,blue:0.71,alpha:1)
            ctx.fill(paper)
            ctx.setStrokeColor(red:0.53,green:0.42,blue:0.32,alpha:1)
            ctx.setLineWidth(max(0.6,size.height*0.05)); ctx.stroke(paper)
            if kind == "image" {
                ctx.setFillColor(red:0.53,green:0.67,blue:0.70,alpha:1); ctx.fill(paper.insetBy(dx:1.5,dy:1.5))
                ctx.setFillColor(red:0.44,green:0.56,blue:0.48,alpha:1); ctx.move(to:CGPoint(x:paper.minX+1.5,y:paper.minY+1.5))
                ctx.addLine(to:CGPoint(x:0,y:paper.height*0.12)); ctx.addLine(to:CGPoint(x:paper.maxX-1.5,y:paper.minY+1.5)); ctx.fillPath()
            } else {
                ctx.move(to:CGPoint(x:paper.minX,y:paper.maxY)); ctx.addLine(to:CGPoint(x:0,y:paper.minY+size.height*0.39))
                ctx.addLine(to:CGPoint(x:paper.maxX,y:paper.maxY)); ctx.strokePath()
            }
            ctx.restoreGState()
        }
        if !scene.widgets.isEmpty {
            try WidgetStill.draw(scene.widgets, in:ctx, frame:frame, assets:source.deletingLastPathComponent())
        }
        let data = NSMutableData()
        guard let output = ctx.makeImage(), let writer = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer,output,[kCGImageDestinationLossyCompressionQuality:0.86] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
