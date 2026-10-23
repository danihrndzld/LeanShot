import AppKit
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum Tool: Int, CaseIterable, Codable {
    case select, rect, filledRect, ellipse, line, arrow, text, pixelate, highlight, counter, pen
    case blur, spotlight, crop, redact, image
    static var visible: [Tool] { allCases.filter { $0 != .image } }
    var symbol: String {
        ["cursorarrow", "square", "square.fill", "circle", "line.diagonal", "arrow.up.right", "textformat",
         "checkerboard.rectangle", "highlighter", "1.circle.fill", "pencil.tip", "drop.halffull", "light.max", "crop", "rectangle.fill", "photo"][rawValue]
    }
    var label: String {
        ["Select", "Rectangle", "Filled Rectangle", "Ellipse", "Line", "Arrow", "Text",
         "Pixelate", "Highlight", "Counter", "Pen", "Smooth Blur", "Spotlight", "Crop", "Redact (Opaque)", "Image"][rawValue]
    }
    /// Single-key shortcut while the canvas has focus.
    var key: String { ["v", "r", "f", "o", "l", "a", "t", "b", "h", "n", "p", "u", "s", "c", "x", "i"][rawValue] }
}

struct Mark: Codable {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var style = 0
    var imageData: Data? = nil

    enum CodingKeys: String, CodingKey { case tool, points, color, width, text, style, imageData }
    init(tool: Tool, points: [CGPoint], color: NSColor, width: CGFloat, text: String = "", style: Int = 0, imageData: Data? = nil) {
        self.tool = tool; self.points = points; self.color = color; self.width = width
        self.text = text; self.style = style; self.imageData = imageData
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(Tool.self, forKey: .tool); points = try c.decode([CGPoint].self, forKey: .points)
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { throw CocoaError(.fileReadCorruptFile) }
        let rgba = try c.decode([CGFloat].self, forKey: .color)
        guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        width = try c.decode(CGFloat.self, forKey: .width)
        guard width.isFinite, (0.1...256).contains(width), points.count >= 2 || [.text, .counter, .pen].contains(tool) else { throw CocoaError(.fileReadCorruptFile) }
        text = try c.decode(String.self, forKey: .text); style = try c.decodeIfPresent(Int.self, forKey: .style) ?? 0
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool); try c.encode(points, forKey: .points)
        let rgb = color.usingColorSpace(.sRGB) ?? .red
        try c.encode([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent], forKey: .color)
        try c.encode(width, forKey: .width); try c.encode(text, forKey: .text); try c.encode(style, forKey: .style)
        try c.encodeIfPresent(imageData, forKey: .imageData)
    }

    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Hit area for the select tool.
    var bounds: CGRect {
        let r: CGRect
        switch tool {
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .counter:
            let d = Mark.counterDiameter(width)
            r = CGRect(x: points[0].x - d / 2, y: points[0].y - d / 2, width: d, height: d)
        case .text:
            r = CGRect(origin: points[0], size: (text as NSString).size(withAttributes: Mark.textAttributes(color, width)))
        default:
            r = rect
        }
        return r.insetBy(dx: -width / 2 - 4, dy: -width / 2 - 4)
    }

    mutating func move(by dx: CGFloat, _ dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    static func font(_ width: CGFloat) -> NSFont { .systemFont(ofSize: 12 + width * 3, weight: .bold) }
    static func counterDiameter(_ width: CGFloat) -> CGFloat { 18 + width * 3 }
    static func textAttributes(_ color: NSColor, _ width: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(width), .foregroundColor: color, .strokeColor: NSColor.white, .strokeWidth: -3]
    }
}

/// Draws the screenshot plus marks. Marks live in view coordinates; export rescales to pixels.
final class Canvas: NSView, NSTextFieldDelegate {
    var image: NSImage
    private var pixelated: NSImage?
    private var blurred: NSImage?
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var tool: Tool = .arrow { didSet { selected = nil; dragFrom = nil; onToolChange?(tool) } }
    var color: NSColor = .systemRed { didSet { if let selected { checkpoint(); marks[selected].color = color } } }
    var width: CGFloat = 4 { didSet { if let selected { checkpoint(); marks[selected].width = width } } }
    var arrowStyle = 0
    var textStyle = 0
    var cropAspect: CGFloat = 0
    var onImageChange: (() -> Void)?
    var onToolChange: ((Tool) -> Void)?
    private struct State { var image: NSImage; var marks: [Mark]; var size: NSSize }
    private var history: [State] = []
    private var future: [State] = []
    private var selected: Int? { didSet { needsDisplay = true } }
    private var dragFrom: CGPoint?
    private var moveUnsaved = false // select-click only records undo once it actually moves
    private var resizeCorner: Int?
    private var editor: NSTextField?

    init(image: NSImage, size: NSSize? = nil) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size ?? image.size))
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            var inserted = false
            for url in urls { if let image = NSImage(contentsOf: url) { insertImage(image, at: point); inserted = true } }
            return inserted
        }
        if let image = NSImage(pasteboard: pasteboard) { insertImage(image, at: point); return true }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        render(in: bounds)
        if let i = selected, i < marks.count {
            let p = NSBezierPath(roundedRect: marks[i].bounds, xRadius: 4, yRadius: 4)
            p.setLineDash([5, 3], count: 2, phase: 0)
            p.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            p.stroke()
            if canResize(marks[i]) {
                for corner in corners(marks[i].rect) {
                    NSColor.white.setFill(); NSColor.controlAccentColor.setStroke()
                    let handle = NSBezierPath(rect: NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)); handle.fill(); handle.stroke()
                }
            }
        }
    }

    func render(in rect: NSRect) {
        image.draw(in: rect)
        let spotlights = marks.filter { $0.tool == .spotlight }
        if !spotlights.isEmpty {
            let dim = NSBezierPath(rect: rect); dim.windingRule = .evenOdd
            spotlights.forEach { dim.append(NSBezierPath(roundedRect: $0.rect, xRadius: 6, yRadius: 6)) }
            NSColor.black.withAlphaComponent(0.62).setFill(); dim.fill()
        }
        var counter = 0
        for m in marks {
            if m.tool == .counter { counter += 1 }
            draw(m, imageRect: rect, number: counter)
        }
    }

    private func draw(_ m: Mark, imageRect: NSRect, number: Int) {
        m.color.set()
        switch m.tool {
        case .select, .spotlight:
            break
        case .crop:
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: m.rect); p.lineWidth = 2; p.stroke()
        case .redact:
            NSColor.black.setFill(); m.rect.fill()
        case .image:
            if let data = m.imageData, let image = NSImage(data: data) { image.draw(in: m.rect) }
        case .rect, .ellipse:
            let p = m.tool == .rect ? NSBezierPath(roundedRect: m.rect, xRadius: 3, yRadius: 3) : NSBezierPath(ovalIn: m.rect)
            p.lineWidth = m.width
            p.stroke()
        case .filledRect:
            NSBezierPath(roundedRect: m.rect, xRadius: 3, yRadius: 3).fill()
        case .highlight:
            m.color.withAlphaComponent(0.35).set()
            m.rect.fill(using: .multiply)
        case .pixelate, .blur:
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: m.rect).addClip()
            if m.tool == .pixelate {
                if pixelated == nil { pixelated = Canvas.pixelate(image) }
                pixelated?.draw(in: imageRect)
            } else {
                if blurred == nil {
                    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let input = CIImage(cgImage: cg)
                        let output = input.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: input.extent)
                        if let result = CIContext().createCGImage(output, from: input.extent) { blurred = NSImage(cgImage: result, size: image.size) }
                    }
                }
                blurred?.draw(in: imageRect)
            }
            NSGraphicsContext.restoreGraphicsState()
        case .pen, .line:
            guard let first = m.points.first else { return }
            let p = NSBezierPath()
            p.move(to: first)
            if m.tool == .pen, m.points.count > 2 {
                for i in 1..<m.points.count - 1 {
                    let a = m.points[i], b = m.points[i + 1]
                    let end = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    p.curve(to: end, controlPoint1: a, controlPoint2: a)
                }
                p.line(to: m.points.last!)
            } else { m.points.dropFirst().forEach { p.line(to: $0) } }
            p.lineWidth = m.width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        case .arrow:
            guard let a = m.points.first, let b = m.points.last, a != b else { return }
            if m.style == 1 { // Curved arrow with a tangent-aligned head.
                let mid = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * 0.32, y: (a.y + b.y) / 2 + (b.x - a.x) * 0.32)
                let path = NSBezierPath(); path.move(to: a); path.curve(to: b, controlPoint1: mid, controlPoint2: mid)
                path.lineWidth = m.width; path.lineCapStyle = .round; path.stroke()
                let length = max(1, hypot(b.x - mid.x, b.y - mid.y)), head = min(length, max(16, m.width * 4))
                let start = CGPoint(x: b.x - (b.x - mid.x) / length * head, y: b.y - (b.y - mid.y) / length * head)
                Canvas.arrowPath(from: start, to: b, width: m.width).fill()
            } else {
                let path = Canvas.arrowPath(from: a, to: b, width: m.width)
                if m.style == 3 { path.lineWidth = 1.5; path.stroke() } else { path.fill() }
                if m.style == 2 { Canvas.arrowPath(from: b, to: a, width: m.width).fill() }
            }
        case .text:
            var attrs = Mark.textAttributes(m.color, m.width)
            if m.style > 0 { attrs[.strokeWidth] = 0 }
            if m.style == 2 { attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12 + m.width * 3, weight: .medium) }
            if m.style == 3 { attrs[.font] = NSFont.systemFont(ofSize: 12 + m.width * 3, weight: .regular) }
            if m.style >= 4 {
                let size = (m.text as NSString).size(withAttributes: attrs)
                let box = NSRect(origin: m.points[0], size: size).insetBy(dx: -8, dy: -4)
                (m.style == 4 ? NSColor.white : m.style == 5 ? NSColor.black : m.color).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                attrs[.foregroundColor] = m.style == 4 ? NSColor.black : NSColor.white
            }
            (m.text as NSString).draw(at: m.points[0], withAttributes: attrs)
        case .counter:
            let d = Mark.counterDiameter(m.width), c = m.points[0]
            NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            let s = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                                                        .foregroundColor: NSColor.white]
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        }
    }

    /// Filled arrow: shaft + triangular head, so it exports crisply at any scale.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> NSBezierPath {
        let len = hypot(b.x - a.x, b.y - a.y)
        let head = min(len * 0.6, max(18, width * 4.5))
        let t = NSAffineTransform()
        t.translateX(by: a.x, yBy: a.y)
        t.rotate(byRadians: atan2(b.y - a.y, b.x - a.x))
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 0, y: -width / 2))
        p.line(to: CGPoint(x: len - head, y: -width / 2))
        p.line(to: CGPoint(x: len - head, y: -head / 2))
        p.line(to: CGPoint(x: len, y: 0))
        p.line(to: CGPoint(x: len - head, y: head / 2))
        p.line(to: CGPoint(x: len - head, y: width / 2))
        p.line(to: CGPoint(x: 0, y: width / 2))
        p.close()
        p.transform(using: t as AffineTransform)
        return p
    }

    static func pixelate(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let input = CIImage(cgImage: cg)
        let f = CIFilter.pixellate()
        f.inputImage = input.clampedToExtent()
        f.scale = Float(max(input.extent.width, input.extent.height) / 80)
        f.center = .zero
        guard let out = f.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(out, from: input.extent) else { return image }
        return NSImage(cgImage: result, size: image.size)
    }

    // MARK: Editing

    private var state: State { State(image: image, marks: marks, size: bounds.size) }
    private func canResize(_ mark: Mark) -> Bool { ![.pen, .text, .counter, .arrow, .line].contains(mark.tool) }
    private func corners(_ rect: CGRect) -> [CGPoint] { [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)] }
    private func checkpoint() { history.append(state); future.removeAll() }
    private func restore(_ state: State) {
        image = state.image; marks = state.marks; setFrameSize(state.size)
        pixelated = nil; blurred = nil; selected = nil; dragFrom = nil; onImageChange?()
    }

    func undo() {
        guard let last = history.popLast() else { return NSSound.beep() }
        future.append(state); restore(last)
    }
    func redo() { guard let next = future.popLast() else { return NSSound.beep() }; history.append(state); restore(next) }
    func replaceImage(_ newImage: NSImage) {
        checkpoint(); image = newImage; marks = []; setFrameSize(newImage.size)
        pixelated = nil; blurred = nil; selected = nil; onImageChange?(); needsDisplay = true
    }
    func insertImage(_ image: NSImage, at point: CGPoint? = nil) {
        commitText(); checkpoint()
        let scale = min(1, bounds.width * 0.65 / image.size.width, bounds.height * 0.65 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = point ?? CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        marks.append(Mark(tool: .image, points: [origin, CGPoint(x: origin.x + size.width, y: origin.y + size.height)], color: .clear, width: 1, imageData: ImageTools.png(image)))
        tool = .select; selected = marks.count - 1
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            if let selected, canResize(marks[selected]), let corner = corners(marks[selected].rect).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) {
                resizeCorner = corner; dragFrom = p; moveUnsaved = true; return
            }
            resizeCorner = nil
            selected = marks.indices.last { marks[$0].bounds.contains(p) }
            if selected != nil { dragFrom = p; moveUnsaved = true }
        case .text:
            beginText(at: p)
        case .counter:
            checkpoint()
            marks.append(Mark(tool: .counter, points: [p], color: color, width: width))
        default:
            checkpoint()
            marks.append(Mark(tool: tool, points: [p, p], color: color, width: width, style: arrowStyle))
            dragFrom = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        var p = convert(event.locationInWindow, from: nil)
        if tool == .crop {
            p.x = min(max(0, p.x), bounds.width); p.y = min(max(0, p.y), bounds.height)
            let aspect = cropAspect > 0 ? cropAspect : event.modifierFlags.contains(.shift) ? 1 : 0
            if aspect > 0 { p.y = from.y + (p.y >= from.y ? 1 : -1) * abs(p.x - from.x) / aspect }
        }
        if tool == .select, let i = selected {
            if moveUnsaved { checkpoint(); moveUnsaved = false }
            if let corner = resizeCorner {
                let opposite = corners(marks[i].rect)[(corner + 2) % 4]
                if marks[i].tool == .image || event.modifierFlags.contains(.shift) {
                    let ratio = marks[i].rect.width / max(1, marks[i].rect.height)
                    p.y = opposite.y + (p.y > opposite.y ? 1 : -1) * abs(p.x - opposite.x) / ratio
                }
                if abs(p.x - opposite.x) > 2, abs(p.y - opposite.y) > 2 { marks[i].points = [opposite, p] }
            } else { marks[i].move(by: p.x - from.x, p.y - from.y) }
            dragFrom = p
        } else if tool == .pen {
            marks[marks.count - 1].points.append(p)
        } else {
            marks[marks.count - 1].points[1] = p
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragFrom = nil; resizeCorner = nil }
        if tool == .crop, let m = marks.last, m.tool == .crop {
            marks.removeLast()
            if m.rect.width > 1, m.rect.height > 1 {
                let flat = export()
                let r = CGRect(x: m.rect.minX / bounds.width * flat.size.width, y: m.rect.minY / bounds.height * flat.size.height, width: m.rect.width / bounds.width * flat.size.width, height: m.rect.height / bounds.height * flat.size.height)
                image = ImageTools.crop(flat, to: r); marks = []; setFrameSize(image.size)
                pixelated = nil; blurred = nil; onImageChange?()
            } else { _ = history.popLast() }
            needsDisplay = true; return
        }
        // A click without a drag leaves an empty shape behind; drop it.
        if dragFrom != nil, tool != .select, let m = marks.last, m.points.count == 2, m.points[0] == m.points[1] {
            marks.removeLast()
            _ = history.popLast()
        }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if [51, 117].contains(event.keyCode), let i = selected { // delete / forward delete
            checkpoint()
            selected = nil
            dragFrom = nil
            marks.remove(at: i)
        } else if plain, let c = event.charactersIgnoringModifiers?.lowercased(),
                  let t = Tool.allCases.first(where: { $0.key == c }) {
            tool = t
        } else {
            super.keyDown(with: event)
        }
    }

    private func beginText(at p: CGPoint) {
        let f = NSTextField(string: "")
        f.font = Mark.font(width)
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.placeholderString = "Type, then Return"
        f.cell?.isScrollable = true
        f.delegate = self
        f.frame = NSRect(x: p.x - 2, y: p.y, width: max(120, bounds.maxX - p.x), height: ceil(f.font!.boundingRectForFont.height))
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f
    }

    func commitText() {
        guard let f = editor else { return }
        editor = nil
        f.removeFromSuperview()
        guard !f.stringValue.isEmpty else { return }
        checkpoint()
        marks.append(Mark(tool: .text, points: [CGPoint(x: f.frame.minX + 2, y: f.frame.minY)], color: color, width: width,
                          text: f.stringValue, style: textStyle))
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { editor?.stringValue = ""; commitText(); return true }
        return false
    }

    /// Renders at the source image's full pixel resolution.
    func export() -> NSImage {
        commitText()
        let rep = image.representations.first
        let pw = rep?.pixelsWide ?? Int(bounds.width), ph = rep?.pixelsHigh ?? Int(bounds.height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let t = NSAffineTransform()
        t.scaleX(by: CGFloat(pw) / bounds.width, yBy: CGFloat(ph) / bounds.height)
        t.concat()
        render(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size // keep Retina DPI so pastes aren't 2x
        let out = NSImage(size: image.size)
        out.addRepresentation(bitmap)
        return out
    }

    func pngData() -> Data? {
        ImageTools.png(export())
    }
}

/// Keeps a document smaller than the viewport centred instead of pinned bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// "Drag Me" pill: drags the annotated image out as a PNG file.
final class DragHandle: NSView, NSDraggingSource {
    var file: () -> URL? = { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.borderWidth = 1
        let label = NSTextField(labelWithString: "Drag Me")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (frame.width - label.frame.width) / 2, y: (frame.height - label.frame.height) / 2)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(label)
        for x in [16, frame.width - 32] {
            let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)!)
            grip.frame = NSRect(x: x, y: (frame.height - 16) / 2, width: 16, height: 16)
            grip.contentTintColor = .tertiaryLabelColor
            addSubview(grip)
        }
        toolTip = "Drag the annotated image into any app"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let url = file() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: url))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

private extension NSToolbarItem.Identifier {
    static let tools = Self("tools"), color = Self("color"), stroke = Self("stroke")
    static let saveAs = Self("saveAs"), done = Self("done")
    static let edit = Self("edit")
}

final class AnnotateWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    private static var open: [AnnotateWindow] = []
    private static let palette: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Black", .black), ("White", .white),
    ]
    private static let strokes: [(String, CGFloat)] = [("Thin", 2), ("Medium", 4), ("Thick", 8)]

    private var canvas: Canvas!
    private var source: URL!
    private var scroll: NSScrollView!
    private var zoom: NSPopUpButton!
    private var toolsItem: NSToolbarItemGroup?
    private var colorItem: NSMenuToolbarItem?
    private var strokeItem: NSMenuToolbarItem?

    @discardableResult
    static func open(_ url: URL) -> AnnotateWindow? {
        let project: ShotProject?
        let image: NSImage
        do {
            if url.pathExtension.lowercased() == "leanshot" {
                let loaded = try ShotProject.read(url); image = try loaded.decodedImage(); project = loaded
            } else {
                guard let loaded = NSImage(contentsOf: url) else { return nil }; image = loaded; project = nil
            }
        } catch { NSAlert(error: error).runModal(); return nil }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(max(1040, image.size.width + 120), screen.width * 0.9),
                          height: min(max(420, image.size.height + 120 + 48), screen.height * 0.85 - 52))
        let w = AnnotateWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.titleVisibility = .hidden
        w.source = url
        w.isReleasedWhenClosed = false
        w.delegate = w
        w.minSize = NSSize(width: min(1040, screen.width * 0.9), height: 360)
        w.build(image: image)
        if let project { w.canvas.setFrameSize(project.canvasSize); w.canvas.marks = project.marks; w.resizeDocument() }
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.canvas)
        w.fit()
        open.append(w)
        return w
    }

    private func build(image: NSImage) {
        canvas = Canvas(image: image)
        canvas.onToolChange = { [weak self] t in self?.toolsItem?.selectedIndex = t.rawValue }
        canvas.onImageChange = { [weak self] in self?.resizeDocument() }
        canvas.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return s
        }()
        let pad: CGFloat = 48
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: image.size.width + pad * 2, height: image.size.height + pad * 2))
        canvas.frame.origin = NSPoint(x: pad, y: pad)
        doc.addSubview(canvas)

        let content = NSView(frame: NSRect(origin: .zero, size: contentLayoutRect.size))
        let barHeight: CGFloat = 52
        scroll = NSScrollView(frame: NSRect(x: 0, y: barHeight, width: content.bounds.width, height: content.bounds.height - barHeight))
        scroll.contentView = CenteringClipView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.backgroundColor = .controlBackgroundColor
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        content.addSubview(bottomBar(width: content.bounds.width, height: barHeight))
        contentView = content

        let toolbar = NSToolbar(identifier: "annotate")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbarStyle = .unified
        self.toolbar = toolbar
    }

    private func bottomBar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.autoresizingMask = [.width, .maxYMargin]
        let line = NSBox(frame: NSRect(x: 0, y: height - 1, width: width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .minYMargin]
        bar.addSubview(line)

        zoom = NSPopUpButton(frame: NSRect(x: 12, y: 11, width: 96, height: 30), pullsDown: true)
        zoom.addItem(withTitle: "100%")
        for (title, level) in [("Zoom to Fit", 0.0), ("50%", 0.5), ("100%", 1), ("200%", 2), ("400%", 4)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "") // addItem(withTitle:) dedupes "100%"
            item.tag = Int(level * 100)
            zoom.menu?.addItem(item)
        }
        zoom.target = self
        zoom.action = #selector(pickZoom(_:))
        bar.addSubview(zoom)

        let handle = DragHandle(frame: NSRect(x: (width - 190) / 2, y: 9, width: 190, height: 34))
        handle.autoresizingMask = [.minXMargin, .maxXMargin]
        handle.file = { [weak self] in self?.tempPNG() }
        bar.addSubview(handle)

        let actions: [(String, String, (AnnotateWindow, NSButton) -> Void)] = [
            ("square.and.arrow.up", "Share", { w, b in
                guard let url = w.tempPNG() else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
            }),
            ("pin", "Pin to Screen", { w, _ in PinWindow.pin(w.canvas.export()) }),
            ("doc.on.doc", "Copy (⌘C)", { w, _ in w.copyImage() }),
        ]
        for (i, (symbol, tip, run)) in actions.reversed().enumerated() {
            let b = ClosureButton(frame: NSRect(x: width - 12 - CGFloat(i + 1) * 48, y: 10, width: 42, height: 32)) {}
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.bezelStyle = .rounded
            b.autoresizingMask = [.minXMargin]
            b.setHandler { [weak self, weak b] in if let self, let b { run(self, b) } }
            bar.addSubview(b)
        }
        return bar
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .color, .stroke, .edit, .flexibleSpace, .saveAs, .done]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .tools:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: Tool.visible.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage(systemSymbolName: "square", accessibilityDescription: $0.label)! },
                                           selectionMode: .selectOne,
                                           labels: Tool.visible.map(\.label), target: self, action: #selector(pickTool))
            for (sub, t) in zip(group.subitems, Tool.visible) { sub.toolTip = "\(t.label) (\(t.key.uppercased()))" }
            group.selectedIndex = canvas.tool.rawValue
            group.controlRepresentation = .expanded
            toolsItem = group
            return group
        case .color:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Color"
            item.showsIndicator = true
            item.menu = NSMenu()
            for (name, c) in Self.palette {
                let m = NSMenuItem(title: name, action: #selector(pickColor(_:)), keyEquivalent: "")
                m.target = self
                m.image = Self.dot(c, 14)
                m.representedObject = c
                item.menu.addItem(m)
            }
            let custom = NSMenuItem(title: "Custom Color / Eyedropper…", action: #selector(customColor), keyEquivalent: "")
            custom.target = self; item.menu.addItem(custom)
            colorItem = item
            refreshColor()
            return item
        case .edit:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Image & Styles"; item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Image & Styles")
            item.showsIndicator = true; item.menu = NSMenu()
            let entries: [(String, Selector)] = [("Undo", #selector(undoEdit)), ("Redo", #selector(redoEdit)), ("Rotate Left", #selector(rotateLeft)), ("Rotate Right", #selector(rotateRight)), ("Flip Horizontal", #selector(flipHorizontal)), ("Flip Vertical", #selector(flipVertical)), ("Resize…", #selector(resizeImage)), ("Add Background…", #selector(background)), ("Insert Image…", #selector(insertImage)), ("Save Editable Project…", #selector(saveProject))]
            for (title, action) in entries { let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; item.menu.addItem(m) }
            func submenu(_ title: String, _ names: [String], _ action: Selector) {
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let sub = NSMenu()
                for (i, name) in names.enumerated() { let m = NSMenuItem(title: name, action: action, keyEquivalent: ""); m.tag = i; m.target = self; sub.addItem(m) }
                parent.submenu = sub; item.menu.addItem(parent)
            }
            submenu("Arrow Style", ["Filled", "Curved", "Double Headed", "Outline"], #selector(arrowStyle(_:)))
            submenu("Text Style", ["Outlined", "Bold", "Monospace", "Regular", "White Label", "Black Label", "Color Label"], #selector(textStyle(_:)))
            submenu("Crop Aspect Ratio", ["Freeform", "Square", "16:9", "4:3", "9:16"], #selector(cropAspect(_:)))
            return item
        case .stroke:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Stroke"
            item.showsIndicator = true
            item.image = NSImage(systemSymbolName: "lineweight", accessibilityDescription: "Stroke")
            item.menu = NSMenu()
            for (name, w) in Self.strokes {
                let m = NSMenuItem(title: name, action: #selector(pickStroke(_:)), keyEquivalent: "")
                m.target = self
                m.tag = Int(w)
                m.state = w == canvas.width ? .on : .off
                item.menu.addItem(m)
            }
            strokeItem = item
            return item
        case .saveAs, .done:
            let isDone = id == .done
            let b = ClosureButton(frame: .zero) { [weak self] in isDone ? self?.done() : self?.saveAs() }
            b.title = isDone ? "Done" : "Save as…"
            b.bezelStyle = .push
            b.controlSize = .large
            if isDone { b.keyEquivalent = "\r" } // default button → accent fill
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = b
            item.label = b.title
            return item
        default:
            return nil
        }
    }

    static func dot(_ color: NSColor, _ d: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    @objc private func pickTool(_ sender: Any) {
        if let i = toolsItem?.selectedIndex, let t = Tool(rawValue: i) { canvas.tool = t }
        makeFirstResponder(canvas)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? NSColor { canvas.color = c }
        refreshColor()
    }

    private func refreshColor() {
        colorItem?.image = Self.dot(canvas.color, 18)
        colorItem?.menu.items.forEach { $0.state = ($0.representedObject as? NSColor) == canvas.color ? .on : .off }
    }

    @objc private func pickStroke(_ sender: NSMenuItem) {
        canvas.width = CGFloat(sender.tag)
        strokeItem?.menu.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func customColor() {
        let p = NSColorPanel.shared; p.setTarget(self); p.setAction(#selector(colorChanged(_:))); p.color = canvas.color; p.orderFront(nil)
    }
    @objc private func colorChanged(_ sender: NSColorPanel) { canvas.color = sender.color; refreshColor() }
    @objc private func arrowStyle(_ sender: NSMenuItem) { canvas.arrowStyle = sender.tag; canvas.tool = .arrow }
    @objc private func textStyle(_ sender: NSMenuItem) { canvas.textStyle = sender.tag; canvas.tool = .text }
    @objc private func cropAspect(_ sender: NSMenuItem) { canvas.cropAspect = [0, 1, 16.0 / 9, 4.0 / 3, 9.0 / 16][sender.tag]; canvas.tool = .crop }
    @objc private func undoEdit() { canvas.undo() }
    @objc private func redoEdit() { canvas.redo() }
    @objc private func rotateLeft() { canvas.replaceImage(ImageTools.rotate(canvas.export(), clockwise: false)) }
    @objc private func rotateRight() { canvas.replaceImage(ImageTools.rotate(canvas.export(), clockwise: true)) }
    @objc private func flipHorizontal() { canvas.replaceImage(ImageTools.flip(canvas.export(), horizontal: true)) }
    @objc private func flipVertical() { canvas.replaceImage(ImageTools.flip(canvas.export(), horizontal: false)) }
    private func resizeDocument() {
        guard let canvas, let doc = scroll?.documentView else { return }
        doc.setFrameSize(NSSize(width: canvas.bounds.width + 96, height: canvas.bounds.height + 96)); canvas.frame.origin = NSPoint(x: 48, y: 48)
        doc.needsDisplay = true; fit()
    }
    @objc private func resizeImage() {
        let p = NSAlert(); p.messageText = "Resize Image"; p.informativeText = "Width in pixels. Height scales proportionally."
        let field = NSTextField(string: "\(Int(ImageTools.pixelSize(canvas.image).width))"); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        p.accessoryView = field; p.addButton(withTitle: "Resize"); p.addButton(withTitle: "Cancel")
        if p.runModal() == .alertFirstButtonReturn, let width = Double(field.stringValue), width.isFinite, (1...16384).contains(width) {
            let flat = canvas.export(); canvas.replaceImage(ImageTools.resize(flat, pixels: NSSize(width: width, height: width * flat.size.height / flat.size.width)))
        }
    }
    @objc private func insertImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true
        p.beginSheetModal(for: self) { [weak self] response in
            if response == .OK { for url in p.urls { if let image = NSImage(contentsOf: url) { self?.canvas.insertImage(image) } } }
        }
    }
    @objc private func saveProject() {
        let p = NSSavePanel(); p.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".leanshot"
        p.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let self, let url = p.url else { return }
            do { try ShotProject(canvas: self.canvas).write(url) } catch { NSAlert(error: error).runModal() }
        }
    }
    @objc private func background() {
        let alert = NSAlert(); alert.messageText = "Background"; alert.informativeText = "Add padding, rounded corners and a background. Apply can be undone."
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let presets = NSPopUpButton(); presets.addItems(withTitles: BackgroundStyle.names)
        let aspect = NSPopUpButton(); aspect.addItems(withTitles: ["Auto aspect", "Square", "Landscape 16:9", "Portrait 9:16", "4:3"])
        let align = NSPopUpButton(); align.addItems(withTitles: ["Left", "Center (Auto Balance)", "Right"]); align.selectItem(at: 1)
        let pad = NSTextField(string: "64"); let radius = NSTextField(string: "16")
        let shadow = NSButton(checkboxWithTitle: "Drop shadow", target: nil, action: nil); shadow.state = .on
        for v in [presets, aspect, align, NSTextField(labelWithString: "Padding (points)"), pad, NSTextField(labelWithString: "Corner radius"), radius, shadow] { stack.addArrangedSubview(v) }
        let saved = Settings.defaults.data(forKey: "backgroundPreset").flatMap { try? JSONDecoder().decode(BackgroundStyle.self, from: $0) }
        if let saved { presets.selectItem(at: saved.palette); aspect.selectItem(at: saved.aspect); align.selectItem(at: saved.alignment); pad.stringValue = "\(Int(saved.padding))"; radius.stringValue = "\(Int(saved.radius))"; shadow.state = saved.shadow ? .on : .off }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 260); alert.accessoryView = stack
        alert.addButton(withTitle: "Apply & Save Preset"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var style = BackgroundStyle(); style.palette = presets.indexOfSelectedItem; style.aspect = aspect.indexOfSelectedItem; style.alignment = align.indexOfSelectedItem
        style.padding = CGFloat(min(512, max(0, pad.doubleValue))); style.radius = CGFloat(min(256, max(0, radius.doubleValue))); style.shadow = shadow.state == .on
        if style.palette == 19 {
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }; style.customImage = data
        }
        Settings.defaults.set(try? JSONEncoder().encode(style), forKey: "backgroundPreset")
        canvas.replaceImage(style.apply(to: canvas.export()))
    }

    // MARK: Zoom

    private func fit() {
        guard let doc = scroll.documentView else { return }
        let clip = scroll.contentSize
        setZoom(min(1, clip.width / doc.frame.width, clip.height / doc.frame.height))
    }

    private func setZoom(_ level: CGFloat) {
        scroll.magnification = level
        zoomChanged()
    }

    @objc private func zoomChanged() { zoom.itemArray.first?.title = "\(Int((scroll.magnification * 100).rounded()))%" }

    @objc private func pickZoom(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 100
        tag == 0 ? fit() : setZoom(CGFloat(tag) / 100)
    }

    // MARK: Output

    private func tempPNG() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".png")
        guard let png = canvas.pngData(), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    private func copyImage() {
        Clipboard.copy(canvas.export())
        Toast.show("Copied")
    }

    /// Writes over the capture, copies it, and closes, like CleanShot's Done.
    private func done() {
        if source.pathExtension.lowercased() == "leanshot" {
            do { try ShotProject(canvas: canvas).write(source); close() } catch { NSAlert(error: error).runModal() }; return
        }
        guard let png = canvas.pngData() else { return }
        do {
            let destination = source.deletingLastPathComponent().standardizedFileURL == Capture.folder.standardizedFileURL && source.pathExtension.lowercased() == "png" ? source! : Capture.newURL("png")
            try png.write(to: destination, options: .atomic)
            Clipboard.copy(destination)
            QuickAccess.show(destination)
            close()
        } catch { NSAlert(error: error).runModal() }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " (annotated).png"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let png = self?.canvas.pngData() else { return }
            do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    /// No main menu in an accessory app, so the window routes shortcuts itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editingText = firstResponder is NSTextView
        if editingText, event.charactersIgnoringModifiers == "\r" { return false } // Return commits text, not Done
        if editingText, event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers {
            let edits: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                             "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                                             "z": Selector(("undo:"))]
            if let action = edits[key] { return NSApp.sendAction(action, to: nil, from: self) }
        }
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "z" where !editingText: event.modifierFlags.contains(.shift) ? canvas.redo() : canvas.undo()
        case "v" where !editingText:
            if let image = NSImage(pasteboard: .general) { canvas.insertImage(image) }
        case "c" where !editingText: copyImage()
        case "s": done()
        case "w": close()
        case "=", "+": setZoom(scroll.magnification * 1.25)
        case "-": setZoom(scroll.magnification / 1.25)
        case "0": setZoom(1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        AnnotateWindow.open.removeAll { $0 === self }
    }

    /// Dev aid: `LeanShot --preview in.png out.png` opens the editor and saves a picture of the window.
    static func preview(_ input: URL, to output: URL) {
        guard let w = open(input) else { print("cannot open \(input.path)"); exit(1) }
        w.canvas.marks = [
            Mark(tool: .arrow, points: [CGPoint(x: 30, y: 30), CGPoint(x: 160, y: 90)], color: .systemRed, width: 4),
            Mark(tool: .rect, points: [CGPoint(x: 180, y: 20), CGPoint(x: 300, y: 100)], color: .systemGreen, width: 4),
            Mark(tool: .counter, points: [CGPoint(x: 330, y: 60)], color: .systemBlue, width: 4),
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            var v = w.contentView!
            while let parent = v.superview { v = parent }
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            print("wrote \(output.path)")
            exit(0)
        }
    }
}

enum SelfTest {
    /// `LeanShot --selftest`: checks annotation export keeps full resolution and OCR reads rendered text.
    static func run() {
        let size = NSSize(width: 400, height: 120)
        let src = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
            ("LeanShot 2026" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: attrs)
            return true
        }
        let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        retina.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: retina)
        src.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let png = retina.representation(using: .png, properties: [:])!
        let image = NSImage(data: png)!
        let pixels = (image.representations[0].pixelsWide, image.representations[0].pixelsHigh)

        let canvas = Canvas(image: image, size: NSSize(width: 200, height: 60)) // half-size view, like a fitted window
        canvas.marks = [Mark(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 190, y: 50)], color: .red, width: 4)]
        let out = canvas.export()
        assert(out.representations[0].pixelsWide == pixels.0 && out.representations[0].pixelsHigh == pixels.1, "export lost resolution")
        let saved = NSImage(data: NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!)!
        assert(saved.size == size, "export lost DPI: \(saved.size)")
        let rep = out.representations[0] as! NSBitmapImageRep
        let mid: NSColor = rep.colorAt(x: pixels.0 / 2, y: pixels.1 / 2)!   // arrow passes through the centre
        let isRed: Bool = mid.redComponent > 0.8 && mid.greenComponent < 0.3
        assert(isRed, "arrow not rendered: \(mid)")

        let arrow = Canvas.arrowPath(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        assert(arrow.contains(CGPoint(x: 99, y: 0)) && !arrow.contains(CGPoint(x: 101, y: 0)), "arrow tip off")

        var text = ""
        let done = DispatchSemaphore(value: 0)
        OCR.recognize(image) { text = $0; done.signal() }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        assert(text.contains("LeanShot"), "OCR read: \(text)")
        print("selftest ok: export \(pixels.0)x\(pixels.1), OCR \"\(text)\"")
    }
}
