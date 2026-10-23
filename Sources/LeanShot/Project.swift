import AppKit

struct ShotProject: Codable {
    var version = 1
    var image: Data
    var size: CGSize
    var canvasSize: CGSize
    var marks: [Mark]

    init(canvas: Canvas) throws {
        canvas.commitText()
        guard let data = ImageTools.png(canvas.image) else { throw CocoaError(.fileWriteUnknown) }
        image = data; size = canvas.image.size; canvasSize = canvas.bounds.size; marks = canvas.marks
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

struct BackgroundStyle: Codable {
    var palette = 0
    var padding: CGFloat = 64
    var radius: CGFloat = 16
    var shadow = true
    var aspect = 0 // auto, square, landscape, portrait
    var alignment = 1
    var customImage: Data?

    static let names = ["Lavender", "Ocean", "Peach", "Mint", "Rose", "Midnight", "Sand", "Slate", "Sky", "Plum", "Coral", "Lemon", "Forest", "Indigo", "Cream", "Charcoal", "White", "Black", "Transparent", "Custom Image"]
    private static let colors: [(UInt32, UInt32)] = [
        (0xe0dcfa, 0xa69be7), (0xcce7f4, 0x3265a8), (0xf9ddc5, 0xe69675), (0xd6eee4, 0x7eb8a3),
        (0xf5dfec, 0xc289a6), (0x2d3458, 0x101422), (0xeae1d1, 0xc4b298), (0xabb8c2, 0x526573),
        (0xe1f4fc, 0x99cbe8), (0xdbcde5, 0x7a528e), (0xf5c2b0, 0xda776a), (0xfbf3c3, 0xe0ce79),
        (0x9abdae, 0x305c4b), (0xa6ace4, 0x424985), (0xf5eee1, 0xe3d4b9), (0x3c3e43, 0x232429),
        (0xffffff, 0xffffff), (0x000000, 0x000000), (0, 0), (0xffffff, 0xffffff)
    ]
    func apply(to image: NSImage) -> NSImage {
        var size = NSSize(width: image.size.width + padding * 2, height: image.size.height + padding * 2)
        let ratios: [CGFloat] = [0, 1, 16 / 9, 9 / 16, 4 / 3]
        let ratio = ratios[min(max(0, aspect), ratios.count - 1)]
        if ratio > 0 {
            if size.width / size.height > ratio { size.height = size.width / ratio } else { size.width = size.height * ratio }
        }
        let scale = ImageTools.pixelSize(image).width / image.size.width
        return ImageTools.render(size: size, pixels: NSSize(width: size.width * scale, height: size.height * scale)) { rect in
            let index = min(max(0, palette), Self.colors.count - 1)
            if index == 19, let data = customImage, let bg = NSImage(data: data) {
                bg.draw(in: rect)
            } else if index != 18 {
                func color(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
                let pair = Self.colors[index]
                NSGradient(starting: color(pair.0), ending: color(pair.1))?.draw(in: rect, angle: -60)
            }
            let x = alignment == 0 ? padding : alignment == 2 ? size.width - image.size.width - padding : (size.width - image.size.width) / 2
            let shot = NSRect(x: x, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            let path = NSBezierPath(roundedRect: shot, xRadius: radius, yRadius: radius)
            if shadow {
                NSGraphicsContext.saveGraphicsState()
                let s = NSShadow(); s.shadowBlurRadius = 24; s.shadowOffset = NSSize(width: 0, height: -12); s.shadowColor = NSColor.black.withAlphaComponent(0.25); s.set()
                NSColor.white.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.saveGraphicsState(); path.addClip(); image.draw(in: shot); NSGraphicsContext.restoreGraphicsState()
        }
    }
}
