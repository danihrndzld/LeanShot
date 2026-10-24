import AppKit
import ScreenCaptureKit
import ApplicationServices

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

/// Titled non-activating panel that still takes keys, so the page being captured keeps focus for scrolling.
private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class ScrollingSession {
    private static var current: ScrollingSession?
    static var active: Bool { current != nil }
    private let region: ScreenRegion
    private var previous: NSImage
    private var result: NSImage
    private let horizontal: Bool
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "1 frame · Scroll, pause, then Add Frame")
    private var busy = false { didSet { buttons.forEach { $0.isEnabled = !busy } } } // greyed while a frame is stitched
    private var buttons: [NSButton] = []
    private var frames = 1
    private var autoTimer: Timer?
    private var unchangedFrames = 0
    private init(region: ScreenRegion, image: NSImage, horizontal: Bool) {
        self.region = region; self.previous = image; self.result = image; self.horizontal = horizontal
        let f = region.screen.visibleFrame
        panel = KeyPanel(contentRect: NSRect(x: f.midX - 316, y: f.minY + 24, width: 632, height: 100), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = horizontal ? "Scrolling Capture — Horizontal" : "Scrolling Capture — Vertical"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        label.frame = NSRect(x: 16, y: 66, width: 600, height: 22); panel.contentView?.addSubview(label)
        // Keyboard rhythm for long pages: Return adds a frame, A toggles auto, ⌘Return finishes, Esc cancels.
        let actions: [(String, String, NSEvent.ModifierFlags, () -> Void)] = [("Add Frame ↩", "\r", [], { [weak self] in self?.addFrame() }), ("Auto / Stop (A)", "a", [], { [weak self] in self?.toggleAuto() }),
                                                                            ("Finish ⌘↩", "\r", .command, { [weak self] in self?.finish() }), ("Cancel (Esc)", "\u{1b}", [], { [weak self] in self?.cancel() })]
        for (i, action) in actions.enumerated() {
            let b = ClosureButton(frame: NSRect(x: 16 + i * 152, y: 16, width: 140, height: 32), action: action.3)
            b.title = action.0; b.bezelStyle = .rounded; b.keyEquivalent = action.1; b.keyEquivalentModifierMask = action.2
            panel.contentView?.addSubview(b); buttons.append(b)
        }
        panel.makeKeyAndOrderFront(nil)
    }
    private func toggleAuto() {
        if autoTimer != nil { stopAuto(); label.stringValue = "Automatic scrolling stopped"; return }
        guard AXIsProcessTrusted() else { return Toast.show("Enable Accessibility for automatic scrolling, or use Add Frame") }
        unchangedFrames = 0; label.stringValue = "Auto scrolling… Click Auto / Stop to pause"
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            let amount = Int32((self.horizontal ? self.region.rect.width : self.region.rect.height) * 0.45)
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: self.horizontal ? 0 : -amount, wheel2: self.horizontal ? -amount : 0, wheel3: 0)
            let rect = self.region.globalRect; event?.location = CGPoint(x: rect.midX, y: rect.midY); event?.post(tap: .cghidEventTap)
            self.addFrame(wait: 0.7)
        }
    }
    private func stopAuto() { autoTimer?.invalidate(); autoTimer = nil }
    static func start(horizontal: Bool) {
        guard current == nil else { NSSound.beep(); return }
        Toast.show("Select only the scrolling content, excluding fixed headers")
        RegionSelector.choose { region, image in
            guard let region, let image else { return }; QuickAccess.hide()
            current = ScrollingSession(region: region, image: image, horizontal: horizontal)
        }
    }
    private func addFrame(wait: Double = 0.2) {
        guard !busy else { return }; busy = true; panel.orderOut(nil)
        Task { @MainActor in
            do {
                // Allow WindowServer to remove the controls before capturing the region.
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
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
                    if overlap >= length - 1 {
                        unchangedFrames += 1
                        if autoTimer != nil, unchangedFrames >= 2 { stopAuto(); label.stringValue = "End of scroll reached · Finish to save" }
                        else { label.stringValue = "No scroll detected · Scroll further and try again" }
                    }
                    else {
                        unchangedFrames = 0
                        let scale = ImageTools.pixelSize(result).width / result.size.width
                        let width = result.size.width + (horizontal ? length - overlap : 0)
                        let height = result.size.height + (horizontal ? 0 : length - overlap)
                        guard width * height * scale * scale <= 100_000_000 else { throw NSError(domain: "LeanShot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Capture reached 100 megapixels. Finish this capture before starting another."]) }
                        let candidate = Stitcher.append(next, to: result, overlap: overlap, horizontal: horizontal)
                        let pixels = ImageTools.pixelSize(candidate)
                        result = candidate; previous = next; frames += 1; label.stringValue = "\(frames) frames · \(Int(pixels.width)) × \(Int(pixels.height)) px"
                    }
                } else { stopAuto(); label.stringValue = "No overlap found · Scroll back a little and retry" }
            } catch { stopAuto(); Permissions.explain(error) }
            busy = false; panel.makeKeyAndOrderFront(nil)
        }
    }
    private func finish() {
        guard !busy, let data = ImageTools.png(result) else { return }
        stopAuto()
        let url = Capture.newURL("png")
        do { try data.write(to: url, options: .atomic); cancel(); if Settings.copyOnCapture { Clipboard.copy(url) }; QuickAccess.show(url) }
        catch { NSAlert(error: error).runModal() }
    }
    private func cancel() { guard !busy else { return }; stopAuto(); panel.orderOut(nil); Self.current = nil; QuickAccess.resume() }
}
