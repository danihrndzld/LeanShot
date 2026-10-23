import AppKit
import AVFoundation
import Quartz

/// Independent cards stay visible across captures and can be restored after dismissal.
enum QuickAccess {
    private static var cards: [OverlayCard] = []
    private static var recentlyClosed: [URL] = []
    private static var hidden = false

    static var activeCount: Int { cards.count }
    static func preview(_ url: URL, to output: URL) {
        let left = OverlayCard(url: url, screen: NSScreen.main)
        let right = OverlayCard(url: url, screen: NSScreen.main)
        left.panel.setFrameOrigin(NSPoint(x: 100, y: 120)); right.panel.setFrameOrigin(NSPoint(x: 420, y: 120))
        left.panel.orderFrontRegardless(); right.panel.orderFrontRegardless(); right.setHovered(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let views = [left, right]
            let size = NSSize(width: left.bounds.width * 2 + 72, height: left.bounds.height + 80)
            let image = ImageTools.render(size: size, pixels: NSSize(width: size.width * 2, height: size.height * 2)) { rect in
                NSColor(srgbRed: 0.22, green: 0.3, blue: 0.44, alpha: 1).setFill(); rect.fill()
                for (index, view) in views.enumerated() {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        rep.draw(in: NSRect(x: 24 + CGFloat(index) * (view.bounds.width + 24), y: 28, width: view.bounds.width, height: view.bounds.height))
                    }
                }
            }
            do { try ImageTools.png(image)?.write(to: output); print("wrote \(output.path)"); exit(0) }
            catch { print(error); exit(1) }
        }
    }
    static func dismiss() { cards.forEach { $0.panel.orderOut(nil); $0.panel.contentView = nil }; recentlyClosed = cards.map(\.url); cards.removeAll() }
    static func hide() { hidden = true; cards.forEach { $0.panel.orderOut(nil) } }
    static func resume() { hidden = false; layout() }
    static func restore() {
        hidden = false
        if cards.isEmpty {
            let urls = recentlyClosed; recentlyClosed = []
            urls.filter { FileManager.default.fileExists(atPath: $0.path) }.reversed().forEach { show($0) }
        } else { layout() }
    }
    static func close(_ card: OverlayCard) {
        recentlyClosed.removeAll { $0 == card.url }; recentlyClosed.insert(card.url, at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(8))
        card.panel.orderOut(nil); card.panel.contentView = nil; cards.removeAll { $0 === card }; layout()
    }
    static func show(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let existing = cards.first(where: { $0.url == url }) { close(existing) }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let card = OverlayCard(url: url, screen: screen)
        cards.insert(card, at: 0)
        while cards.count > 4 { close(cards.last!) }
        hidden = false; layout()
        if Settings.autoClose > 0 { scheduleClose(card, after: Settings.autoClose) }
    }
    private static func scheduleClose(_ card: OverlayCard, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak card] in
            guard let card, cards.contains(where: { $0 === card }) else { return }
            if card.isHovered || card.isDragging || card.menuIsOpen || hidden { scheduleClose(card, after: 1) }
            else { close(card) }
        }
    }
    private static func layout() {
        var offsets: [UInt32: CGFloat] = [:]
        for card in cards {
            let screen = card.screen ?? NSScreen.main
            let f = screen?.visibleFrame ?? .zero
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let offset = offsets[id] ?? 20
            let right = Settings.corner % 2 == 1, top = Settings.corner >= 2
            let x = right ? f.maxX - card.panel.frame.width - 20 : f.minX + 20
            let y = top ? f.maxY - offset - card.panel.frame.height : f.minY + offset
            if offset + card.panel.frame.height > f.height { card.panel.orderOut(nil); continue }
            card.panel.setFrameOrigin(NSPoint(x: x, y: y))
            if !hidden { card.panel.orderFrontRegardless() }
            offsets[id] = offset + card.panel.frame.height + 12
        }
    }
}

final class OverlayCard: NSView, NSMenuDelegate, QLPreviewPanelDataSource {
    let url: URL
    let panel: NSPanel
    let screen: NSScreen?
    var isHovered = false
    var isDragging = false
    var menuIsOpen = false
    private let controls = NSView()
    private let thumbnail: DragImageView
    private var actions: [() -> Void] = []
    private var tracking: NSTrackingArea?

    init(url: URL, screen: NSScreen?) {
        self.url = url; self.screen = screen
        let image = NSImage(contentsOf: url)
        let width = Settings.overlayWidth
        let ratio = image.map { $0.size.height / max(1, $0.size.width) } ?? 0.56
        let height = min(210, max(110, width * ratio))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        thumbnail = DragImageView(frame: frame)
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        // Exclude overlays from screenshots taken by screen capture APIs.
        panel.sharingType = .none
        thumbnail.url = url; thumbnail.image = image ?? NSWorkspace.shared.icon(forFile: url.path)
        if image == nil, ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
            Task { @MainActor [weak self] in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 680, height: 420)
                if let frame = try? await generator.image(at: .zero) {
                    self?.thumbnail.image = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
                }
            }
        }
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.toolTip = "Drag to any app · Double-click to edit · Right-click for actions"
        thumbnail.doubleClick = { [weak self] in self?.edit() }
        thumbnail.dragging = { [weak self] in self?.isDragging = $0; if !$0 { self?.setHovered(false) } }
        addSubview(thumbnail)
        let shade = NSVisualEffectView(frame: bounds)
        shade.material = .hudWindow; shade.state = .active; shade.blendingMode = .withinWindow
        controls.frame = bounds
        controls.addSubview(shade)
        // Keep the center image draggable. Only actual buttons intercept events.
        shade.alphaValue = 0.85
        let copy = button("Copy", symbol: nil, rect: NSRect(x: (width - 80) / 2, y: height / 2 + 2, width: 80, height: 28)) { Clipboard.copy(url); Toast.show("Copied") }
        copy.bezelStyle = .rounded
        let save = button("Save…", symbol: nil, rect: NSRect(x: (width - 80) / 2, y: height / 2 - 32, width: 80, height: 28)) { [weak self] in self?.save() }
        save.bezelStyle = .rounded
        _ = button("Pin to Screen", symbol: "pin.fill", rect: NSRect(x: 10, y: height - 36, width: 28, height: 28)) { [weak self] in self?.pin() }
        _ = button("Close", symbol: "xmark", rect: NSRect(x: width - 38, y: height - 36, width: 28, height: 28)) { [weak self] in if let self { QuickAccess.close(self) } }
        _ = button("Annotate", symbol: "pencil", rect: NSRect(x: 10, y: 8, width: 28, height: 28)) { [weak self] in self?.edit() }
        _ = button("Share", symbol: "square.and.arrow.up", rect: NSRect(x: width - 38, y: 8, width: 28, height: 28)) { [weak self] in self?.share() }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let info = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        info.font = .systemFont(ofSize: 10); info.textColor = .secondaryLabelColor; info.alignment = .center
        info.frame = NSRect(x: 44, y: 12, width: width - 88, height: 16); controls.addSubview(info)
        controls.isHidden = true
        addSubview(controls)
        let menu = NSMenu()
        func action(_ title: String, _ run: @escaping () -> Void) {
            actions.append(run)
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = actions.count - 1; menu.addItem(item)
        }
        action(image == nil ? "Open Video Editor…" : "Open Annotation Tool…") { [weak self] in self?.edit() }
        if image != nil {
            action("Pin to the Screen") { [weak self] in self?.pin() }
            action("Rotate Left") { [weak self] in self?.rotate() }
            action("Copy Text / QR Code") { OCR.copyContents(url) }
        }
        menu.addItem(.separator())
        action("Copy") { Clipboard.copy(url) }
        action("Save As…") { [weak self] in self?.save() }
        action("Quick Look") { [weak self] in self?.quickLook() }
        action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        action("Share…") { [weak self] in self?.share() }
        menu.addItem(.separator())
        action("Temporarily Hide Overlays") { QuickAccess.hide() }
        action("Close") { [weak self] in if let self { QuickAccess.close(self) } }
        action("Move to Trash") { [weak self] in
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); if let self { QuickAccess.close(self) } }
            catch { NSAlert(error: error).runModal() }
        }
        menu.delegate = self; self.menu = menu; thumbnail.menu = menu
        panel.contentView = self
    }
    required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String, symbol: String?, rect: NSRect, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(frame: rect, action: action); b.title = symbol == nil ? title : ""
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        b.bezelStyle = .circular; b.toolTip = title; controls.addSubview(b); return b
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if !controls.isHidden {
            for button in controls.subviews.compactMap({ $0 as? NSButton }) where button.frame.contains(p) { return button }
        }
        return bounds.contains(p) ? thumbnail : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { if !isDragging { setHovered(false) } }
    override func swipe(with event: NSEvent) { if abs(event.deltaX) > 0 { QuickAccess.close(self) } }
    fileprivate func setHovered(_ value: Bool) { isHovered = value; controls.isHidden = !value }
    @objc private func menuAction(_ sender: NSMenuItem) { actions[sender.tag]() }
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
    private func quickLook() {
        guard let preview = QLPreviewPanel.shared() else { return }
        NSApp.activate(ignoringOtherApps: true); preview.dataSource = self; preview.reloadData(); preview.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL }
    private func edit() {
        if NSImage(contentsOf: url) != nil { AnnotateWindow.open(url) }
        else { VideoEditor.open(url) }
    }
    private func pin() { if let image = NSImage(contentsOf: url) { PinWindow.pin(image) } }
    private func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = url.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let destination = p.url, destination != url {
            do { let data = try Data(contentsOf: url); try data.write(to: destination, options: .atomic); Toast.show("Saved") }
            catch { NSAlert(error: error).runModal() }
        }
    }
    private func share() { NSSharingServicePicker(items: [url]).show(relativeTo: bounds, of: self, preferredEdge: .maxX) }
    private func rotate() {
        guard let image = NSImage(contentsOf: url), let data = ImageTools.png(ImageTools.rotate(image, clockwise: false)) else { return }
        do { try data.write(to: url, options: .atomic); thumbnail.image = NSImage(contentsOf: url) }
        catch { NSAlert(error: error).runModal() }
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
    var doubleClick: (() -> Void)?
    var dragging: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        if event.clickCount == 2 { if let doubleClick { doubleClick() } else { NSWorkspace.shared.open(url) }; return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        dragging?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging?(false) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Screenshot pinned above all windows. Drag to move, scroll to zoom, Esc or double-click to close.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    static func unlockAll() { open.forEach { $0.ignoresMouseEvents = false } }

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
        let menu = NSMenu()
        for (title, action) in [("Lock (Click Through)", #selector(lockPin)), ("Opacity 50% / 100%", #selector(toggleOpacity)), ("Close", #selector(closePin))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = w; menu.addItem(item)
        }
        view.menu = menu
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
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var origin = frame.origin
        switch event.keyCode {
        case 53: dismiss(); return
        case 123: origin.x -= step
        case 124: origin.x += step
        case 125: origin.y -= step
        case 126: origin.y += step
        default: super.keyDown(with: event); return
        }
        setFrameOrigin(origin)
    }
    @objc private func lockPin() { ignoresMouseEvents = true; Toast.show("Pin locked · Menu → Unlock Floating Screenshots") }
    @objc private func toggleOpacity() { alphaValue = alphaValue < 1 ? 1 : 0.5 }
    @objc private func closePin() { dismiss() }

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
