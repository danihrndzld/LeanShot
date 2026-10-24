import AppKit
import CoreImage
import ImageIO

struct ShotProject: Codable {
    var version = 1
    var image: Data
    var size: CGSize
    var canvasSize: CGSize
    var marks: [Mark]
    var background: ShotBackground?

    init(canvas: Canvas, background: ShotBackground? = nil) throws {
        canvas.commitText()
        guard let data = ImageTools.png(canvas.image) else { throw CocoaError(.fileWriteUnknown) }
        image = data; size = canvas.image.size; canvasSize = canvas.bounds.size; marks = canvas.marks; self.background = background
    }
    func decodedImage() throws -> NSImage {
        guard version == 1, let result = NSImage(data: image),
              size.width.isFinite, size.height.isFinite, (1...100_000).contains(size.width), (1...100_000).contains(size.height),
              canvasSize.width.isFinite, canvasSize.height.isFinite, (1...100_000).contains(canvasSize.width), (1...100_000).contains(canvasSize.height) else { throw CocoaError(.fileReadCorruptFile) }
        let pixels = ImageTools.pixelSize(result)
        guard pixels.width * pixels.height <= 100_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        result.size = size; return result
    }
    static func read(_ url: URL) throws -> ShotProject { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    func write(_ url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
}

/// Non-destructive backdrop: fill, padding, inset card, shadow, corners, 3×3 position and ratio.
struct ShotBackground: Codable, Equatable {
    var palette = 0          // gradient index, used when there is no color or image
    var color: [CGFloat]?    // plain sRGBA; alpha 0 means transparent
    var customImage: Data?   // wallpaper, downscaled JPEG
    var blur: CGFloat = 0
    var padding: CGFloat = 64
    var inset: CGFloat = 0
    var radius: CGFloat = 12
    var shadow: CGFloat = 0.5 // 0...1
    var aspect = 0           // auto, square, 16:9, 9:16, 4:3
    var position = 4         // 3×3 grid, 0 = top left

    static let ratios: [(String, CGFloat)] = [("Auto", 0), ("1:1", 1), ("16:9", 16 / 9), ("9:16", 9 / 16), ("4:3", 4 / 3)]
    static let gradients: [(UInt32, UInt32)] = [
        (0xf5576c, 0xb24592), (0x6a5af9, 0xd66efd), (0x0f2862, 0x3e7cb1), (0x8ee3c8, 0x3a9e8f), (0xffb88c, 0xde6262),
        (0x4facfe, 0xc471f5), (0xe8e8e8, 0xf6d5d5), (0xbdc3c7, 0xf3b597), (0x89c4ff, 0x7b5cff), (0x0b0b2b, 0x3a3aa8),
        (0x3b5f8a, 0xf2b263), (0x93a5cf, 0xe4b4d0), (0xa18cd1, 0xfbc2eb), (0x4a1c2c, 0xe24a3b), (0x1a1a5e, 0xc2185b),
        (0xa18cd1, 0xff9a9e), (0xff512f, 0xf09819), (0x1e3c72, 0xfdbb2d), (0x2b1055, 0xff6a3d), (0x4facfe, 0xf78ca0),
    ]
    static let plainColors: [UInt32] = [0x000000, 0xffffff, 0xd94040, 0xe8862e, 0xe8b23a, 0x3d8f58, 0x3e87e0, 0x7c4ee8,
                                        0x3a3a3c, 0xe5e5ea, 0xf2b8b5, 0xf6c58d, 0xf3dc98, 0xa8dfb9, 0xa9d2f5, 0xd5bdf5]
    static func rgba(_ hex: UInt32) -> [CGFloat] { [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, 1] }
    private static func nsColor(_ c: [CGFloat]) -> NSColor { NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]) }
    var isTransparent: Bool { customImage == nil && (color?[3] ?? 1) == 0 }

    /// Output size, the inset card and the screenshot rect inside it.
    func layout(_ image: NSSize) -> (size: NSSize, card: NSRect, shot: NSRect) {
        let card = NSSize(width: image.width + inset * 2, height: image.height + inset * 2)
        var size = NSSize(width: card.width + padding * 2, height: card.height + padding * 2)
        let ratio = Self.ratios[min(max(0, aspect), Self.ratios.count - 1)].1
        if ratio > 0 { if size.width / size.height > ratio { size.height = size.width / ratio } else { size.width = size.height * ratio } }
        let column = position % 3, row = position / 3
        let x = column == 0 ? padding : column == 2 ? size.width - card.width - padding : (size.width - card.width) / 2
        let y = row == 0 ? size.height - card.height - padding : row == 2 ? padding : (size.height - card.height) / 2
        let cardRect = NSRect(x: x, y: y, width: card.width, height: card.height)
        return (size, cardRect, cardRect.insetBy(dx: inset, dy: inset))
    }

    private static var blurCache: (key: Int, image: NSImage)?
    private func wallpaper() -> NSImage? {
        guard let data = customImage else { return nil }
        let key = data.hashValue ^ blur.hashValue
        if let cached = Self.blurCache, cached.key == key { return cached.image }
        guard let image = NSImage(data: data) else { return nil }
        var result = image
        if blur > 0, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let input = CIImage(cgImage: cg)
            if let out = ImageTools.ciContext.createCGImage(input.clampedToExtent().applyingGaussianBlur(sigma: Double(blur)).cropped(to: input.extent), from: input.extent) {
                result = NSImage(cgImage: out, size: image.size)
            }
        }
        Self.blurCache = (key, result)
        return result
    }

    /// Paints the backdrop (wallpaper aspect-fills, gradients run diagonally).
    func drawFill(in rect: NSRect) {
        if let image = wallpaper() {
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        } else if let color {
            Self.nsColor(color).setFill(); rect.fill()
        } else {
            let pair = Self.gradients[min(max(0, palette), Self.gradients.count - 1)]
            NSGradient(starting: Self.nsColor(Self.rgba(pair.0)), ending: Self.nsColor(Self.rgba(pair.1)))?.draw(in: rect, angle: -50)
        }
    }

    /// Shadowed card behind the screenshot; with an inset it shows the screenshot's own edge color.
    func drawCard(_ card: NSRect, edge: NSColor) {
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if shadow > 0 {
            let s = NSShadow(); s.shadowBlurRadius = 6 + 44 * shadow; s.shadowOffset = NSSize(width: 0, height: -(2 + 18 * shadow))
            s.shadowColor = NSColor.black.withAlphaComponent(0.12 + 0.38 * shadow); s.set()
        }
        (inset > 0 ? edge : .white).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    var screenshotRadius: CGFloat { max(0, radius - inset) }

    static func edgeColor(_ image: NSImage) -> NSColor {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let c = rep.colorAt(x: 1, y: 1) else { return .white }
        return c
    }

    func apply(to image: NSImage) -> NSImage {
        let (size, card, shot) = layout(image.size)
        let scale = ImageTools.pixelSize(image).width / image.size.width
        let edge = inset > 0 ? Self.edgeColor(image) : .white
        return ImageTools.render(size: size, pixels: NSSize(width: size.width * scale, height: size.height * scale)) { rect in
            drawFill(in: rect)
            drawCard(card, edge: edge)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: shot, xRadius: screenshotRadius, yRadius: screenshotRadius).addClip()
            image.draw(in: shot)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Wallpapers are stored as ≤2400 px JPEG so projects and presets stay small.
    static func wallpaperData(_ url: URL, maxPixels: Int = 2400) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
