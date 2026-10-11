import AppKit

/// Floating thumbnail shown after each capture (CleanShot's "Quick Access Overlay").
enum QuickAccess {
    private static var panel: NSPanel?

    static func dismiss() { panel?.orderOut(nil); panel = nil }

    static func show(_ url: URL) {
        dismiss()
        let isImage = NSImage(contentsOf: url) != nil
        let size = NSSize(width: 260, height: 200)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14

        let thumb = DragImageView(frame: NSRect(x: 10, y: 50, width: size.width - 20, height: size.height - 60))
        thumb.url = url
        thumb.image = isImage ? NSImage(contentsOf: url) : NSWorkspace.shared.icon(forFile: url.path)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.toolTip = "Drag into any app"
        bg.addSubview(thumb)

        var buttons: [(String, String, () -> Void)] = [
            ("doc.on.doc", "Copy", { Clipboard.copy(url); Toast.show("Copied") }),
            ("folder", "Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
        ]
        if isImage {
            buttons += [
                ("pencil.tip.crop.circle", "Annotate", { AnnotateWindow.open(url) }),
                ("pin", "Pin", { if let i = NSImage(contentsOf: url) { PinWindow.pin(i) } }),
                ("text.viewfinder", "Copy Text", {
                    guard let i = NSImage(contentsOf: url) else { return }
                    OCR.recognize(i) { text in
                        guard !text.isEmpty else { return Toast.show("No text found") }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        Toast.show("Copied \(text.count) characters")
                    }
                }),
            ]
        }
        buttons += [
            ("trash", "Delete", { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); dismiss() }),
            ("xmark", "Close", { dismiss() }),
        ]
        let w = (size.width - 20) / CGFloat(buttons.count)
        for (i, (symbol, tip, action)) in buttons.enumerated() {
            let b = ClosureButton(frame: NSRect(x: 10 + CGFloat(i) * w, y: 10, width: w, height: 30), action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.bezelStyle = .regularSquare
            b.isBordered = false
            bg.addSubview(b)
        }

        p.contentView = bg
        p.orderFrontRegardless()
        panel = p
    }
}

final class ClosureButton: NSButton {
    private var handler: () -> Void
    func setHandler(_ h: @escaping () -> Void) { handler = h }
    init(frame: NSRect, action: @escaping () -> Void) {
        handler = action
        super.init(frame: frame)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Thumbnail that can be dragged out as a file into Finder, Slack, Mail, etc.
final class DragImageView: NSImageView, NSDraggingSource {
    var url: URL?

    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        if event.clickCount == 2 { NSWorkspace.shared.open(url); return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Screenshot pinned above all windows. Drag to move, scroll to zoom, Esc or double-click to close.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    static func pin(_ image: NSImage) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var size = image.size
        let fit = min(1, screen.width * 0.6 / size.width, screen.height * 0.6 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        let w = PinWindow(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                              width: size.width, height: size.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = PinView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        w.aspectRatio = size
        w.level = .floating
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.makeKeyAndOrderFront(nil)
        open.append(w)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { dismiss() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY / 100
        var f = frame
        let newSize = NSSize(width: f.width * factor, height: f.height * factor)
        if (factor < 1 && newSize.width < 60) || (factor > 1 && newSize.width > 4000) { return }
        f.origin.x -= (newSize.width - f.width) / 2
        f.origin.y -= (newSize.height - f.height) / 2
        f.size = newSize
        setFrame(f, display: true)
    }

    private func dismiss() {
        orderOut(nil)
        PinWindow.open.removeAll { $0 === self }
    }
}

/// Plain view (not NSImageView) so clicks reach the window: drag moves it, double-click closes it.
final class PinView: NSView {
    var image: NSImage?
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds) }
}
