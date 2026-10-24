import AppKit
import ScreenCaptureKit
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
    /// The general pasteboard, swapped for a private one by `--e2e` so tests never touch the user's clipboard.
    static var pasteboard: NSPasteboard = .general
    static func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL]); return }
        copy(image, png: url.pathExtension.lowercased() == "png" ? try? Data(contentsOf: url) : nil)
    }

    /// PNG for browsers and design tools (Figma, Notion, Linear), TIFF for older Cocoa apps. Pass `png` when it is already encoded.
    static func copy(_ image: NSImage, png: Data? = nil, to target: NSPasteboard? = nil) {
        let pasteboard = target ?? Self.pasteboard
        let item = NSPasteboardItem()
        // Encoded only when an app actually pastes, so Copy stays instant on a 6 MP capture.
        provider = LazyImage(image: image, png: png)
        item.setDataProvider(provider!, forTypes: [.png, .tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
    private static var provider: LazyImage? // the pasteboard holds providers weakly
    private final class LazyImage: NSObject, NSPasteboardItemDataProvider {
        let image: NSImage, png: Data?
        init(image: NSImage, png: Data?) { self.image = image; self.png = png }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if let data = type == .png ? png ?? ImageTools.png(image) : image.tiffRepresentation { item.setData(data, forType: type) }
        }
    }
}

enum OCR {
    static func textRects(_ image: NSImage, completion: @escaping ([CGRect]) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast; request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: cg).perform([request])
                let rects = (request.results ?? []).map(\.boundingBox)
                DispatchQueue.main.async { completion(rects) }
            } catch { DispatchQueue.main.async { completion([]) } }
        }
    }
    static func copyContents(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        recognize(image) { text in
            guard !text.isEmpty else { return Toast.show("No text or QR code found") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
        }
    }
    static func recognize(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return completion("") }
        let request = VNRecognizeTextRequest()
        let codes = VNDetectBarcodesRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cg).perform([request, codes])
                var lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                for value in (codes.results ?? []).compactMap(\.payloadStringValue) where !lines.contains(value) { lines.append(value) }
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async { completion(text) }
            } catch { DispatchQueue.main.async { completion("") } }
        }
    }
}

/// Shared motion vocabulary: one ease-out curve, and no motion when Reduce Motion is on.
enum Anim {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static func run(_ duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0 : duration
            context.timingFunction = easeOut
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }
    /// Stretchable rounded mask; layer corner radius does not clip NSVisualEffectView material.
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Liquid Glass on macOS 26+, the previous materials elsewhere.
enum Glass {
    static var available: Bool { if #available(macOS 26, *) { true } else { false } }
    static func style(_ button: NSButton, circle: Bool = false) {
        guard #available(macOS 26, *) else { return }
        button.bezelStyle = .glass
        if circle { button.borderShape = .circle }
    }
    /// Embeds `content` in a glass pane of the same frame.
    static func pane(_ content: NSView, radius: CGFloat, interactive: Bool = false) -> NSView {
        guard #available(macOS 26, *) else { return content }
        let glass = NSGlassEffectView(frame: content.frame)
        glass.cornerRadius = radius
        glass.autoresizingMask = content.autoresizingMask
        #if compiler(>=6.4) // effectIsInteractive ships in the macOS 27 SDK; CI builds with the macOS 26 SDK
        if #available(macOS 27, *) { glass.effectIsInteractive = interactive }
        #endif
        content.frame.origin = .zero
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        return glass
    }
}

/// HUD capsule that rises in, replaces any toast still on screen, and fades away.
enum Toast {
    private static var current: NSPanel?
    static func show(_ message: String, symbol: String? = nil) {
        current?.orderOut(nil)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.sizeToFit()
        let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.map { image -> NSImageView in
            let view = NSImageView(image: image)
            view.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
            view.contentTintColor = .controlAccentColor
            view.frame.size = NSSize(width: 18, height: 18)
            return view
        }
        let inset: CGFloat = 18, gap: CGFloat = icon == nil ? 0 : 26
        let size = NSSize(width: label.frame.width + inset * 2 + gap, height: 40)
        let screen = NSScreen.underPointer?.visibleFrame ?? .zero
        let target = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: target.offsetBy(dx: 0, dy: -10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.sharingType = .none // toasts (the self-timer countdown included) never end up in a capture
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.maskImage = Anim.roundedMask(size.height / 2)
        let content = Glass.available ? NSView(frame: bg.frame) : bg
        if let icon { icon.frame.origin = NSPoint(x: inset, y: (size.height - 18) / 2); content.addSubview(icon) }
        label.frame.origin = NSPoint(x: inset + gap, y: (size.height - label.frame.height) / 2)
        content.addSubview(label)
        panel.contentView = Glass.pane(content, radius: size.height / 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel
        Anim.run(0.28) { panel.animator().alphaValue = 1; panel.animator().setFrame(target, display: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            Anim.run(0.2, { panel.animator().alphaValue = 0 }) { panel.orderOut(nil); if current === panel { current = nil } }
        }
    }
}

/// One place that turns capture permission failures into "here is the switch to flip", instead of raw error codes.
enum Permissions {
    static func explain(_ error: Error) {
        let alert = NSAlert(error: error)
        let declined = (error as? SCStreamError)?.code == .userDeclined || !CGPreflightScreenCaptureAccess()
        if declined {
            alert.messageText = "LeanShot needs Screen Recording permission"
            alert.informativeText = "Turn on LeanShot in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, declined,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

extension NSScreen {
    /// The display under the pointer: new windows and overlays open where the user is working.
    static var underPointer: NSScreen? { screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main }
}

extension NSWindow {
    func centerOnPointerScreen() {
        guard let f = NSScreen.underPointer?.visibleFrame else { return center() }
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + f.height / 12)) // a touch above center, like center()
    }
}
