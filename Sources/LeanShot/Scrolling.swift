import AppKit
import ScreenCaptureKit

enum Stitcher {
    /// Matches the bottom/right of the last frame with the top/left of the next.
    /// A nil result deliberately leaves the original frames untouched.
    static func overlap(_ previous: NSImage, _ next: NSImage, horizontal: Bool) -> CGFloat? {
        guard previous.size == next.size else { return nil }
        let length = horizontal ? previous.size.width : previous.size.height
        let steps = min(512, max(32, Int(length)))
        let cross = 32
        func samples(_ image: NSImage) -> [Double] {
            let size = horizontal ? NSSize(width: steps, height: cross) : NSSize(width: cross, height: steps)
            let sample = ImageTools.resize(image, pixels: size)
            let rep = sample.representations[0] as! NSBitmapImageRep
            return (0..<steps).flatMap { i in (0..<cross).map { j in
                let c = rep.colorAt(x: horizontal ? i : j, y: horizontal ? j : i)!.usingColorSpace(.sRGB)!
                return Double(c.redComponent * 0.3 + c.greenComponent * 0.59 + c.blueComponent * 0.11)
            } }
        }
        let a = samples(previous), b = samples(next)
        let unchanged = zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
        if unchanged < 0.002 { return length }
        var best = Double.greatestFiniteMagnitude, bestCount = 0
        for overlap in max(8, steps / 10)..<steps - 2 {
            var diff = 0.0, count = 0
            // Sample throughout the overlapping region, skipping moving outer edges.
            for row in stride(from: 2, to: overlap - 2, by: max(1, overlap / 24)) {
                for column in 3..<cross - 3 {
                    diff += abs(a[(steps - overlap + row) * cross + column] - b[row * cross + column]); count += 1
                }
            }
            let error = diff / Double(max(1, count))
            if error < best { best = error; bestCount = overlap }
        }
        guard best < 0.035, bestCount > 0 else { return nil }
        return CGFloat(bestCount) / CGFloat(steps) * length
    }

    static func append(_ next: NSImage, to result: NSImage, overlap: CGFloat, horizontal: Bool) -> NSImage {
        let added = max(0, (horizontal ? next.size.width : next.size.height) - overlap)
        guard added > 0 else { return result }
        let size = NSSize(width: result.size.width + (horizontal ? added : 0), height: result.size.height + (horizontal ? 0 : added))
        let scale = ImageTools.pixelSize(result).width / result.size.width
        return ImageTools.render(size: size, pixels: NSSize(width: size.width * scale, height: size.height * scale)) { _ in
            if horizontal {
                result.draw(in: NSRect(origin: .zero, size: result.size))
                next.draw(in: NSRect(x: result.size.width - overlap, y: 0, width: next.size.width, height: next.size.height))
            } else {
                result.draw(in: NSRect(x: 0, y: added, width: result.size.width, height: result.size.height))
                next.draw(in: NSRect(origin: .zero, size: next.size))
            }
        }
    }
}

final class ScrollingSession {
    private static var current: ScrollingSession?
    static var active: Bool { current != nil }
    private let region: ScreenRegion
    private var previous: NSImage
    private var result: NSImage
    private let horizontal: Bool
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "1 frame · Scroll, pause, then Add Frame")
    private var busy = false
    private var frames = 1
    private init(region: ScreenRegion, image: NSImage, horizontal: Bool) {
        self.region = region; self.previous = image; self.result = image; self.horizontal = horizontal
        let f = region.screen.visibleFrame
        panel = NSPanel(contentRect: NSRect(x: f.midX - 240, y: f.minY + 24, width: 480, height: 100), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = horizontal ? "Scrolling Capture — Horizontal" : "Scrolling Capture — Vertical"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        label.frame = NSRect(x: 16, y: 66, width: 448, height: 22); panel.contentView?.addSubview(label)
        let actions: [(String, () -> Void)] = [("Add Frame", { [weak self] in self?.addFrame() }), ("Finish", { [weak self] in self?.finish() }), ("Cancel", { [weak self] in self?.cancel() })]
        for (i, pair) in actions.enumerated() {
            let b = ClosureButton(frame: NSRect(x: 16 + i * 152, y: 16, width: 140, height: 32), action: pair.1)
            b.title = pair.0; b.bezelStyle = .rounded; panel.contentView?.addSubview(b)
        }
        panel.orderFrontRegardless()
    }
    static func start(horizontal: Bool) {
        guard current == nil else { NSSound.beep(); return }
        Toast.show("Select only the scrolling content, excluding fixed headers")
        RegionSelector.choose { region, image in
            guard let region, let image else { return }; QuickAccess.hide()
            current = ScrollingSession(region: region, image: image, horizontal: horizontal)
        }
    }
    private func addFrame() {
        guard !busy else { return }; busy = true; panel.orderOut(nil)
        Task { @MainActor in
            do {
                // Allow WindowServer to remove the controls before capturing the region.
                try await Task.sleep(nanoseconds: 200_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { throw CocoaError(.featureUnsupported) }
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: region.rect.minX, y: region.screen.frame.height - region.rect.maxY, width: region.rect.width, height: region.rect.height)
                config.width = Int(region.rect.width * region.screen.backingScaleFactor); config.height = Int(region.rect.height * region.screen.backingScaleFactor); config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let next = NSImage(cgImage: cg, size: region.rect.size)
                if let overlap = Stitcher.overlap(previous, next, horizontal: horizontal) {
                    let length = horizontal ? next.size.width : next.size.height
                    if overlap >= length - 1 { label.stringValue = "No scroll detected · Scroll further and try again" }
                    else {
                        let candidate = Stitcher.append(next, to: result, overlap: overlap, horizontal: horizontal)
                        let pixels = ImageTools.pixelSize(candidate)
                        guard pixels.width * pixels.height <= 100_000_000 else { throw NSError(domain: "LeanShot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Capture reached 100 megapixels. Finish this capture before starting another."]) }
                        result = candidate; previous = next; frames += 1; label.stringValue = "\(frames) frames · \(Int(pixels.width)) × \(Int(pixels.height)) px"
                    }
                } else { label.stringValue = "No overlap found · Scroll back a little and retry" }
            } catch { NSAlert(error: error).runModal() }
            busy = false; panel.orderFrontRegardless()
        }
    }
    private func finish() {
        guard !busy, let data = ImageTools.png(result) else { return }
        let url = Capture.newURL("png")
        do { try data.write(to: url, options: .atomic); cancel(); if Settings.copyOnCapture { Clipboard.copy(url) }; QuickAccess.show(url) }
        catch { NSAlert(error: error).runModal() }
    }
    private func cancel() { guard !busy else { return }; panel.orderOut(nil); Self.current = nil; QuickAccess.restore() }
}
