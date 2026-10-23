import AppKit
import ScreenCaptureKit

struct ScreenRegion {
    var screen: NSScreen
    var rect: CGRect // AppKit points, relative to this display's bottom left.
    var globalRect: CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(x: screen.frame.minX + rect.minX, y: top - screen.frame.minY - rect.maxY, width: rect.width, height: rect.height)
    }
    var displayID: CGDirectDisplayID { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
}

/// Freeze-frame region picker shared by screenshots, scrolling capture and video.
final class RegionSelector: NSWindow {
    private static var current: RegionSelector?
    static var isSelecting = false

    static func choose(size: CGSize? = nil, completion: @escaping (ScreenRegion?, NSImage?) -> Void) {
        guard !isSelecting, Capture.current == nil else { NSSound.beep(); return }
        isSelecting = true; QuickAccess.hide()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { isSelecting = false; completion(nil, nil); return }
        if let size, size.width > screen.frame.width || size.height > screen.frame.height {
            isSelecting = false; QuickAccess.resume(); Toast.show("The requested dimensions must fit on this display"); completion(nil, nil); return
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CocoaError(.featureUnsupported) }
                let config = SCStreamConfiguration(); config.width = Int(screen.frame.width * screen.backingScaleFactor); config.height = Int(screen.frame.height * screen.backingScaleFactor); config.showsCursor = false
                let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let image = NSImage(cgImage: cg, size: screen.frame.size)
                let w = RegionSelector(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.level = .screenSaver; w.isOpaque = true; w.acceptsMouseMovedEvents = true
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let v = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)); v.image = image
                if let encoded = Settings.defaults.string(forKey: "lastRegion.\(displayID)") { v.selection = NSRectFromString(encoded) }
                v.fixedSize = size
                v.finish = { [weak w] rect in
                    let region = rect.map { ScreenRegion(screen: screen, rect: $0) }
                    let shot = rect.map { ImageTools.crop(image, to: $0) }
                    if let rect { Settings.defaults.set(NSStringFromRect(rect), forKey: "lastRegion.\(displayID)") }
                    w?.orderOut(nil); current = nil; isSelecting = false; QuickAccess.resume(); completion(region, shot)
                }
                w.contentView = v; current = w
                NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
            } catch { isSelecting = false; QuickAccess.resume(); NSAlert(error: error).runModal(); completion(nil, nil) }
        }
    }
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var image: NSImage?
    var selection = CGRect.zero
    var fixedSize: CGSize? {
        didSet { if let fixedSize { selection = CGRect(x: (bounds.width - fixedSize.width) / 2, y: (bounds.height - fixedSize.height) / 2, width: fixedSize.width, height: fixedSize.height) } }
    }
    var finish: ((CGRect?) -> Void)?
    private var start = CGPoint.zero
    private var pointer = CGPoint.zero
    private var magnifier = true
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateFixedSelection(); needsDisplay = true }
    private func updateFixedSelection() {
        if let fixedSize { selection = CGRect(x: min(max(0, pointer.x - fixedSize.width / 2), bounds.width - fixedSize.width), y: min(max(0, pointer.y - fixedSize.height / 2), bounds.height - fixedSize.height), width: fixedSize.width, height: fixedSize.height) }
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); pointer = start
        if fixedSize != nil { updateFixedSelection() } else { selection = .zero }
    }
    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if fixedSize != nil { updateFixedSelection(); needsDisplay = true; return }
        if event.modifierFlags.contains(.shift) {
            let edge = min(abs(pointer.x - start.x), abs(pointer.y - start.y))
            pointer.x = start.x + (pointer.x > start.x ? edge : -edge); pointer.y = start.y + (pointer.y > start.y ? edge : -edge)
        }
        selection = CGRect(x: min(start.x, pointer.x), y: min(start.y, pointer.y), width: abs(pointer.x - start.x), height: abs(pointer.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if selection.width > 2, selection.height > 2 { finish?(selection) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish?(nil)
        case 36 where selection.width > 2 && selection.height > 2: finish?(selection.intersection(bounds))
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "m" { magnifier.toggle(); needsDisplay = true }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
        let dim = NSBezierPath(rect: bounds); dim.windingRule = .evenOdd
        if selection.width > 0 { dim.append(NSBezierPath(rect: selection)) }
        NSColor.black.withAlphaComponent(0.38).setFill(); dim.fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection); border.lineWidth = 1; border.stroke()
        let crosshair = NSBezierPath(); crosshair.move(to: CGPoint(x: pointer.x, y: 0)); crosshair.line(to: CGPoint(x: pointer.x, y: bounds.height)); crosshair.move(to: CGPoint(x: 0, y: pointer.y)); crosshair.line(to: CGPoint(x: bounds.width, y: pointer.y))
        NSColor.white.withAlphaComponent(0.4).setStroke(); crosshair.lineWidth = 0.5; crosshair.stroke()
        let message = "Drag to capture · Shift: square · Return: repeat selection · M: magnifier · Esc: cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let textSize = (message as NSString).size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - textSize.width / 2 - 16, y: 32, width: textSize.width + 32, height: 40)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (message as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY + 12), withAttributes: attrs)
        if selection.width > 0 {
            let size = "\(Int(selection.width)) × \(Int(selection.height)) pt"
            (size as NSString).draw(at: CGPoint(x: selection.minX + 8, y: max(80, selection.minY - 24)), withAttributes: attrs)
        }
        if magnifier, let image {
            let lens = NSRect(x: min(bounds.width - 132, pointer.x + 24), y: min(bounds.height - 132, max(90, pointer.y - 144)), width: 112, height: 112)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: lens, xRadius: 10, yRadius: 10).addClip()
            image.draw(in: lens, from: CGRect(x: pointer.x - 14, y: pointer.y - 14, width: 28, height: 28), operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke(); NSBezierPath(roundedRect: lens, xRadius: 10, yRadius: 10).stroke()
        }
    }
}
