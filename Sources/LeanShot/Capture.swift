import AppKit
import Vision

enum Capture {
    static var folder: URL {
        let url = Settings.saveFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newURL(_ ext: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return folder.appendingPathComponent("LeanShot \(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).\(ext)")
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// The running screencapture, so a video recording can be stopped (SIGINT finalizes the .mov).
    static var current: Process?

    /// Drives /usr/sbin/screencapture, which gives us the native crosshair, window picker and
    /// recording toolbar. Completion gets nil when the user cancels (Esc writes no file).
    /// Call on main. One capture at a time: beeps and returns false if one is already running.
    @discardableResult
    static func run(_ args: [String], to url: URL, completion: @escaping (URL?) -> Void) -> Bool {
        guard current == nil else { NSSound.beep(); return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x"] + args + [url.path]
        current = p
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run(); p.waitUntilExit() } catch { NSLog("LeanShot: \(error)") }
            let ok = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async { current = nil; completion(ok ? url : nil) }
        }
        return true
    }
}

enum Clipboard {
    static func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let image = NSImage(contentsOf: url) { pb.writeObjects([image]) } else { pb.writeObjects([url as NSURL]) }
    }

    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

enum OCR {
    static func recognize(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return completion("") }
        let request = VNRecognizeTextRequest { req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n")) }
        }
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        DispatchQueue.global(qos: .userInitiated).async {
            do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { DispatchQueue.main.async { completion("") } }
        }
    }
}

enum Toast {
    static func show(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 44)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let panel = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
        bg.addSubview(label)
        panel.contentView = bg
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { panel.orderOut(nil) }
    }
}
