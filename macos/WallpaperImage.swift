import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Stores only a locally normalized JPEG. The original image stays where the visitor chose it.
final class WallpaperImage {
    let directory: URL
    let file: URL
    private(set) var dataURL: String?

    init(temporary: Bool) {
        let files = FileManager.default
        if temporary {
            directory = files.temporaryDirectory.appendingPathComponent("SnowfallTest-" + UUID().uuidString, isDirectory: true)
        } else {
            let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("com.snowfallos.desktop", isDirectory: true)
        }
        file = directory.appendingPathComponent("wallpaper.jpg")
        if let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize, size <= 64 * 1024 * 1024,
           let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
           let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source) as String? == UTType.jpeg.identifier {
            dataURL = Self.uri(bytes)
        }
    }

    private enum ImageError: LocalizedError {
        case unreadable, encoding
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This image could not be decoded. Choose another photo."
            case .encoding: return "Snowfall could not prepare a wallpaper from this image."
            }
        }
    }

    static func convert(_ url: URL) throws -> Data {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable
        }
        // An opaque sRGB canvas gives transparent PNGs a white backing and strips source metadata.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageError.encoding
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(bounds)
        canvas.draw(image, in: bounds)
        guard let output = canvas.makeImage() else { throw ImageError.encoding }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.encoding
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encoding }
        return result as Data
    }

    func save(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file, options: .atomic)
        dataURL = Self.uri(bytes)
    }

    func restoreAlpine() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        dataURL = nil
    }

    private static func uri(_ bytes: Data) -> String { "data:image/jpeg;base64," + bytes.base64EncodedString() }

    /// Generates an oversized image with a rotation tag in the smoke test's private temporary folder.
    func loadTestPicture() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceFile = directory.appendingPathComponent("generated-test.tiff")
        guard let context = CGContext(data: nil, width: 4160, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let target = CGImageDestinationCreateWithURL(sourceFile as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ImageError.encoding
        }
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.81, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4160, height: 400))
        guard let picture = context.makeImage() else { throw ImageError.encoding }
        CGImageDestinationAddImage(target, picture, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw ImageError.encoding }
        let normalized = try Self.convert(sourceFile)
        guard let saved = CGImageSourceCreateWithData(normalized as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(saved, 0, nil), decoded.height == 4096, decoded.width < decoded.height else {
            throw ImageError.encoding
        }
        try save(normalized)
    }
}
