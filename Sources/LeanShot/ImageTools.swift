import AppKit

/// Bitmap operations preserve source pixel density and never resample through a screen context.
enum ImageTools {
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
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
