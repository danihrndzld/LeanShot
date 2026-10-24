import AppKit

/// `LeanShot --bench`: times the hot paths on a Retina-sized capture so performance changes are measured, not guessed.
enum Bench {
    static func run() {
        _ = NSApplication.shared
        let size = NSSize(width: 1512, height: 982), pixels = NSSize(width: 3024, height: 1964)
        let shot = ImageTools.render(size: size, pixels: pixels) { r in
            NSGradient(colors: [.systemIndigo, .systemTeal])!.draw(in: r, angle: 30)
            for row in 0..<40 {
                ("LeanShot benchmark row \(row) · The quick brown fox jumps over the lazy dog" as NSString)
                    .draw(at: NSPoint(x: 20, y: CGFloat(row) * 24), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("leanshot-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shot.png")

        time("PNG encode 3024×1964", 5) { try? ImageTools.png(shot)?.write(to: file) }
        time("Thumbnail 88×56, uncached", 1) { _ = ImageTools.render(size: NSSize(width: 88, height: 56), pixels: NSSize(width: 176, height: 112)) { Thumbnail.image(file, maxPixels: 176)?.draw(in: $0) } }

        let canvas = Canvas(image: NSImage(contentsOf: file)!)
        canvas.marks = (0..<30).map { i in
            let p = CGPoint(x: 40 + CGFloat(i % 10) * 140, y: 60 + CGFloat(i / 10) * 260)
            let tool: Tool = [.rect, .arrow, .ellipse, .pen, .counter, .highlight][i % 6]
            return Mark(tool: tool, points: tool == .counter ? [p] : [p, CGPoint(x: p.x + 110, y: p.y + 90)], color: .systemRed, width: 5)
        } + (0..<4).map { Mark(tool: .pixelate, points: [CGPoint(x: 100 + CGFloat($0) * 300, y: 800), CGPoint(x: 300 + CGFloat($0) * 300, y: 900)], color: .red, width: 14, style: $0) }
        ImageTools.warmUp(); Thread.sleep(forTimeInterval: 1) // as at launch
        time("Canvas frame, 34 marks (cold effects)", 1) { frame(canvas, size) }
        time("Canvas frame, 34 marks (warm)", 20) { frame(canvas, size) }
        time("Drag frame, 300×200 pt dirty rect", 20) { frame(canvas, size, dirty: CGRect(x: 400, y: 300, width: 300, height: 200)) }
        let empty = Canvas(image: canvas.image)
        time("Canvas frame, image only", 20) { frame(empty, size) }
        var amount: CGFloat = 8
        time("Redaction slider step (new amount)", 10) {
            amount += 1; canvas.marks[30...33].indices.forEach { canvas.marks[$0].width = amount }; frame(canvas, size)
        }
        time("Hit test ×1000 (hover)", 5) { for i in 0..<1000 { _ = canvas.mark(at: CGPoint(x: CGFloat(i % 1500), y: CGFloat(i % 980))) } }
        time("Export at full resolution", 5) { _ = canvas.export() }

        var style = ShotBackground(); style.palette = 3
        time("Background apply (gradient + shadow)", 5) { _ = style.apply(to: shot) }
        time("Quick Access card init", 5) { _ = OverlayCard(url: file, screen: NSScreen.main) }
        exit(0)
    }

    /// One redraw of the editor canvas at 2x, the work AppKit does per drag event.
    private static func frame(_ canvas: Canvas, _ size: NSSize, dirty: CGRect? = nil) {
        _ = ImageTools.render(size: size, pixels: NSSize(width: size.width * 2, height: size.height * 2)) {
            if let dirty { NSBezierPath(rect: dirty).addClip() } // what AppKit does for setNeedsDisplay(rect)
            canvas.render(in: $0)
        }
    }

    private static func time(_ name: String, _ runs: Int, _ body: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            autoreleasepool { body() }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "%-40@ %8.2f ms  (median of %d)", name as NSString, median, runs))
    }
}
