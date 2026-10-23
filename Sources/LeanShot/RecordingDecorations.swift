import AppKit
import AVFoundation
import ApplicationServices

/// Windows explicitly included in display/area recording filters, while LeanShot's UI stays excluded.
final class RecordingDecorations {
    private var camera: NSPanel?
    private var keys: NSPanel?
    private var desktop: NSPanel?
    private var clicks: NSPanel?
    private var clickView: ClickOverlay?
    private var clickMonitor: Any?
    private var session: AVCaptureSession?
    private var monitor: Any?
    private var keyGeneration = 0
    private let cameraQueue = DispatchQueue(label: "LeanShot.camera")
    var windowIDs: Set<CGWindowID> { Set([camera, keys, desktop, clicks].compactMap { $0.map { CGWindowID($0.windowNumber) } }) }

    @MainActor func prepare(screen: NSScreen?, region: CGRect?) async throws {
        let bounds = region ?? screen?.visibleFrame ?? .zero
        if Settings.recordKeystrokes, !AXIsProcessTrusted() { throw Self.error("Enable LeanShot in System Settings → Privacy & Security → Accessibility to show keystrokes, or disable keystrokes in LeanShot Settings.") }
        if Settings.hideDesktop, let screen {
            let panel = Self.panel(screen.frame); panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.ignoresMouseEvents = true; panel.backgroundColor = .windowBackgroundColor
            let image = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) { image.image = NSImage(contentsOf: url) }
            image.imageScaling = .scaleAxesIndependently; panel.contentView = image; panel.orderFrontRegardless(); desktop = panel
        }
        if Settings.recordClicks {
            let panel = Self.panel(bounds); panel.ignoresMouseEvents = true
            let view = ClickOverlay(frame: CGRect(origin: .zero, size: bounds.size)); panel.contentView = view; panel.orderFrontRegardless()
            clicks = panel; clickView = view
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak view] _ in
                let p = NSEvent.mouseLocation
                if bounds.contains(p) { view?.show(at: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            }
        }
        if Settings.recordCamera {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw Self.error("Enable Camera access in System Settings or disable camera recording in LeanShot Settings.") }
            let cameraSession: AVCaptureSession = try await withCheckedThrowingContinuation { continuation in
                cameraQueue.async {
                    do {
                        guard let device = AVCaptureDevice.default(for: .video) else { throw Self.error("No camera is available.") }
                        let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .medium
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw Self.error("The camera cannot be opened.") }
                        session.addInput(input); session.commitConfiguration(); session.startRunning(); continuation.resume(returning: session)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            session = cameraSession
            let size = min(Settings.cameraSize, min(bounds.width, bounds.height) * 0.45)
            let right = Settings.cameraCorner % 2 == 1, top = Settings.cameraCorner >= 2
            let rect = Settings.cameraFullscreen ? bounds : NSRect(x: right ? bounds.maxX - size - 20 : bounds.minX + 20, y: top ? bounds.maxY - size - 20 : bounds.minY + 20, width: size, height: size)
            let panel = Self.panel(rect)
            let view = CameraPreview(frame: NSRect(origin: .zero, size: rect.size))
            view.wantsLayer = true; view.layer?.cornerRadius = Settings.cameraFullscreen ? 0 : Settings.cameraCircle ? size / 2 : 18; view.layer?.masksToBounds = true
            view.preview.session = cameraSession; view.preview.videoGravity = .resizeAspectFill
            panel.contentView = view; panel.isMovableByWindowBackground = true; panel.orderFrontRegardless(); camera = panel
        }
        if Settings.recordKeystrokes {
            let width = min(300, max(100, bounds.width - 40)), height = Settings.keysSize + 25
            let right = Settings.keysCorner % 2 == 1, top = Settings.keysCorner >= 2
            let rect = NSRect(x: right ? bounds.maxX - width - 20 : bounds.minX + 20, y: top ? bounds.maxY - height - 24 : bounds.minY + 24, width: width, height: height)
            let panel = Self.panel(rect)
            panel.ignoresMouseEvents = true
            let label = NSTextField(labelWithString: "Shortcuts")
            label.frame = NSRect(x: 12, y: 8, width: width - 24, height: height - 16); label.font = .systemFont(ofSize: Settings.keysSize, weight: .medium); label.alignment = .center
            label.textColor = Settings.keysLight ? .black : .white
            let view = NSView(frame: NSRect(origin: .zero, size: rect.size)); view.wantsLayer = true
            view.layer?.backgroundColor = (Settings.keysLight ? NSColor.white : NSColor.black).withAlphaComponent(0.85).cgColor; view.layer?.cornerRadius = 12
            view.addSubview(label); panel.contentView = view; panel.orderFrontRegardless(); keys = panel
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self, weak label] event in
                guard let self else { return }
                let flags = event.modifierFlags
                if Settings.commandKeysOnly && flags.intersection([.command, .control, .option]).isEmpty { return }
                let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
                let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
                let modifiers = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                label?.stringValue = modifiers + key
                self.keyGeneration += 1; let generation = self.keyGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak label] in
                    if self?.keyGeneration == generation { label?.stringValue = "" }
                }
            }
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        keyGeneration += 1
        camera?.orderOut(nil); camera?.contentView = nil; camera = nil
        keys?.orderOut(nil); keys?.contentView = nil; keys = nil
        desktop?.orderOut(nil); desktop?.contentView = nil; desktop = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        clickView?.stop(); clickView = nil; clicks?.orderOut(nil); clicks?.contentView = nil; clicks = nil
        if let session { self.session = nil; cameraQueue.async { session.stopRunning() } }
    }
    private static func panel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; return p
    }
    private static func error(_ description: String) -> NSError { NSError(domain: "LeanShot", code: 3, userInfo: [NSLocalizedDescriptionKey: description]) }
}

private final class CameraPreview: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(preview) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds }
    override var mouseDownCanMoveWindow: Bool { true }
}
