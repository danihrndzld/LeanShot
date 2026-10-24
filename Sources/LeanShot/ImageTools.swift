import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// Bitmap operations preserve source pixel density and never resample through a screen context.
enum ImageTools {
    /// One Core Image context for the app: creating one per filter pass cost ~60 ms each.
    static let ciContext = CIContext()
    /// The first Core Image render compiles its kernels (~90 ms); do it at launch, off the main thread.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let pixel = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            let f = CIFilter.pixellate(); f.inputImage = pixel.clampedToExtent(); f.scale = 8
            _ = ciContext.createCGImage((f.outputImage ?? pixel).applyingGaussianBlur(sigma: 4), from: pixel.extent)
        }
    }

    /// Encodes straight from the CGImage (no TIFF round trip) and keeps the Retina DPI so pastes stay 1x.
    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return png(cg, pointWidth: image.size.width)
    }
    /// Thread-safe variant: take the CGImage on the main thread, encode anywhere.
    static func png(_ cg: CGImage, pointWidth: CGFloat) -> Data? { encode(cg, pointWidth: pointWidth, as: .png) }
    /// PNG, JPEG or HEIC at the capture's Retina DPI; lossy formats use 90% quality.
    static func encode(_ cg: CGImage, pointWidth: CGFloat, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * CGFloat(cg.width) / max(1, pointWidth)
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type != .png { options[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    static func render(size: NSSize, pixels: NSSize? = nil, draw: (NSRect) -> Void) -> NSImage {
        let p = pixels ?? size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(p.width.rounded())), pixelsHigh: max(1, Int(p.height.rounded())), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let t = NSAffineTransform(); t.scaleX(by: p.width / size.width, yBy: p.height / size.height); t.concat()
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let result = NSImage(size: size); result.addRepresentation(bitmap); return result
    }
    static func pixelSize(_ image: NSImage) -> NSSize {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image.size }
        return NSSize(width: cg.width, height: cg.height)
    }
    static func rotate(_ image: NSImage, clockwise: Bool) -> NSImage {
        let size = NSSize(width: image.size.height, height: image.size.width), p = pixelSize(image)
        return render(size: size, pixels: NSSize(width: p.height, height: p.width)) { _ in
            let t = NSAffineTransform()
            t.translateX(by: clockwise ? 0 : size.width, yBy: clockwise ? size.height : 0)
            t.rotate(byDegrees: clockwise ? -90 : 90); t.concat()
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
    }
    static func flip(_ image: NSImage, horizontal: Bool) -> NSImage {
        render(size: image.size, pixels: pixelSize(image)) { rect in
            let t = NSAffineTransform(); t.translateX(by: horizontal ? rect.width : 0, yBy: horizontal ? 0 : rect.height)
            t.scaleX(by: horizontal ? -1 : 1, yBy: horizontal ? 1 : -1); t.concat(); image.draw(in: rect)
        }
    }
    static func crop(_ image: NSImage, to rect: NSRect) -> NSImage {
        let r = rect.intersection(NSRect(origin: .zero, size: image.size))
        guard r.width >= 1, r.height >= 1 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let sx = CGFloat(cg.width) / image.size.width, sy = CGFloat(cg.height) / image.size.height
        let pixels = CGRect(x: r.minX * sx, y: (image.size.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
        guard let cropped = cg.cropping(to: pixels) else { return image }
        return NSImage(cgImage: cropped, size: r.size)
    }
    static func resize(_ image: NSImage, pixels: NSSize) -> NSImage {
        render(size: pixels, pixels: pixels) { image.draw(in: $0) }
    }
}

/// Small previews decoded at display size by ImageIO, instead of decoding a 6 MP capture per row or card.
enum Thumbnail {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ url: URL, maxPixels: CGFloat) -> NSImage? {
        let key = "\(url.path)|\(Int(maxPixels))|\(modified(url))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
    /// First frame of a recording, for History rows and Quick Access cards.
    static func video(_ url: URL, maxPixels: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width / 2, height: frame.image.height / 2))
    }
    /// Reads only the file header: true for PNG/JPEG/GIF/HEIC, false for videos and projects.
    static func isImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }
    private static func modified(_ url: URL) -> TimeInterval { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0 }
}
