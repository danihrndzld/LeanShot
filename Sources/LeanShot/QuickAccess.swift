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
        // Real window captures, so glass, blur and the layered shadow render as on screen.
        [left, right].forEach { $0.panel.sharingType = .readOnly }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let parts = [left, right].map { card -> URL in
                let file = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
                let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l\(card.panel.windowNumber)", file.path]; try? task.run(); task.waitUntilExit()
                return file
            }
            let images = parts.compactMap { NSImage(contentsOf: $0) }
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            guard images.count == 2 else { print("capture failed"); exit(1) }
            let size = NSSize(width: images[0].size.width * 2 + 24, height: images[0].size.height + 24)
            let image = ImageTools.render(size: size, pixels: NSSize(width: size.width * 2, height: size.height * 2)) { rect in
                NSColor(srgbRed: 0.91, green: 0.92, blue: 0.95, alpha: 1).setFill(); rect.fill()
                for (index, part) in images.enumerated() { part.draw(at: NSPoint(x: 12 + CGFloat(index) * (part.size.width + 0), y: 12), from: .zero, operation: .sourceOver, fraction: 1) }
            }
            do { try ImageTools.png(image)?.write(to: output); print("wrote \(output.path)"); exit(0) }
            catch { print(error); exit(1) }
        }
    }
    static func dismiss() { cards.forEach { $0.panel.orderOut(nil); $0.panel.contentView = nil }; recentlyClosed = cards.map(\.url); cards.removeAll() }
    static func hide() { hidden = true; cards.forEach { $0.panel.orderOut(nil) } }
    static func resume() { hidden = false; layout() }
    static func restore() {
        let wasHidden = hidden
        hidden = false
        if wasHidden, !cards.isEmpty { layout(); return }
        if let url = recentlyClosed.first(where: { url in !cards.contains(where: { $0.url == url }) && FileManager.default.fileExists(atPath: url.path) }) {
            recentlyClosed.removeAll { $0 == url }; show(url)
        } else { layout() }
    }
    /// `dx` sends the card off in a swipe's direction; nil slides it back toward its screen edge.
    static func close(_ card: OverlayCard, dx: CGFloat? = nil, duration: TimeInterval = 0.2) {
        recentlyClosed.removeAll { $0 == card.url }; recentlyClosed.insert(card.url, at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(8))
        cards.removeAll { $0 === card }; layout()
        let panel = card.panel
        guard panel.isVisible, !Anim.reduced else { panel.orderOut(nil); panel.contentView = nil; return }
        // Slide back toward the edge it came from; the card stays alive until the panel lets go.
        Anim.run(duration, {
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: dx ?? edgeOffset(panel), dy: 0), display: false)
        }) { panel.orderOut(nil); panel.contentView = nil }
    }
    private static func edgeOffset(_ panel: NSPanel) -> CGFloat { (Settings.corner % 2 == 1 ? 1 : -1) * (panel.frame.width + 24) }
    static func show(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let existing = cards.first(where: { $0.url == url }) { close(existing) }
        let screen = NSScreen.underPointer
        let card = OverlayCard(url: url, screen: screen)
        cards.insert(card, at: 0)
        while cards.count > 4 { close(cards.last!) }
        hidden = false; layout()
        if Settings.autoClose > 0 { scheduleClose(card, after: Settings.autoClose) }
    }
    private static func scheduleClose(_ card: OverlayCard, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak card] in
            guard let card, cards.contains(where: { $0 === card }) else { return }
            if card.isHovered || card.isDragging || card.isSwiping || card.menuIsOpen || hidden { scheduleClose(card, after: 1) }
            else { close(card) }
        }
    }
    private static func layout() {
        var offsets: [UInt32: CGFloat] = [:]
        for card in cards {
            let screen = card.screen ?? NSScreen.main
            let f = screen?.visibleFrame ?? .zero
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let offset = offsets[id] ?? 14
            let right = Settings.corner % 2 == 1, top = Settings.corner >= 2
            let m = OverlayCard.margin, w = card.panel.frame.width - 2 * m, h = card.panel.frame.height - 2 * m
            let x = (right ? f.maxX - w - 14 : f.minX + 14) - m
            let y = (top ? f.maxY - offset - h : f.minY + offset) - m
            if offset + h > f.height { card.panel.orderOut(nil); continue }
            offsets[id] = offset + h + 8
            let target = NSRect(origin: NSPoint(x: x, y: y), size: card.panel.frame.size)
            guard !hidden else { card.panel.setFrame(target, display: false); continue }
            if card.panel.isVisible {
                Anim.run(0.3) { card.panel.animator().setFrame(target, display: true) } // restack
            } else {
                // New cards slide in from the screen edge; returning cards just fade back.
                card.panel.setFrame(card.presented ? target : target.offsetBy(dx: edgeOffset(card.panel), dy: 0), display: false)
                card.panel.alphaValue = 0; card.panel.orderFrontRegardless()
                Anim.run(card.presented ? 0.2 : 0.38) { card.panel.animator().alphaValue = 1; card.panel.animator().setFrame(target, display: true) }
                card.presented = true
            }
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
    var presented = false
    private let controls = NSView()
    private let thumbnail: DragImageView
    private var actions: [() -> Void] = []
    private var tracking: NSTrackingArea?

    init(url: URL, screen: NSScreen?) {
        self.url = url; self.screen = screen
        let image = Thumbnail.image(url, maxPixels: 600) // the card is at most 230 pt wide
        let width = Settings.overlayWidth
        let ratio = image.map { $0.size.height / max(1, $0.size.width) } ?? 0.56
        let height = min(150, max(84, width * ratio))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let m = OverlayCard.margin
        panel = NSPanel(contentRect: frame.insetBy(dx: -m, dy: -m), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        thumbnail = DragImageView(frame: frame)
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = Glass.available ? 18 : 14; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        // Exclude overlays from screenshots taken by screen capture APIs.
        panel.sharingType = .none
        thumbnail.url = url; thumbnail.image = image ?? NSWorkspace.shared.icon(forFile: url.path)
        if image == nil, ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
            Task { @MainActor [weak self] in if let frame = await Thumbnail.video(url, maxPixels: 680) { self?.thumbnail.image = frame } }
        }
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.toolTip = "Drag to any app · Double-click to edit · Right-click for actions"
        thumbnail.doubleClick = { [weak self] in self?.edit() }
        thumbnail.dragging = { [weak self] in self?.isDragging = $0; if !$0 { self?.setHovered(false) } }
        addSubview(thumbnail)
        // Hover frosts the thumbnail with a dark blur, so controls read the same on any screenshot.
        let shade = NSVisualEffectView(frame: bounds)
        shade.material = .hudWindow; shade.state = .active; shade.blendingMode = .withinWindow
        controls.frame = bounds; controls.appearance = NSAppearance(named: .darkAqua)
        controls.addSubview(shade)
        // Keep the center image draggable. Only actual buttons intercept events.
        let copy = button("Copy", symbol: nil, rect: NSRect(x: width / 2 - 66, y: height / 2 - 11, width: 62, height: 24)) { Clipboard.copy(url); Toast.show("Copied", symbol: "checkmark.circle.fill") }
        copy.bezelStyle = .rounded; Glass.style(copy)
        let save = button("Save", symbol: nil, rect: NSRect(x: width / 2 + 4, y: height / 2 - 11, width: 62, height: 24)) { [weak self] in self?.save() }
        save.bezelStyle = .rounded; Glass.style(save)
        for b in [copy, save] { b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]) }
        _ = button("Pin to Screen", symbol: "pin.fill", rect: NSRect(x: 8, y: height - 32, width: 24, height: 24)) { [weak self] in self?.pin() }
        _ = button("Close", symbol: "xmark", rect: NSRect(x: width - 32, y: height - 32, width: 24, height: 24)) { [weak self] in if let self { QuickAccess.close(self) } }
        _ = button("Annotate", symbol: "pencil", rect: NSRect(x: 8, y: 8, width: 24, height: 24)) { [weak self] in self?.edit() }
        _ = button("Share", symbol: "square.and.arrow.up", rect: NSRect(x: width - 32, y: 8, width: 24, height: 24)) { [weak self] in self?.share() }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let info = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        info.font = .systemFont(ofSize: 10); info.textColor = .secondaryLabelColor; info.alignment = .center
        info.frame = NSRect(x: 36, y: 12, width: width - 72, height: 14); controls.addSubview(info)
        controls.alphaValue = 0
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
        // Own layered shadow (soft ambient + tight contact) instead of the window server's hard one.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * m, height: height + 2 * m)); container.wantsLayer = true
        for (radius, offset, opacity) in [(CGFloat(22), CGFloat(-12), Float(0.24)), (5, -2, 0.14)] {
            let shadow = CALayer(); shadow.frame = NSRect(x: m, y: m, width: width, height: height)
            shadow.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: layer!.cornerRadius, cornerHeight: layer!.cornerRadius, transform: nil)
            shadow.shadowColor = NSColor.black.cgColor; shadow.shadowRadius = radius; shadow.shadowOffset = CGSize(width: 0, height: offset); shadow.shadowOpacity = opacity
            container.layer?.addSublayer(shadow)
        }
        setFrameOrigin(NSPoint(x: m, y: m)); container.addSubview(self)
        panel.contentView = container
    }
    /// Transparent room around the card for its shadow; layout subtracts it so cards keep their 20 pt inset.
    static let margin: CGFloat = 40
    required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String, symbol: String?, rect: NSRect, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(frame: rect, action: action); b.title = symbol == nil ? title : ""
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(paletteColors: [.white])) }
        b.bezelStyle = .circular; if symbol != nil { Glass.style(b, circle: true) }; b.toolTip = title; controls.addSubview(b); return b
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if isHovered {
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
    /// Two-finger horizontal swipe: the card follows the fingers, and a flick or a drag past 60 pt throws it off at the
    /// fingers' speed; otherwise it springs back. The axis locks on the first moving event, because `.began` carries no deltas.
    private var swipe: (home: NSRect, dx: CGFloat, velocity: CGFloat, time: TimeInterval, horizontal: Bool?)?
    var isSwiping: Bool { swipe != nil } // auto-close waits, so it never animates the panel under the fingers
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return } // .ended already decided the throw
        if event.phase == .began { swipe = (panel.frame, 0, 0, event.timestamp, nil); return }
        guard var s = swipe else { return }
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if s.horizontal == nil, delta != 0 || event.scrollingDeltaY != 0 {
            s.horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            if s.horizontal == false { swipe = nil; return }
        }
        if delta != 0 {
            let dt = max(0.004, event.timestamp - s.time)
            s.velocity = s.velocity * 0.4 + delta / dt * 0.6; s.time = event.timestamp
        }
        s.dx += delta
        swipe = s
        if event.phase == .changed, s.horizontal == true {
            panel.setFrameOrigin(s.home.origin.applying(.init(translationX: s.dx, y: 0))); panel.alphaValue = max(0.3, 1 - abs(s.dx) / 300)
        }
        guard event.phase == .ended || event.phase == .cancelled else { return }
        swipe = nil
        guard s.horizontal == true else { return }
        // A finger resting before lift-off leaves a stale velocity; only a recent one counts as a flick.
        let velocity = event.timestamp - s.time < 0.05 ? s.velocity : 0
        if event.phase == .ended, let direction = OverlayCard.throwDirection(dx: s.dx, velocity: velocity) {
            let distance = s.home.width + 40 - abs(s.dx)
            // Anim.easeOut starts at about 4.5x its average speed, so this duration hands off at the fingers' speed.
            let duration = min(0.35, max(0.14, 4.5 * distance / max(1, abs(velocity))))
            QuickAccess.close(self, dx: direction * distance, duration: duration)
        } else { Anim.run(0.3) { panel.animator().setFrame(s.home, display: true); panel.animator().alphaValue = 1 } }
    }
    /// Which way a released swipe throws the card: -1 or 1, or nil to spring back. A flick above 500 pt/s throws in
    /// its own direction even when short; a slow drag throws once it passes 60 pt.
    static func throwDirection(dx: CGFloat, velocity: CGFloat) -> CGFloat? {
        if abs(velocity) > 500 { return velocity > 0 ? 1 : -1 }
        return abs(dx) > 60 ? (dx > 0 ? 1 : -1) : nil
    }
    fileprivate func setHovered(_ value: Bool) {
        isHovered = value
        Anim.run(value ? 0.16 : 0.12) { controls.animator().alphaValue = value ? 1 : 0 }
    }
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
        if Thumbnail.isImage(url) { AnnotateWindow.open(url) }
        else { VideoEditor.open(url) }
    }
    private func pin() { if let image = NSImage(contentsOf: url) { PinWindow.pin(image) } }
    private func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = url.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let destination = p.url, destination != url {
            do { let data = try Data(contentsOf: url); try data.write(to: destination, options: .atomic); Toast.show("Saved", symbol: "checkmark.circle.fill") }
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

    private var pressed: NSEvent?
    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        if event.clickCount == 2 { if let doubleClick { doubleClick() } else { NSWorkspace.shared.open(url) }; return }
        pressed = event // a drag starts only after 4 pt of movement, so plain clicks stay clicks
    }
    override func mouseDragged(with event: NSEvent) {
        guard let url, let start = pressed,
              hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y) > 4 else { return }
        pressed = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        dragging?(true)
        beginDraggingSession(with: [item], event: start, source: self)
    }
    override func mouseUp(with event: NSEvent) { pressed = nil }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging?(false) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Screenshot pinned above all windows. Drag to move, scroll to zoom, Esc or double-click to close.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    static func unlockAll() { open.forEach { $0.ignoresMouseEvents = false } }

    static func pin(_ image: NSImage) {
        let screen = NSScreen.underPointer?.visibleFrame ?? .zero
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
        // A pin is a working surface: copy, save or mark it up without hunting for the original file.
        for (title, action, key) in [("Copy", #selector(copyPin), "c"), ("Save As…", #selector(savePin), "s"), ("Annotate…", #selector(annotatePin), ""), ("", nil, ""),
                                     ("Lock (Click Through)", #selector(lockPin), ""), ("Opacity 50% / 100%", #selector(toggleOpacity), ""), ("Close", #selector(closePin), "w")] as [(String, Selector?, String)] {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = w; menu.addItem(item)
        }
        w.image = image
        view.menu = menu
        w.aspectRatio = size
        w.level = .floating
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let target = w.frame
        w.setFrame(target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04), display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        Anim.run(0.24) { w.animator().alphaValue = 1; w.animator().setFrame(target, display: true) }
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
    @objc private func toggleOpacity() { let value: CGFloat = alphaValue < 1 ? 1 : 0.5; Anim.run(0.2) { animator().alphaValue = value } }
    @objc private func closePin() { dismiss() }
    private var image = NSImage()
    @objc private func copyPin() { Clipboard.copy(image); Toast.show("Copied", symbol: "checkmark.circle.fill") }
    @objc private func savePin() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Pinned Screenshot.png"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { guard let png = ImageTools.png(image) else { throw CocoaError(.fileWriteUnknown) }; try png.write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func annotatePin() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pinned Screenshot \(UUID().uuidString.prefix(4)).png")
        guard let png = ImageTools.png(image), (try? png.write(to: url)) != nil else { return NSSound.beep() }
        AnnotateWindow.open(url)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c": copyPin(); return true
        case "s": savePin(); return true
        case "w": dismiss(); return true
        default: return super.performKeyEquivalent(with: event)
        }
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
        PinWindow.open.removeAll { $0 === self }
        Anim.run(0.15, { animator().alphaValue = 0 }) { self.orderOut(nil) }
    }
}

/// Plain view (not NSImageView) so clicks reach the window: drag moves it, double-click closes it.
final class PinView: NSView {
    var image: NSImage?
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds) }
}
