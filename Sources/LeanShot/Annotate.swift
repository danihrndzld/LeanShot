import AppKit
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum Tool: Int, CaseIterable, Codable {
    case select, rect, filledRect, ellipse, line, arrow, text, pixelate, highlight, counter, pen
    case blur, spotlight, crop, redact, image
    static var visible: [Tool] { allCases.filter { $0 != .image } }
    /// Crop has its own toolbar button, so the tool group stays compact.
    static var grouped: [Tool] { visible.filter { ![.crop, .blur, .redact].contains($0) } }
    /// Redaction styles of the pixelate tool: title, SF Symbol, slider meaning.
    static let redactions: [(String, String, String)] = [("Pixelate", "squareshape.split.3x3", "Pixel Size"), ("Gaussian Blur", "drop.halffull", "Blur Radius"),
                                                         ("Secure Blur", "lock.shield", "Strength"), ("Black Bar", "rectangle.fill", "")]
    var symbol: String { traits.symbol }
    var label: String { traits.label }
    /// CleanShot-compatible single-key shortcuts while the canvas has focus.
    var key: String { traits.key }
    /// One exhaustive table: a new tool fails to compile until it says how it looks, selects and resizes.
    var traits: ToolTraits {
        switch self {
        case .select: ToolTraits(symbol: "cursorarrow", label: "Select", key: "v")
        case .rect: ToolTraits(symbol: "square", label: "Rectangle", key: "r", lifted: true)
        case .filledRect: ToolTraits(symbol: "square.fill", label: "Filled Rectangle", key: "f", lifted: true)
        case .ellipse: ToolTraits(symbol: "circle", label: "Ellipse", key: "e", lifted: true)
        case .line: ToolTraits(symbol: "line.diagonal", label: "Line", key: "l", handles: .endpoints, lifted: true)
        case .arrow: ToolTraits(symbol: "arrow.up.right", label: "Arrow", key: "a", handles: .endpoints, lifted: true, styles: 4)
        case .text: ToolTraits(symbol: "textformat", label: "Text", key: "t", handles: .none, styles: 7)
        case .pixelate: ToolTraits(symbol: "squareshape.split.3x3", label: "Blur & Redact", key: "x", styles: Tool.redactions.count)
        case .highlight: ToolTraits(symbol: "highlighter", label: "Highlight", key: "m")
        case .counter: ToolTraits(symbol: "1.circle.fill", label: "Counter", key: "c", handles: .none, lifted: true)
        case .pen: ToolTraits(symbol: "pencil.tip", label: "Pen", key: "d", handles: .none, lifted: true)
        case .blur: ToolTraits(symbol: "drop.halffull", label: "Gaussian Blur", key: "u")
        case .spotlight: ToolTraits(symbol: "light.max", label: "Spotlight", key: "h")
        case .crop: ToolTraits(symbol: "crop", label: "Crop", key: "k")
        case .redact: ToolTraits(symbol: "rectangle.fill", label: "Black Bar", key: "p")
        case .image: ToolTraits(symbol: "photo", label: "Image", key: "")
        }
    }
}

struct ToolTraits {
    /// Corner handles for boxes, endpoint handles for lines; text, counters and pen strokes only move.
    enum Handles { case corners, endpoints, none }
    var symbol: String, label: String, key: String
    var handles: Handles = .corners
    /// Vector marks get a soft drop shadow; area effects keep exact pixels.
    var lifted = false
    /// Number of valid `Mark.style` values; 0 means the tool has no styles.
    var styles = 0
}

/// Editor shortcuts beyond tool keys. One table feeds the key handling and the Settings list.
enum EditorShortcut: CaseIterable {
    case copyObject, duplicate, save, saveAs, copyScreenshot, print, pin, addScreenshot, addFromFile, background, increaseSize, decreaseSize
    case undo, redo, paste, close, zoomIn, zoomOut, actualSize
    var title: String {
        switch self {
        case .undo: "Undo"
        case .redo: "Redo"
        case .paste: "Paste Object or Image"
        case .close: "Close Window"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .copyObject: "Copy Object to Clipboard"
        case .duplicate: "Duplicate Object"
        case .save: "Save"
        case .saveAs: "Save as"
        case .copyScreenshot: "Copy Screenshot to Clipboard"
        case .print: "Print"
        case .pin: "Pin to the Screen"
        case .addScreenshot: "Add New Screenshot"
        case .addFromFile: "Add Screenshot From File"
        case .background: "Background Tool"
        case .increaseSize: "Increase Tool Size"
        case .decreaseSize: "Decrease Tool Size"
        }
    }
    var key: String {
        switch self {
        case .copyObject, .copyScreenshot: "c"
        case .duplicate: "d"
        case .save, .saveAs: "s"
        case .print, .pin: "p"
        case .addScreenshot, .addFromFile: "i"
        case .background: "b"
        case .increaseSize: "]"
        case .decreaseSize: "["
        case .undo, .redo: "z"
        case .paste: "v"
        case .close: "w"
        case .zoomIn: "="
        case .zoomOut: "-"
        case .actualSize: "0"
        }
    }
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .copyObject, .duplicate, .save, .print, .addFromFile, .undo, .paste, .close, .zoomIn, .zoomOut, .actualSize: [.command]
        case .saveAs, .copyScreenshot, .addScreenshot, .pin, .redo: [.command, .shift]
        case .background, .increaseSize, .decreaseSize: []
        }
    }
    /// "⇧⌘S" style label.
    var display: String {
        let key = self == .zoomIn ? "+" : self == .zoomOut ? "−" : self.key.uppercased()
        return (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key
    }
    static func matching(_ event: NSEvent) -> EditorShortcut? {
        var flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "+" { key = "="; flags.remove(.shift) } // ⌘+ is ⇧⌘= on most layouts
        return allCases.first { $0.key == key && $0.modifiers == flags }
    }
}

struct Mark: Codable, Equatable {
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
        guard width.isFinite, (0.1...256).contains(width), points.count >= 2 || tool.traits.handles == .none else { throw CocoaError(.fileReadCorruptFile) }
        text = try c.decode(String.self, forKey: .text); style = try c.decodeIfPresent(Int.self, forKey: .style) ?? 0
        // Older files stamped the arrow style on every shape, so only tools with styles validate it.
        let styles = tool.traits.styles
        guard styles == 0 || (0..<styles).contains(style) else { throw CocoaError(.fileReadCorruptFile) }
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
        case .select, .rect, .filledRect, .ellipse, .line, .arrow, .pixelate, .highlight, .blur, .spotlight, .crop, .redact, .image:
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
    var image: NSImage { didSet { highlightRects = nil; effects = [:]; if tool == .highlight { detectHighlightText() } } }
    /// Full-image redaction layers keyed by style and amount; each mark clips one to its rect.
    private var effects: [String: NSImage] = [:]
    private var ciInput: (source: NSImage, image: CIImage)?
    var marks: [Mark] = [] { didSet { invalidate(from: oldValue) } }
    /// Dragging one mark repaints only where it was and where it is (~6x less work than the whole Retina canvas).
    /// Spotlights dim everything and counters renumber, so changes to those still repaint it all.
    private func invalidate(from old: [Mark]) {
        guard old.count == marks.count else { needsDisplay = true; return }
        var dirty = CGRect.null
        for i in marks.indices where marks[i] != old[i] {
            // Curved arrows bulge past their chord and monospace text outgrows bounds: repaint those in full.
            if [.spotlight, .counter, .text].contains(marks[i].tool) || (marks[i].tool == .arrow && marks[i].style == 1) { needsDisplay = true; return }
            for m in [old[i], marks[i]] { dirty = dirty.union(m.bounds.insetBy(dx: -max(24, m.width * 3), dy: -max(24, m.width * 3))) }
        }
        if !dirty.isNull { setNeedsDisplay(dirty.insetBy(dx: -12 * chromeScale, dy: -12 * chromeScale)) } // handles and outline
    }
    var tool: Tool = .arrow { didSet { selected = nil; dragFrom = nil; onToolChange?(tool); if tool == .highlight { detectHighlightText() }; remember() } }
    private var highlightRects: [CGRect]?
    private func detectHighlightText() {
        guard highlightRects == nil else { return }
        highlightRects = []
        let source = image
        OCR.textRects(source) { [weak self] rects in if let self, self.image === source { self.highlightRects = rects } }
    }
    var color: NSColor = .systemRed { didSet { if let selected { checkpoint(); marks[selected].color = color }; remember() } }
    var width: CGFloat = 5 { didSet { if let selected, marks[selected].tool != .pixelate { checkpoint(); marks[selected].width = width }; remember() } }
    /// Redaction: 0 pixelate, 1 gaussian, 2 secure (pixelate + blur), 3 black bar. Amount is block size / radius in points.
    var redactStyle = 0 { didSet { adjustRedaction { $0.style = redactStyle }; remember() } }
    var redactAmount: CGFloat = 14 { didSet { adjustRedaction { $0.width = redactAmount }; remember() } }
    private var adjusting: Int? // slider drags on one mark share a single undo step
    private func adjustRedaction(_ change: (inout Mark) -> Void) {
        guard let i = selected, marks[i].tool == .pixelate else { return }
        if adjusting != i { checkpoint(); adjusting = i }
        change(&marks[i])
    }
    var arrowStyle = 0 { didSet { remember() } }
    var textStyle = 0 { didSet { remember() } }
    /// Editor windows remember tool, color, sizes and styles across captures; tests and previews leave it off.
    var remembersChoices = false
    private func remember() {
        guard remembersChoices else { return }
        // Slider drags fire per tick; write once they settle, like BackgroundInspector.persist().
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveChoices), object: nil)
        perform(#selector(saveChoices), with: nil, afterDelay: 0.5)
    }
    @objc private func saveChoices() {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        Settings.editorChoices = ["tool": Double(tool == .crop ? Tool.arrow.rawValue : tool.rawValue), "width": width, "redactStyle": Double(redactStyle),
                                  "redactAmount": redactAmount, "arrowStyle": Double(arrowStyle), "textStyle": Double(textStyle),
                                  "r": rgb.redComponent, "g": rgb.greenComponent, "b": rgb.blueComponent, "a": rgb.alphaComponent]
    }
    func restoreChoices() {
        let c = Settings.editorChoices
        if let t = c["tool"].flatMap({ Tool(rawValue: Int($0)) }), Tool.grouped.contains(t) { tool = t }
        if let w = c["width"], (2...40).contains(w) { width = w }
        if let s = c["redactStyle"], Tool.redactions.indices.contains(Int(s)) { redactStyle = Int(s) }
        if let a = c["redactAmount"], (4...40).contains(a) { redactAmount = a }
        if let s = c["arrowStyle"], (0..<4).contains(Int(s)) { arrowStyle = Int(s) }
        if let s = c["textStyle"], (0..<7).contains(Int(s)) { textStyle = Int(s) }
        if let r = c["r"], let g = c["g"], let b = c["b"] { color = NSColor(srgbRed: r, green: g, blue: b, alpha: c["a"] ?? 1) }
        remembersChoices = true
    }
    var cropAspect: CGFloat = 0
    var onImageChange: (() -> Void)?
    var onToolChange: ((Tool) -> Void)?
    var onKey: ((EditorShortcut) -> Void)?
    /// Copied annotation, valid while the general pasteboard still holds what we put there.
    private static var copied: (mark: Mark, change: Int)?
    private struct State { var image: NSImage; var marks: [Mark]; var size: NSSize }
    private var history: [State] = []
    private var future: [State] = []
    var selected: Int? { didSet { needsDisplay = true; adjusting = nil } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private enum Drag { case draw, move, resize(Int) }
    private var drag: Drag?
    private var dragFrom: CGPoint?
    private var moveUnsaved = false // a click on a mark only records undo once it actually moves
    private var editor: NSTextField?
    /// 1 / magnification, so selection chrome keeps its on-screen size at any zoom.
    var chromeScale: CGFloat = 1 { didSet { needsDisplay = true } }

    init(image: NSImage, size: NSSize? = nil) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size ?? image.size))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    // An explicit shadow path keeps the drop shadow off the per-frame offscreen pass.
    override var shadow: NSShadow? { didSet { updateShadowPath() } }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateShadowPath() }
    private func updateShadowPath() { layer?.shadowPath = CGPath(rect: bounds, transform: nil) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil; NSCursor.arrow.set() }

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
        let s = chromeScale
        if let h = hovered, h != selected, h < marks.count, let outline = chromeOutline(marks[h]) {
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke(); outline.lineWidth = 1 * s; outline.stroke()
        }
        guard let i = selected, i < marks.count else { return }
        if let outline = chromeOutline(marks[i]) { NSColor.controlAccentColor.setStroke(); outline.lineWidth = 1.5 * s; outline.stroke() }
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowBlurRadius = 3 * s; glow.shadowOffset = NSSize(width: 0, height: -1 * s); glow.shadowColor = .black.withAlphaComponent(0.3); glow.set()
        for h in handles(marks[i]) {
            let dot = NSBezierPath(ovalIn: NSRect(x: h.x - 6 * s, y: h.y - 6 * s, width: 12 * s, height: 12 * s))
            NSColor.controlAccentColor.setFill(); dot.fill()
            NSColor.white.setStroke(); dot.lineWidth = 2 * s; dot.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Selection outline: hugs both edges of stroked shapes, a soft box around everything else.
    private func chromeOutline(_ m: Mark) -> NSBezierPath? {
        switch m.tool {
        case .line, .arrow: return nil // endpoint handles say enough
        case .rect, .ellipse: return centerline(m).map { NSBezierPath(cgPath: $0.cgPath.copy(strokingWithWidth: m.width, lineCap: .round, lineJoin: .round, miterLimit: 10)) }
        case .pen, .text, .counter: return NSBezierPath(roundedRect: m.bounds, xRadius: 4 * chromeScale, yRadius: 4 * chromeScale)
        case .select, .filledRect, .pixelate, .highlight, .blur, .spotlight, .crop, .redact, .image: return NSBezierPath(roundedRect: m.rect.insetBy(dx: -2 * chromeScale, dy: -2 * chromeScale), xRadius: 3, yRadius: 3)
        }
    }

    func render(in rect: NSRect) {
        image.draw(in: rect)
        let spotlights = marks.filter { $0.tool == .spotlight }
        if !spotlights.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.withAlphaComponent(0.62).setFill(); rect.fill()
            context.setBlendMode(.clear)
            spotlights.forEach { NSBezierPath(roundedRect: $0.rect, xRadius: 6, yRadius: 6).fill() }
            context.setBlendMode(.normal); context.endTransparencyLayer(); context.restoreGState()
        }
        var counter = 0
        for m in marks {
            if m.tool == .counter { counter += 1 }
            draw(m, imageRect: rect, number: counter)
        }
    }

    private func draw(_ m: Mark, imageRect: NSRect, number: Int) {
        m.color.set()
        // Soft lift for vector marks only; area effects must keep exact pixels. One shadow per mark keeps each
        // blur bounded by the mark; a shared transparency layer measured 6x slower (full-canvas offscreen).
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState(); defer { context?.restoreGState() }
        if m.tool.traits.lifted, let context {
            let k = abs(context.userSpaceToDeviceSpaceTransform.a) // shadows live in device space
            context.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 3 * k, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        }
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
            // Legacy .blur marks render as a gaussian at their original strength.
            let style = m.tool == .blur ? 1 : m.style, amount = m.tool == .blur ? 18 : m.width
            if style == 3 { NSColor.black.setFill(); m.rect.fill(); break }
            if let (layer, frame) = effect(style, amount, m.rect, imageRect) { layer.draw(in: frame) }
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

    /// Redaction pixels for one mark's rect only, so a new mark or a slider step costs its own area, not the whole capture.
    /// Pixellate keeps its grid anchored at the image origin, so a moved mark still lines up.
    private func effect(_ style: Int, _ amount: CGFloat, _ rect: CGRect, _ imageRect: CGRect) -> (NSImage, CGRect)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = CGFloat(cg.width) / max(1, imageRect.width)
        let pixels = CGRect(x: (rect.minX - imageRect.minX) * s, y: (rect.minY - imageRect.minY) * s, width: rect.width * s, height: rect.height * s)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixels.isEmpty else { return nil }
        let frame = CGRect(x: imageRect.minX + pixels.minX / s, y: imageRect.minY + pixels.minY / s, width: pixels.width / s, height: pixels.height / s)
        let key = "\(style)-\(Int(amount))-\(pixels)"
        if let cached = effects[key] { return (cached, frame) }
        if ciInput?.source !== image { ciInput = (image, CIImage(cgImage: cg)) }
        guard let input = ciInput?.image else { return nil }
        // Never weaker than 6 pt blocks: old projects stored stroke widths here.
        let scale = CGFloat(cg.width) / max(1, image.size.width), px = max(6, amount) * scale
        var out = input.clampedToExtent()
        func pixellate(_ size: CGFloat) { let f = CIFilter.pixellate(); f.inputImage = out; f.scale = Float(size); f.center = .zero; out = f.outputImage ?? out }
        switch style {
        case 1: out = out.applyingGaussianBlur(sigma: Double(px * 0.5))
        case 2: // Secure: quantize, blur, quantize again on another grid, so block-average inversion has nothing to recover.
            let block = max(px, 12 * scale)
            pixellate(block); out = out.applyingGaussianBlur(sigma: Double(block * 0.4)); pixellate(block * 0.75)
        default: pixellate(px)
        }
        guard let result = ImageTools.ciContext.createCGImage(out, from: pixels) else { return nil }
        if effects.count > 32 { effects.removeAll() } // drags and slider steps mint one entry per frame
        let layer = NSImage(cgImage: result, size: frame.size)
        effects[key] = layer
        return (layer, frame)
    }

    // MARK: Editing

    private var state: State { State(image: image, marks: marks, size: bounds.size) }
    private func corners(_ rect: CGRect) -> [CGPoint] { [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)] }
    /// Corners for boxes, endpoints for lines and arrows; freeform marks only move.
    private func handles(_ m: Mark) -> [CGPoint] {
        switch m.tool.traits.handles {
        case .endpoints: return [m.points[0], m.points[m.points.count - 1]]
        case .none: return []
        case .corners: return corners(m.rect)
        }
    }
    /// Stroked shapes are hit along their stroke, so you can still draw inside an outlined box.
    private func centerline(_ m: Mark) -> NSBezierPath? {
        switch m.tool {
        case .rect: return NSBezierPath(roundedRect: m.rect, xRadius: 3, yRadius: 3)
        case .ellipse: return NSBezierPath(ovalIn: m.rect)
        case .line, .arrow, .pen:
            let p = NSBezierPath(); p.move(to: m.points[0]); m.points.dropFirst().forEach { p.line(to: $0) }; return p
        case .select, .filledRect, .text, .pixelate, .highlight, .counter, .blur, .spotlight, .crop, .redact, .image: return nil
        }
    }
    private func hits(_ m: Mark, _ p: CGPoint) -> Bool {
        guard let line = centerline(m) else { return m.bounds.contains(p) }
        let reach = max(m.width + 10 * chromeScale, 14 * chromeScale)
        return line.cgPath.copy(strokingWithWidth: reach, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }
    private func handle(at p: CGPoint) -> Int? {
        guard let i = selected, i < marks.count else { return nil }
        return handles(marks[i]).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 10 * chromeScale }
    }
    /// Pen and crop always draw; every other tool grabs an existing mark first.
    func mark(at p: CGPoint) -> Int? {
        if tool == .pen || tool == .crop { return nil }
        // Select also grabs an outlined box by its interior.
        return marks.indices.last { hits(marks[$0], p) } ?? (tool == .select ? marks.indices.last { marks[$0].bounds.contains(p) } : nil)
    }
    private func updateHover(_ p: CGPoint) {
        if let h = handle(at: p) {
            hovered = nil
            if #available(macOS 15, *), handles(marks[selected!]).count == 4 {
                let positions: [NSCursor.FrameResizePosition] = [.bottomLeft, .bottomRight, .topRight, .topLeft]
                NSCursor.frameResize(position: positions[h], directions: .all).set()
            } else { NSCursor.crosshair.set() }
            return
        }
        hovered = mark(at: p)
        (hovered != nil ? NSCursor.openHand : tool == .text ? NSCursor.iBeam : tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
    }
    /// Shift snaps lines to 45° steps.
    private func snapped(_ p: CGPoint, from o: CGPoint) -> CGPoint {
        let angle = (atan2(p.y - o.y, p.x - o.x) / (.pi / 4)).rounded() * .pi / 4, r = hypot(p.x - o.x, p.y - o.y)
        return CGPoint(x: o.x + r * cos(angle), y: o.y + r * sin(angle))
    }
    private func checkpoint() { history.append(state); future.removeAll(); window?.isDocumentEdited = true }
    /// Cross-fades the next redraw: undo, deletes and image edits change state without a jump cut.
    private func crossfade(_ duration: CFTimeInterval = 0.18) {
        guard !Anim.reduced else { return }
        let t = CATransition(); t.type = .fade; t.duration = duration; t.timingFunction = Anim.easeOut
        layer?.add(t, forKey: "fade")
    }
    private func restore(_ state: State) {
        crossfade()
        image = state.image; marks = state.marks; setFrameSize(state.size)
        effects = [:]; selected = nil; hovered = nil; dragFrom = nil; onImageChange?()
    }

    func undo() {
        guard let last = history.popLast() else { return NSSound.beep() }
        future.append(state); restore(last)
    }
    func redo() { guard let next = future.popLast() else { return NSSound.beep() }; history.append(state); restore(next) }
    func replaceImage(_ newImage: NSImage) {
        crossfade(0.25)
        checkpoint(); image = newImage; marks = []; setFrameSize(newImage.size)
        effects = [:]; selected = nil; hovered = nil; onImageChange?(); needsDisplay = true
    }
    func insertImage(_ image: NSImage, at point: CGPoint? = nil) {
        commitText(); checkpoint()
        let scale = min(1, bounds.width * 0.65 / image.size.width, bounds.height * 0.65 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let center = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let origin = CGPoint(x: min(max(0, center.x - size.width / 2), bounds.width - size.width), y: min(max(0, center.y - size.height / 2), bounds.height - size.height))
        crossfade()
        marks.append(Mark(tool: .image, points: [origin, CGPoint(x: origin.x + size.width, y: origin.y + size.height)], color: .clear, width: 1, imageData: ImageTools.png(image)))
        tool = .select; selected = marks.count - 1
    }

    /// ⌘C on a selection copies the object (as an image for other apps, as a layer for ⌘V here).
    func copySelection() -> Bool {
        guard let i = selected, i < marks.count else { return false }
        let m = marks[i], r = m.bounds
        let picture = NSImage(size: r.size, flipped: false) { _ in
            let t = NSAffineTransform(); t.translateX(by: -r.minX, yBy: -r.minY); t.concat()
            self.draw(m, imageRect: self.bounds, number: self.marks[...i].filter { $0.tool == .counter }.count)
            return true
        }
        Clipboard.copy(picture)
        Canvas.copied = (m, Clipboard.pasteboard.changeCount)
        return true
    }
    func pasteMark() -> Bool {
        guard var copy = Canvas.copied, copy.change == Clipboard.pasteboard.changeCount else { return false }
        copy.mark.move(by: 12, -12); Canvas.copied = copy
        add(copy.mark); return true
    }
    func duplicateSelection() -> Bool {
        guard let i = selected, i < marks.count else { return false }
        var m = marks[i]; m.move(by: 12, -12); add(m); return true
    }
    private func add(_ mark: Mark) {
        commitText(); checkpoint(); crossfade(0.12)
        marks.append(mark); selected = marks.count - 1
    }

    /// A ring that expands from a freshly placed counter.
    private func ripple(at center: CGPoint, diameter d: CGFloat, color: NSColor) {
        guard !Anim.reduced, let layer else { return }
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = nil; ring.strokeColor = color.cgColor; ring.lineWidth = 2; ring.opacity = 0
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.7; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.4; group.timingFunction = Anim.easeOut
        CATransaction.begin(); CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: nil); CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let h = handle(at: p) { drag = .resize(h); dragFrom = p; moveUnsaved = true; return }
        if event.clickCount == 2, let i = mark(at: p), marks[i].tool == .text {
            // Double-click a text mark to fix it in place, keeping its color, size and style.
            let m = marks[i]
            checkpoint(); marks.remove(at: i); selected = nil
            color = m.color; width = m.width; textStyle = m.style
            beginText(at: m.points[0], text: m.text); return
        }
        if let i = mark(at: p) {
            selected = i; hovered = nil; drag = .move; dragFrom = p; moveUnsaved = true
            NSCursor.closedHand.set(); return
        }
        selected = nil
        switch tool {
        case .select:
            break
        case .text:
            beginText(at: p)
        case .counter:
            checkpoint()
            marks.append(Mark(tool: .counter, points: [p], color: color, width: width))
            ripple(at: p, diameter: Mark.counterDiameter(width), color: color)
        case .rect, .filledRect, .ellipse, .line, .arrow, .pixelate, .highlight, .pen, .blur, .spotlight, .crop, .redact, .image:
            checkpoint()
            let redaction = tool == .pixelate
            marks.append(Mark(tool: tool, points: [p, p], color: color, width: redaction ? redactAmount : width, style: redaction ? redactStyle : tool == .arrow ? arrowStyle : 0))
            drag = .draw; dragFrom = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom, let drag else { return }
        var p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .move:
            guard let i = selected else { return }
            if moveUnsaved { checkpoint(); moveUnsaved = false }
            marks[i].move(by: p.x - from.x, p.y - from.y)
            dragFrom = p
        case .resize(let h):
            guard let i = selected else { return }
            if moveUnsaved { checkpoint(); moveUnsaved = false }
            if marks[i].tool.traits.handles == .endpoints {
                let index = h == 0 ? 0 : marks[i].points.count - 1, other = marks[i].points[h == 0 ? marks[i].points.count - 1 : 0]
                marks[i].points[index] = shift ? snapped(p, from: other) : p
            } else {
                let opposite = corners(marks[i].rect)[(h + 2) % 4]
                if marks[i].tool == .image || shift {
                    let ratio = marks[i].rect.width / max(1, marks[i].rect.height)
                    p.y = opposite.y + (p.y > opposite.y ? 1 : -1) * abs(p.x - opposite.x) / ratio
                }
                if abs(p.x - opposite.x) > 2, abs(p.y - opposite.y) > 2 {
                    marks[i].points = [opposite, p]
                    // Keep the grabbed handle under the pointer after the rect normalizes.
                    self.drag = .resize(corners(marks[i].rect).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 0.5 } ?? h)
                }
            }
        case .draw:
            if tool == .pen { marks[marks.count - 1].points.append(p); return }
            if tool == .crop { p.x = min(max(0, p.x), bounds.width); p.y = min(max(0, p.y), bounds.height) }
            let endpoints = tool.traits.handles == .endpoints
            if shift, endpoints { p = snapped(p, from: from) }
            let aspect = tool == .crop && cropAspect > 0 ? cropAspect : shift && !endpoints ? 1 : 0
            if aspect > 0 { p.y = from.y + (p.y >= from.y ? 1 : -1) * abs(p.x - from.x) / aspect }
            marks[marks.count - 1].points[1] = p
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragFrom = nil; drag = nil; updateHover(convert(event.locationInWindow, from: nil)) }
        guard case .draw = drag else { return }
        if tool == .highlight, let mark = marks.last, mark.tool == .highlight, let highlightRects {
            let boxes = highlightRects.map { CGRect(x: $0.minX * bounds.width, y: $0.minY * bounds.height, width: $0.width * bounds.width, height: $0.height * bounds.height) }.filter { $0.intersects(mark.rect) }
            if let first = boxes.first {
                let line = boxes.dropFirst().reduce(first) { $0.union($1) }
                marks[marks.count - 1].points = [CGPoint(x: mark.rect.minX, y: line.minY - 1), CGPoint(x: mark.rect.maxX, y: line.maxY + 1)]
            }
        }
        if tool == .crop, let m = marks.last, m.tool == .crop {
            marks.removeLast()
            if m.rect.width > 1, m.rect.height > 1 {
                crossfade(0.25)
                let flat = export()
                let r = CGRect(x: m.rect.minX / bounds.width * flat.size.width, y: m.rect.minY / bounds.height * flat.size.height, width: m.rect.width / bounds.width * flat.size.width, height: m.rect.height / bounds.height * flat.size.height)
                image = ImageTools.crop(flat, to: r); marks = []; setFrameSize(image.size)
                effects = [:]; onImageChange?()
            } else { _ = history.popLast() }
            needsDisplay = true; return
        }
        // A click without a drag leaves an empty shape behind; drop it.
        if let m = marks.last, m.points.count == 2, m.points[0] == m.points[1] {
            marks.removeLast()
            _ = history.popLast()
        } else if tool != .pen {
            selected = marks.count - 1 // the new shape is immediately editable
        }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let nudges: [UInt16: (CGFloat, CGFloat)] = [123: (-step, 0), 124: (step, 0), 125: (0, -step), 126: (0, step)]
        if [51, 117].contains(event.keyCode), let i = selected { // delete / forward delete
            checkpoint()
            crossfade(0.15)
            selected = nil; hovered = nil
            dragFrom = nil
            marks.remove(at: i)
        } else if let i = selected, let (dx, dy) = nudges[event.keyCode] {
            if !event.isARepeat { checkpoint() }
            marks[i].move(by: dx, dy)
        } else if event.keyCode == 53, selected != nil {
            selected = nil
        } else if let shortcut = EditorShortcut.matching(event), shortcut.modifiers.isEmpty {
            onKey?(shortcut)
        } else if plain, let c = event.charactersIgnoringModifiers?.lowercased(), !c.isEmpty,
                  let t = Tool.allCases.first(where: { $0.key == c }) {
            if t == .blur || t == .redact { redactStyle = t == .blur ? 1 : 3; tool = .pixelate } else { tool = t }
        } else {
            super.keyDown(with: event)
        }
    }

    private func beginText(at p: CGPoint, text: String = "") {
        let f = NSTextField(string: text)
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
        selected = marks.count - 1 // like every other shape, the new text stays selected
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
        // Centre within the area left visible by the glass toolbar and floating controls.
        let inset = contentInsets, visible = NSSize(width: r.width - inset.left - inset.right, height: r.height - inset.top - inset.bottom)
        if visible.width > doc.frame.width { r.origin.x = (doc.frame.width - visible.width) / 2 - inset.left }
        if visible.height > doc.frame.height { r.origin.y = (doc.frame.height - visible.height) / 2 - inset.bottom }
        return r
    }
}

/// Scroll document: margin + live background preview, with the canvas placed where `ShotBackground` puts the screenshot.
final class Backdrop: NSView {
    static let margin: CGFloat = 48
    let canvas: Canvas
    var style: ShotBackground? { didSet { relayout() } }
    private var edge = NSColor.white
    private weak var edgeSource: NSImage?
    private let canvasShadow = NSShadow()

    init(canvas: Canvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        canvasShadow.shadowBlurRadius = 24; canvasShadow.shadowOffset = NSSize(width: 0, height: -6); canvasShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        addSubview(canvas)
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    func relayout() {
        let m = Self.margin, size = canvas.bounds.size
        if let style {
            let (total, _, shot) = style.layout(size)
            if style.inset > 0, edgeSource !== canvas.image { edge = ShotBackground.edgeColor(canvas.image); edgeSource = canvas.image } // once per image, not per slider tick
            setFrameSize(NSSize(width: total.width + m * 2, height: total.height + m * 2))
            canvas.setFrameOrigin(NSPoint(x: m + shot.minX, y: m + shot.minY))
            canvas.shadow = nil
            canvas.layer?.cornerRadius = style.screenshotRadius; canvas.layer?.masksToBounds = style.screenshotRadius > 0
        } else {
            setFrameSize(NSSize(width: size.width + m * 2, height: size.height + m * 2))
            canvas.setFrameOrigin(NSPoint(x: m, y: m))
            canvas.layer?.cornerRadius = 0; canvas.layer?.masksToBounds = false
            canvas.shadow = canvasShadow
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let m = Self.margin
        let (total, card, _) = style.layout(canvas.bounds.size)
        let rect = NSRect(x: m, y: m, width: total.width, height: total.height)
        if style.isTransparent { BackgroundInspector.checkerboard(rect, cell: 10) } else { style.drawFill(in: rect) }
        style.drawCard(card.offsetBy(dx: m, dy: m), edge: edge)
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
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Drag annotated screenshot to another app")
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
        guard !Glass.available else { layer?.borderWidth = 0; return } // the glass pane is the background
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

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
    static let edit = Self("edit"), redaction = Self("redaction")
    static let background = Self("background"), insert = Self("insert"), crop = Self("crop")
}

final class AnnotateWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    private static var open: [AnnotateWindow] = []
    private static let palette: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Black", .black), ("White", .white),
    ]
    private static let strokes: [(String, CGFloat)] = [("Light", 3), ("Regular", 5), ("Medium", 8), ("Bold", 12), ("Heavy", 18), ("Black", 26)]
    /// Pull-down whose first item is the button face; AppKit never lists that item in the menu.
    private static func pullDown(_ image: NSImage?, _ label: String) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .toolbar
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: ""); face.image = image; button.menu?.addItem(face)
        button.imagePosition = .imageOnly
        button.toolTip = label; button.setAccessibilityLabel(label)
        return button
    }
    private static func symbol(_ name: String, _ label: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: label) }
    /// Menu preview of a stroke: a rounded bar at that weight.
    private static func strokeImage(_ width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 18), flipped: false) { r in
            NSColor.black.setFill()
            let h = min(16, 1 + width * 0.6); NSBezierPath(roundedRect: NSRect(x: 2, y: (r.height - h) / 2, width: 30, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            return true
        }
        image.isTemplate = true; return image
    }

    private(set) var canvas: Canvas! // read by the e2e driver
    private var backdrop: Backdrop!
    private let inspector = BackgroundInspector()
    private var sidebar: NSSplitViewItem!
    private var source: URL!
    private var scroll: NSScrollView!
    private var zoom: NSPopUpButton!
    private var toolsItem: NSSegmentedControl?
    private var colorItem: NSPopUpButton?
    private var strokeItem: NSPopUpButton?
    private var strokeSlider: NSSlider?
    private var redactPicker: NSPopUpButton?
    private var redactSlider: NSSlider?
    /// Stroke and redaction controls swap places with the tool (macOS 15+ can hide toolbar items).
    private var contextualItems: (stroke: NSToolbarItem?, redaction: NSToolbarItem?)
    private var backgroundItem: NSToolbarItem?

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
        let screen = NSScreen.underPointer?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(max(1140, image.size.width + 120), screen.width * 0.9),
                          height: min(max(420, image.size.height + 120 + 48), screen.height * 0.85 - 52))
        let w = AnnotateWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none // a line at titlebar height cut through the taller unified toolbar
        w.source = url
        w.isReleasedWhenClosed = false
        w.delegate = w
        w.animationBehavior = .documentWindow
        w.minSize = NSSize(width: min(1040, screen.width * 0.9), height: 360)
        w.build(image: image)
        if let project {
            w.canvas.setFrameSize(project.canvasSize); w.canvas.marks = project.marks
            if let background = project.background { w.inspector.style = background }
            w.resizeDocument()
        }
        w.centerOnPointerScreen()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.canvas)
        w.updateInsets()
        w.fit(animated: false)
        open.append(w)
        return w
    }

    private func build(image: NSImage) {
        canvas = Canvas(image: image)
        canvas.restoreChoices()
        canvas.onToolChange = { [weak self] t in
            self?.toolsItem?.selectedSegment = Tool.grouped.firstIndex(of: t) ?? -1
            self?.refreshStroke(); self?.updateContextualItems()
        }
        canvas.onImageChange = { [weak self] in self?.resizeDocument() }
        canvas.onKey = { [weak self] shortcut in self?.run(shortcut) }
        backdrop = Backdrop(canvas: canvas)

        // Preview-style under-page material so the screenshot reads as the document.
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentLayoutRect.size))
        content.material = .underPageBackground
        content.blendingMode = .withinWindow
        // With Liquid Glass the screenshot scrolls under the floating toolbar and floating bottom controls.
        let barHeight: CGFloat = Glass.available ? 0 : 52
        scroll = NSScrollView(frame: NSRect(x: 0, y: barHeight, width: content.bounds.width, height: content.bounds.height - barHeight))
        scroll.contentView = CenteringClipView()
        scroll.documentView = backdrop
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        if Glass.available { floatingControls(in: content) } else { content.addSubview(bottomBar(width: content.bounds.width, height: 52)) }

        // Background inspector as a native sidebar: Liquid Glass on macOS 26+, collapses with animation.
        inspector.onChange = { [weak self] style in self?.backdrop.style = style; self?.fit(animated: false) }
        let editor = NSViewController(); editor.view = content
        let split = NSSplitViewController()
        sidebar = NSSplitViewItem(sidebarWithViewController: inspector)
        sidebar.minimumThickness = 268; sidebar.maximumThickness = 268
        sidebar.canCollapse = true; sidebar.isCollapsed = true
        let main = NSSplitViewItem(viewController: editor)
        sidebar.titlebarSeparatorStyle = .none; main.titlebarSeparatorStyle = .none
        // macOS 26: the sidebar floats as inset Liquid Glass over the canvas, like System Settings.
        if #available(macOS 26, *) { main.automaticallyAdjustsSafeAreaInsets = true }
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(main)
        let frame = self.frame
        contentViewController = split
        setFrame(frame, display: false)

        let toolbar = NSToolbar(identifier: "annotate")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbarStyle = .unified
        self.toolbar = toolbar
    }

    /// Keeps the document clear of the toolbar and the floating bottom controls.
    private func updateInsets() {
        // The floating sidebar covers the left of the editor; its width arrives as a safe-area inset.
        let left = sidebar.isCollapsed ? 0 : scroll.superview?.safeAreaInsets.left ?? 0
        scroll.contentInsets = NSEdgeInsets(top: frame.height - contentLayoutRect.height, left: left, bottom: Glass.available ? 64 : 0, right: 0)
        zoom.frame.origin.x = 16 + left
    }

    /// Bottom controls as separate glass capsules floating over the canvas.
    private func floatingControls(in content: NSView) {
        let width = content.bounds.width, y: CGFloat = 14
        zoom = zoomButton(frame: NSRect(x: 16, y: y, width: 78, height: 34))
        Glass.style(zoom)
        zoom.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(zoom)

        let handle = DragHandle(frame: NSRect(x: (width - 170) / 2, y: y, width: 170, height: 34))
        handle.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        handle.file = { [weak self] in self?.tempPNG() }
        content.addSubview(Glass.pane(handle, radius: 17, interactive: true))

        for (i, button) in actionButtons().reversed().enumerated() {
            button.frame = NSRect(x: width - 16 - CGFloat(i + 1) * 40 - CGFloat(i) * 8, y: y, width: 40, height: 34)
            Glass.style(button, circle: true)
            button.autoresizingMask = [.minXMargin, .maxYMargin]
            content.addSubview(button)
        }
    }

    private func zoomButton(frame: NSRect) -> NSPopUpButton {
        let zoom = NSPopUpButton(frame: frame, pullsDown: true)
        zoom.addItem(withTitle: "100%")
        for (title, level) in [("Zoom to Fit", 0.0), ("50%", 0.5), ("100%", 1), ("200%", 2), ("400%", 4)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "") // addItem(withTitle:) dedupes "100%"
            item.tag = Int(level * 100)
            zoom.menu?.addItem(item)
        }
        zoom.target = self
        zoom.action = #selector(pickZoom(_:))
        return zoom
    }

    private func actionButtons() -> [NSButton] {
        let actions: [(String, String, (AnnotateWindow, NSButton) -> Void)] = [
            ("square.and.arrow.up", "Share", { w, b in
                guard let url = w.tempPNG() else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
            }),
            ("pin", "Pin to Screen (⇧⌘P)", { w, _ in PinWindow.pin(w.output()) }),
            ("doc.on.doc", "Copy Screenshot (⇧⌘C)", { w, _ in w.copyImage() }),
        ]
        return actions.map { symbol, tip, run in
            let b = ClosureButton(frame: .zero) {}
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.setHandler { [weak self, weak b] in if let self, let b { run(self, b) } }
            return b
        }
    }

    /// Editor shortcuts from `EditorShortcut`; plain keys arrive from the canvas, ⌘ keys from performKeyEquivalent.
    private func run(_ shortcut: EditorShortcut) {
        switch shortcut {
        case .copyObject: if !canvas.copySelection() { copyImage() }
        case .duplicate: if !canvas.duplicateSelection() { NSSound.beep() }
        case .save: done()
        case .saveAs: saveAs()
        case .copyScreenshot: copyImage()
        case .print: printImage()
        case .pin: PinWindow.pin(output())
        case .addScreenshot:
            RegionSelector.choose { [weak self] _, image in
                guard let self, let image else { return }
                self.makeKeyAndOrderFront(nil); self.canvas.insertImage(image)
            }
        case .addFromFile: insertImage()
        case .background: toggleBackground()
        case .undo: canvas.undo()
        case .redo: canvas.redo()
        case .paste: if !canvas.pasteMark(), let image = NSImage(pasteboard: Clipboard.pasteboard) { canvas.insertImage(image) }
        case .close: performClose(nil)
        case .zoomIn: setZoom(scroll.magnification * 1.25)
        case .zoomOut: setZoom(scroll.magnification / 1.25)
        case .actualSize: setZoom(1)
        case .increaseSize, .decreaseSize:
            let step: CGFloat = shortcut == .increaseSize ? 2 : -2
            if canvas.tool == .pixelate { canvas.redactAmount = min(40, max(4, canvas.redactAmount + step)) }
            else { canvas.width = min(40, max(2, canvas.width + step)) }
            refreshStroke()
        }
    }

    private func printImage() {
        let view = NSImageView(image: output())
        view.frame = NSRect(origin: .zero, size: view.image?.size ?? .zero)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        NSPrintOperation(view: view, printInfo: info).runModal(for: self, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func bottomBar(width: CGFloat, height: CGFloat) -> NSView {
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.autoresizingMask = [.width, .maxYMargin]
        let line = NSBox(frame: NSRect(x: 0, y: height - 1, width: width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .minYMargin]
        bar.addSubview(line)

        zoom = zoomButton(frame: NSRect(x: 12, y: 11, width: 96, height: 30))
        bar.addSubview(zoom)

        let handle = DragHandle(frame: NSRect(x: (width - 190) / 2, y: 9, width: 190, height: 34))
        handle.autoresizingMask = [.minXMargin, .maxXMargin]
        handle.file = { [weak self] in self?.tempPNG() }
        bar.addSubview(handle)

        for (i, b) in actionButtons().reversed().enumerated() {
            b.frame = NSRect(x: width - 12 - CGFloat(i + 1) * 48, y: 10, width: 42, height: 32)
            b.bezelStyle = .recessed
            b.showsBorderOnlyWhileMouseInside = true
            b.autoresizingMask = [.minXMargin]
            bar.addSubview(b)
        }
        return bar
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.crop, .insert, .background, .sidebarTrackingSeparator, .tools, .color, .stroke, .redaction, .edit, .flexibleSpace, .saveAs, .done]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .crop, .insert, .background:
            let (symbol, label, action): (String, String, Selector) = id == .crop ? ("crop", "Crop (K)", #selector(cropTool))
                : id == .insert ? ("photo.badge.plus", "Add Screenshot From File (⌘I)", #selector(insertImage)) : ("photo.on.rectangle.angled", "Background (B)", #selector(toggleBackground))
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label; item.toolTip = label
            item.target = self; item.action = action; item.isBordered = true
            if id == .background { backgroundItem = item }
            return item
        case .tools:
            // One compact segmented control: the toolbar wraps it in a single glass capsule.
            let control = NSSegmentedControl(images: Tool.grouped.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage(systemSymbolName: "square", accessibilityDescription: $0.label)! },
                                             trackingMode: .selectOne, target: self, action: #selector(pickTool))
            control.segmentStyle = .separated
            for (index, t) in Tool.grouped.enumerated() {
                control.setWidth(26, forSegment: index)
                control.setToolTip("\(t.label) (\(t.key.uppercased()))", forSegment: index)
            }
            control.selectedSegment = Tool.grouped.firstIndex(of: canvas.tool) ?? -1
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control; item.label = "Tools"
            toolsItem = control
            return item
        case .color:
            let button = Self.pullDown(Self.dot(canvas.color, 18), "Color")
            for (name, c) in Self.palette {
                let m = NSMenuItem(title: name, action: #selector(pickColor(_:)), keyEquivalent: "")
                m.target = self; m.image = Self.dot(c, 14); m.representedObject = c
                button.menu?.addItem(m)
            }
            button.menu?.addItem(.separator())
            let custom = NSMenuItem(title: "Custom Color / Eyedropper…", action: #selector(customColor), keyEquivalent: "")
            custom.target = self; custom.image = Self.symbol("eyedropper", "Custom Color"); button.menu?.addItem(custom)
            colorItem = button
            refreshColor()
            return toolbarItem(id, button, "Color")
        case .edit:
            let button = Self.pullDown(Self.symbol("slider.horizontal.3", "Image & Styles"), "Image & Styles")
            let entries: [(String, String, Selector)] = [("Undo", "arrow.uturn.backward", #selector(undoEdit)), ("Redo", "arrow.uturn.forward", #selector(redoEdit)), ("", "", #selector(undoEdit)),
                ("Rotate Left", "rotate.left", #selector(rotateLeft)), ("Rotate Right", "rotate.right", #selector(rotateRight)),
                ("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", #selector(flipHorizontal)),
                ("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", #selector(flipVertical)),
                ("Resize…", "arrow.up.left.and.arrow.down.right", #selector(resizeImage)), ("", "", #selector(undoEdit)),
                ("Background…", "photo.on.rectangle.angled", #selector(toggleBackground)), ("Insert Image…", "photo.badge.plus", #selector(insertImage)),
                ("Save Editable Project…", "doc.badge.gearshape", #selector(saveProject)), ("", "", #selector(undoEdit))]
            for (title, symbol, action) in entries {
                if title.isEmpty { button.menu?.addItem(.separator()); continue }
                let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; m.image = Self.symbol(symbol, title); button.menu?.addItem(m)
            }
            func submenu(_ title: String, _ symbol: String, _ names: [String], _ action: Selector) {
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let sub = NSMenu()
                for (i, name) in names.enumerated() { let m = NSMenuItem(title: name, action: action, keyEquivalent: ""); m.tag = i; m.target = self; sub.addItem(m) }
                parent.image = Self.symbol(symbol, title); parent.submenu = sub; button.menu?.addItem(parent)
            }
            submenu("Arrow Style", "arrow.up.right", ["Filled", "Curved", "Double Headed", "Outline"], #selector(arrowStyle(_:)))
            submenu("Text Style", "textformat", ["Outlined", "Bold", "Monospace", "Regular", "White Label", "Black Label", "Color Label"], #selector(textStyle(_:)))
            submenu("Crop Aspect Ratio", "aspectratio", ["Freeform", "Square", "16:9", "4:3", "9:16"], #selector(cropAspect(_:)))
            return toolbarItem(id, button, "Image & Styles")
        case .stroke:
            let button = Self.pullDown(Self.symbol("lineweight", "Stroke"), "Stroke")
            for (name, w) in Self.strokes {
                let m = NSMenuItem(title: "\(name) · \(Int(w)) pt", action: #selector(pickStroke(_:)), keyEquivalent: "")
                m.image = Self.strokeImage(w); m.target = self; m.tag = Int(w)
                button.menu?.addItem(m)
            }
            button.menu?.addItem(.separator())
            // Free width between presets, live while dragging.
            let slider = NSSlider(value: canvas.width, minValue: 2, maxValue: 40, target: self, action: #selector(slideStroke(_:)))
            slider.frame = NSRect(x: 18, y: 4, width: 190, height: 24)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 226, height: 32)); host.addSubview(slider)
            let sliderItem = NSMenuItem(); sliderItem.view = host; button.menu?.addItem(sliderItem)
            strokeItem = button; strokeSlider = slider
            refreshStroke()
            let item = toolbarItem(id, button, "Stroke"); contextualItems.stroke = item; updateContextualItems()
            return item
        case .redaction:
            let picker = Self.pullDown(nil, "Redaction Style")
            for (i, (title, symbol, _)) in Tool.redactions.enumerated() {
                let m = NSMenuItem(title: title, action: #selector(pickRedaction(_:)), keyEquivalent: ""); m.tag = i; m.target = self
                m.image = Self.symbol(symbol, title); picker.menu?.addItem(m)
            }
            let slider = NSSlider(value: canvas.redactAmount, minValue: 4, maxValue: 40, target: self, action: #selector(slideRedaction(_:)))
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [picker, slider]); stack.spacing = 8
            redactPicker = picker; redactSlider = slider
            refreshStroke()
            let item = toolbarItem(id, stack, "Redaction"); contextualItems.redaction = item; updateContextualItems()
            return item
        case .saveAs, .done:
            let isDone = id == .done
            if #available(macOS 26, *) { // system glass text buttons; Done gets the prominent accent capsule
                let item = NSToolbarItem(itemIdentifier: id)
                item.title = isDone ? "Done" : "Save as…"
                item.label = item.title
                item.target = self
                item.action = isDone ? #selector(doneAction) : #selector(saveAsAction)
                item.isBordered = true
                if isDone { item.style = .prominent; item.backgroundTintColor = .controlAccentColor }
                item.visibilityPriority = isDone ? .high : .low
                return item
            }
            let b = ClosureButton(frame: .zero) { [weak self] in isDone ? self?.done() : self?.saveAs() }
            b.title = isDone ? "Done" : "Save as…"
            b.bezelStyle = .push
            b.controlSize = .large
            if isDone { b.keyEquivalent = "\r" } // default button → accent fill
            let item = NSToolbarItem(itemIdentifier: id)
            item.visibilityPriority = isDone ? .high : .low // Done never overflows behind the chevron
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

    private func toolbarItem(_ id: NSToolbarItem.Identifier, _ view: NSView, _ label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id); item.view = view; item.label = label; return item
    }

    private func updateContextualItems() {
        guard #available(macOS 15, *) else { return }
        contextualItems.stroke?.isHidden = canvas.tool == .pixelate
        contextualItems.redaction?.isHidden = canvas.tool != .pixelate
    }

    @objc private func pickTool(_ sender: Any) {
        if let i = toolsItem?.selectedSegment, Tool.grouped.indices.contains(i) { canvas.tool = Tool.grouped[i] }
        makeFirstResponder(canvas)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? NSColor { canvas.color = c }
        refreshColor()
    }

    private func refreshColor() {
        colorItem?.item(at: 0)?.image = Self.dot(canvas.color, 18)
        colorItem?.menu?.items.forEach { $0.state = ($0.representedObject as? NSColor) == canvas.color ? .on : .off }
    }

    @objc private func pickStroke(_ sender: NSMenuItem) {
        canvas.width = CGFloat(sender.tag); refreshStroke()
    }
    @objc private func slideStroke(_ sender: NSSlider) { canvas.width = sender.doubleValue.rounded(); refreshStroke() }
    @objc private func pickRedaction(_ sender: NSMenuItem) { canvas.redactStyle = sender.tag; canvas.tool = .pixelate; refreshStroke() }
    @objc private func slideRedaction(_ sender: NSSlider) { canvas.redactAmount = sender.doubleValue.rounded() }

    /// Syncs stroke and redaction controls with the canvas.
    private func refreshStroke() {
        strokeItem?.menu?.items.dropFirst().forEach { $0.state = $0.tag > 0 && CGFloat($0.tag) == canvas.width ? .on : .off }
        strokeSlider?.doubleValue = canvas.width
        let (title, symbol, meaning) = Tool.redactions[canvas.redactStyle]
        redactPicker?.item(at: 0)?.image = Self.symbol(symbol, title)
        redactPicker?.menu?.items.dropFirst().forEach { $0.state = $0.tag == canvas.redactStyle ? .on : .off }
        redactSlider?.doubleValue = canvas.redactAmount
        redactSlider?.isEnabled = !meaning.isEmpty; redactSlider?.toolTip = meaning
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
        guard canvas != nil, let backdrop else { return }
        backdrop.relayout(); fit(animated: isVisible)
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
            do { try ShotProject(canvas: self.canvas, background: self.backdrop.style).write(url) } catch { NSAlert(error: error).runModal() }
        }
    }
    @objc private func toggleBackground() {
        let open = sidebar.isCollapsed
        if open, inspector.style == nil { inspector.style = BackgroundInspector.lastUsed ?? ShotBackground() }
        Anim.run(0.3, { sidebar.animator().isCollapsed = !open }) { [weak self] in self?.updateInsets(); self?.fit() }
        if #available(macOS 26, *) { backgroundItem?.style = open ? .prominent : .plain }
    }
    @objc private func cropTool() { canvas.tool = .crop; makeFirstResponder(canvas) }
    @objc private func doneAction() { done() }
    @objc private func saveAsAction() { saveAs() }

    /// The annotated screenshot with its background, as exported, copied, pinned and dragged.
    private func output() -> NSImage {
        let flat = canvas.export()
        return backdrop.style.map { $0.apply(to: flat) } ?? flat
    }

    // MARK: Zoom

    private func fit(animated: Bool = true) {
        guard let doc = scroll.documentView else { return }
        let inset = scroll.contentInsets
        let clip = NSSize(width: scroll.contentSize.width - inset.left - inset.right, height: scroll.contentSize.height - inset.top - inset.bottom)
        setZoom(min(1, clip.width / doc.frame.width, clip.height / doc.frame.height), animated: animated)
    }

    private func setZoom(_ level: CGFloat, animated: Bool = true) {
        let level = min(scroll.maxMagnification, max(scroll.minMagnification, level))
        if animated { Anim.run(0.25) { scroll.animator().magnification = level } } else { scroll.magnification = level }
        showZoom(level)
    }

    @objc private func zoomChanged() { showZoom(scroll.magnification) }
    private func showZoom(_ level: CGFloat) {
        zoom.itemArray.first?.title = "\(Int((level * 100).rounded()))%"
        canvas.chromeScale = 1 / level
    }

    @objc private func pickZoom(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 100
        tag == 0 ? fit() : setZoom(CGFloat(tag) / 100)
    }

    // MARK: Output

    private func tempPNG() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".png")
        guard let png = ImageTools.png(output()), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    private func copyImage() {
        Clipboard.copy(output())
        Toast.show("Copied", symbol: "checkmark.circle.fill")
    }

    /// Writes over the capture, copies it, and closes, like CleanShot's Done.
    private func done() {
        if source.pathExtension.lowercased() == "leanshot" {
            do { try ShotProject(canvas: canvas, background: backdrop.style).write(source); isDocumentEdited = false; close() } catch { NSAlert(error: error).runModal() }; return
        }
        let image = output(), width = image.size.width
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let destination = source.deletingLastPathComponent().standardizedFileURL == Capture.folder.standardizedFileURL && source.pathExtension.lowercased() == "png" ? source! : Capture.newURL("png")
        let replacing = destination == source
        // The window leaves at once; it only closes after the PNG is safely on disk, and comes back if writing fails.
        orderOut(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let png = ImageTools.png(cg, pointWidth: width)
            let result = Result { () -> Void in
                guard let png else { throw CocoaError(.fileWriteUnknown) }
                // Done replaces the capture in place; the unannotated original goes to the Trash, so a wrong redaction stays recoverable.
                if replacing { try? FileManager.default.trashItem(at: destination, resultingItemURL: nil) }
                try png.write(to: destination, options: .atomic)
            }
            DispatchQueue.main.async {
                if case .failure(let error) = result { self.makeKeyAndOrderFront(nil); NSAlert(error: error).beginSheetModal(for: self); return }
                Clipboard.copy(image, png: png)
                QuickAccess.show(destination)
                self.isDocumentEdited = false
                self.close()
            }
        }
    }

    private func saveAs() {
        // PNG keeps every pixel; JPEG and HEIC fit email and chat upload limits. The last choice sticks.
        let formats: [(String, UTType)] = [("PNG", .png), ("JPEG", .jpeg), ("HEIC", .heic)]
        let panel = NSSavePanel()
        var format = formats.indices.contains(Settings.exportFormat) ? Settings.exportFormat : 0
        let name = source.deletingPathExtension().lastPathComponent + " (annotated)"
        panel.allowedContentTypes = [formats[format].1]
        panel.nameFieldStringValue = name + "." + (formats[format].1.preferredFilenameExtension ?? "png")
        panel.directoryURL = source.deletingLastPathComponent()
        let picker = ClosurePopup(choices: formats.map(\.0), selected: format) { [weak panel] index in
            format = index; panel?.allowedContentTypes = [formats[index].1]
        }
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), picker]); accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Settings.exportFormat = format
            let image = self.output()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = ImageTools.encode(cg, pointWidth: image.size.width, as: formats[format].1) else { return NSSound.beep() }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    /// No main menu in an accessory app, so the window routes shortcuts itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editingText = firstResponder is NSTextView
        if editingText, event.charactersIgnoringModifiers == "\r" { return false } // Return commits text, not Done
        if !editingText, event.keyCode == 36, event.modifierFlags.intersection([.command, .control, .option]).isEmpty { done(); return true }
        if editingText, event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers {
            let edits: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                             "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                                             "z": Selector(("undo:"))]
            if let action = edits[key] { return NSApp.sendAction(action, to: nil, from: self) }
        }
        guard event.modifierFlags.contains(.command), let shortcut = EditorShortcut.matching(event),
              !editingText || [.save, .close].contains(shortcut) else { return super.performKeyEquivalent(with: event) }
        run(shortcut)
        return true
    }

    /// Unsaved annotations get a sheet instead of vanishing on ⌘W, the close button or Quit.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDocumentEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your annotations?"
        alert.informativeText = "Done saves and copies the annotated screenshot. Discard closes without saving."
        alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.done() }
            else if response == .alertSecondButtonReturn { self.isDocumentEdited = false; self.close() }
        }
        return false
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
        w.canvas.selected = 1
        if CommandLine.arguments.contains("--background") { w.toggleBackground() }
        // Real window capture, so Liquid Glass and the sidebar material render as on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(w.windowNumber)", output.path]
            try? task.run(); task.waitUntilExit()
            // screencapture fails while the screen is locked; fall back to the view's own rendering.
            if !FileManager.default.fileExists(atPath: output.path), let view = w.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: output)
            }
            print("wrote \(output.path)")
            exit(0)
        }
    }
}

