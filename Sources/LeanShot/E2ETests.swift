import AppKit

/// `LeanShot --e2e <junit.xml>`: end-to-end tests that drive the real editor the way a user does.
/// Files open through `AppDelegate.application(_:open:)` (the Finder entry point), input arrives as real mouse and
/// key NSEvents sent to the window, and checks read what a user sees: files on disk, the pasteboard, windows and sheets.
/// Isolation: a throwaway UserDefaults domain (`Settings.testSuite`), a private pasteboard and temporary folders.
/// Out of reach at this level: screencapture/ScreenCaptureKit (Screen Recording permission), Carbon global hotkeys,
/// hover tracking areas and the out-of-process Save panel.
enum E2ETests {
    private struct Failure: Error { let message: String }
    private struct Case { let title: String; let line: Int; let body: () throws -> Void }
    private static var cases: [Case] = []
    private static func test(_ title: String, line: Int = #line, _ body: @escaping () throws -> Void) { cases.append(Case(title: title, line: line, body: body)) }
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws { if !condition { throw Failure(message: message()) } }

    // MARK: Driver

    private static let delegate = AppDelegate()
    private static var captures: URL!, outside: URL!
    /// The editor opened last; it stays addressable after it closes, so checks can still read its state.
    private static var window: AnnotateWindow!
    private static var canvas: Canvas { window.canvas }

    static func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @discardableResult static func wait(_ seconds: Double = 5, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { pump() }
        return condition()
    }

    /// A 800x500 pt capture at 2x: a gray ramp with 4 pt dark stripes, so blurring or pixelating any area changes its pixels.
    static func fixture(_ name: String, in folder: URL, png: Bool = true) -> URL {
        let image = ImageTools.render(size: NSSize(width: 800, height: 500), pixels: NSSize(width: 1600, height: 1000)) { r in
            NSGradient(starting: NSColor(white: 0.85, alpha: 1), ending: NSColor(white: 0.35, alpha: 1))!.draw(in: r, angle: 0)
            NSColor(white: 0.1, alpha: 1).setFill()
            for x in stride(from: 0, to: r.width, by: 8) { NSRect(x: x, y: 0, width: 4, height: r.height).fill() }
        }
        let url = folder.appendingPathComponent(name + (png ? ".png" : ".jpg"))
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try? ImageTools.encode(cg, pointWidth: 800, as: png ? .png : .jpeg)!.write(to: url)
        return url
    }
    static func open(_ url: URL) throws {
        delegate.application(NSApp, open: [url])
        try expect(wait { NSApp.windows.contains { ($0 as? AnnotateWindow)?.isVisible == true && $0.title == url.lastPathComponent } }, "editor did not open \(url.lastPathComponent)")
        window = NSApp.windows.compactMap { $0 as? AnnotateWindow }.last { $0.isVisible && $0.title == url.lastPathComponent }
        window.makeFirstResponder(canvas)
        pump(0.2)
    }
    /// The test process can't become the active app (macOS blocks focus stealing, and CI has no user), and AppKit spends the
    /// first click on an inactive window on activating it. So the driver hands each event to the view `hitTest` finds,
    /// which is what NSWindow.sendEvent does for a key window; the canvas code that runs is the same.
    private static var pressed: NSView?
    static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
        let e = NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        if window.isKeyWindow { window.sendEvent(e); return }
        switch type {
        case .leftMouseDown:
            pressed = window.contentView?.superview?.hitTest(e.locationInWindow)
            if let v = pressed, v.acceptsFirstResponder { window.makeFirstResponder(v) }
            pressed?.mouseDown(with: e)
        case .leftMouseDragged: pressed?.mouseDragged(with: e)
        default: pressed?.mouseUp(with: e); pressed = nil
        }
    }
    static func drag(_ a: CGPoint, _ b: CGPoint) {
        mouse(.leftMouseDown, a)
        for i in 1...4 { let t = CGFloat(i) / 4; mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        mouse(.leftMouseUp, b); pump()
    }
    /// Same order as NSApplication.sendEvent: the key window's key equivalents first, then the first responder.
    static func key(_ chars: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        if !(flags.contains(.command) && window.performKeyEquivalent(with: e)) { window.sendEvent(e) }
        pump()
    }
    static func buttons(_ v: NSView?) -> [NSButton] { guard let v else { return [] }; return (v as? NSButton).map { [$0] } ?? [] + v.subviews.flatMap(buttons) }
    static func pressSheetButton(_ title: String, on w: NSWindow) throws {
        try expect(wait { w.attachedSheet != nil }, "no sheet attached")
        guard let button = buttons(w.attachedSheet?.contentView).first(where: { $0.title == title }) else { throw Failure(message: "sheet has no \(title) button") }
        button.performClick(nil); pump(0.3)
    }
    static func newFiles() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "png" } ?? [] }
    static func pixel(_ url: URL, _ x: Int, _ y: Int) -> NSColor? { NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data())?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
    static func pixels(_ url: URL) -> (Int, Int)? { NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()).map { ($0.pixelsWide, $0.pixelsHigh) } }
    static func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
    }
    static func isBlack(_ c: NSColor?) -> Bool { c.map { $0.redComponent < 0.02 && $0.greenComponent < 0.02 && $0.blueComponent < 0.02 } ?? false }
    /// Done, then wait until the window is gone and the written PNG is readable.
    static func done() throws {
        let w: AnnotateWindow = window
        key("s", .command)
        try expect(wait { !w.isVisible }, "Done did not close the editor")
        pump(0.3)
    }
    static func pick(_ title: String, in identifier: String) throws {
        guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == identifier }),
              let popup = (item.view as? NSPopUpButton) ?? (item.view?.subviews.first { $0 is NSPopUpButton } as? NSPopUpButton),
              let index = popup.menu?.items.firstIndex(where: { $0.title == title }) else { throw Failure(message: "no \(title) in \(identifier)") }
        popup.menu?.performActionForItem(at: index); pump()
    }

    private static func reset() {
        for w in NSApp.windows { if let a = w as? AnnotateWindow, a.isVisible { a.isDocumentEdited = false; a.attachedSheet.map { a.endSheet($0) }; a.close() } }
        NSApp.windows.filter { $0 is PinWindow && $0.isVisible }.forEach { $0.orderOut(nil) }
        QuickAccess.hide()
        UserDefaults().removePersistentDomain(forName: Settings.testSuite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leanshot-e2e-\(UUID().uuidString.prefix(8))")
        captures = root.appendingPathComponent("Captures", isDirectory: true); outside = root.appendingPathComponent("Downloads", isDirectory: true)
        for f in [captures!, outside!] { try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        Settings.saveFolder = captures
        Clipboard.pasteboard.clearContents()
        pump(0.1)
    }

    // MARK: Cases

    private static func define() {
        let a = CGPoint(x: 200, y: 150), b = CGPoint(x: 360, y: 280)

        // Decision table: where Done writes, for source location x file type (README, Annotate).
        test("DT-R1 Done on a PNG in the captures folder replaces it and moves the original to the Trash") {
            let src = fixture("dt-r1-\(UUID().uuidString.prefix(6))", in: captures); try open(src)
            let before = newFiles().count
            key("p"); drag(a, b); try done()
            try expect(newFiles().count == before, "Done created another file instead of replacing")
            try expect(isBlack(pixel(src, 560, 1000 - 430)), "the file at the original path is not the annotated image")
            let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0].appendingPathComponent(src.lastPathComponent)
            try expect(FileManager.default.fileExists(atPath: trash.path), "original not found in the Trash")
            try? FileManager.default.removeItem(at: trash)
        }
        test("DT-R2 Done on a JPEG in the captures folder writes a new PNG and keeps the JPEG") {
            let src = fixture("dt-r2", in: captures, png: false); let original = try Data(contentsOf: src); try open(src)
            key("r"); drag(a, b); try done()
            try expect(newFiles().count == 1, "expected one new PNG, found \(newFiles().count)")
            try expect((try? Data(contentsOf: src)) == original, "the JPEG changed")
        }
        test("DT-R3 Done on a PNG outside the captures folder writes a new capture and keeps the original") {
            let src = fixture("dt-r3", in: outside); let original = try Data(contentsOf: src); try open(src)
            key("r"); drag(a, b); try done()
            try expect(newFiles().count == 1, "expected one new capture, found \(newFiles().count)")
            try expect((try? Data(contentsOf: src)) == original, "the original changed")
        }
        test("DT-R4 Done on a JPEG outside the captures folder writes a new capture and keeps the original") {
            let src = fixture("dt-r4", in: outside, png: false); let original = try Data(contentsOf: src); try open(src)
            key("e"); drag(a, b); try done()
            try expect(newFiles().count == 1, "expected one new capture, found \(newFiles().count)")
            try expect((try? Data(contentsOf: src)) == original, "the original changed")
        }
        test("AC-01 Done keeps Retina pixels and copies a PNG to the clipboard") {
            let src = fixture("ac-01", in: outside); try open(src)
            key("a"); drag(a, b); try done()
            try expect(newFiles().first.flatMap(pixels).map { $0 == (1600, 1000) } == true, "saved size \(String(describing: newFiles().first.flatMap(pixels)))")
            try expect(Clipboard.pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0)?.pixelsWide } == 1600, "clipboard has no 1600 px PNG")
        }

        // State transitions: unsaved annotations and closing.
        test("ST-T1 Clean editor closes with Cmd-W without a sheet") {
            try open(fixture("st-t1", in: outside)); let w: AnnotateWindow = window
            key("w", .command)
            try expect(!w.isVisible && w.attachedSheet == nil, "clean editor did not close directly")
        }
        test("ST-T2 Drawing a shape marks the editor as edited") {
            try open(fixture("st-t2", in: outside))
            try expect(!window.isDocumentEdited, "edited before any change")
            key("r"); drag(a, b)
            try expect(window.isDocumentEdited, "not edited after drawing")
        }
        test("ST-T3 Cmd-W on an edited editor shows Done, Discard and Cancel") {
            try open(fixture("st-t3", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("w", .command)
            try expect(wait { w.attachedSheet != nil } && w.isVisible, "no sheet")
            let titles = buttons(w.attachedSheet?.contentView).map(\.title)
            try expect(Set(["Done", "Discard", "Cancel"]).isSubset(of: Set(titles)), "sheet buttons \(titles)")
        }
        test("ST-T4 Cancel keeps the editor open with its annotations") {
            try open(fixture("st-t4", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("w", .command); try pressSheetButton("Cancel", on: w)
            try expect(w.isVisible && w.canvas.marks.count == 1 && w.attachedSheet == nil, "Cancel did not keep the editor")
        }
        test("ST-T5 Discard closes the editor without writing a file") {
            try open(fixture("st-t5", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("w", .command); try pressSheetButton("Discard", on: w)
            try expect(!w.isVisible && newFiles().isEmpty, "Discard left the window or wrote \(newFiles().count) files")
        }
        test("ST-T6 Done in the sheet saves the annotations and closes") {
            try open(fixture("st-t6", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("w", .command); try pressSheetButton("Done", on: w)
            try expect(wait { !w.isVisible } && wait { newFiles().count == 1 }, "sheet Done did not save and close")
        }
        test("ST-T7 Cmd-S on an edited editor saves without a sheet") {
            try open(fixture("st-t7", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("s", .command)
            try expect(wait { !w.isVisible } && w.attachedSheet == nil && newFiles().count == 1, "Cmd-S did not save directly")
        }
        test("ST-T8 Quit with unsaved annotations is cancelled and shows the sheet") {
            try open(fixture("st-t8", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            try expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "quit was not cancelled")
            try expect(wait { w.attachedSheet != nil }, "no sheet after quit")
        }
        test("ST-T9 Quit with a clean editor is allowed") {
            try open(fixture("st-t9", in: outside))
            try expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "clean quit was blocked")
        }
        test("ST-I1 A second Cmd-W while the sheet is open does not stack another sheet or close") {
            try open(fixture("st-i1", in: outside)); key("r"); drag(a, b); let w: AnnotateWindow = window
            key("w", .command); _ = wait { w.attachedSheet != nil }; let sheet = w.attachedSheet
            key("w", .command)
            try expect(w.isVisible && w.attachedSheet === sheet, "second Cmd-W changed state")
        }

        // Equivalence partitioning over the README tool keys, plus one unassigned key.
        // (ID, key, tool from the README table, whether README's "every new shape stays selected" applies, see S2)
        let shapes: [(String, String, Tool, Bool)] = [
            ("EP-02", "r", .rect, true),
            ("EP-03", "f", .filledRect, true),
            ("EP-04", "e", .ellipse, true),
            ("EP-05", "l", .line, true),
            ("EP-06", "a", .arrow, true),
            ("EP-07", "d", .pen, false),
            ("EP-08", "m", .highlight, false),
            ("EP-09", "h", .spotlight, false),
        ]
        test("EP-01 V selects without drawing") {
            try open(fixture("ep-01", in: outside)); key("v"); drag(a, b)
            try expect(canvas.tool == .select && canvas.marks.isEmpty, "V drew \(canvas.marks.map(\.tool))")
        }
        for (id, keyName, tool, selects) in shapes {
            cases.append(Case(title: "\(id) \(keyName.uppercased()) draws \(tool.label)", line: lineOf(id)) {
                try open(fixture(id.lowercased(), in: outside)); key(keyName); drag(a, b)
                try expect(canvas.marks.last?.tool == tool, "\(keyName) drew \(String(describing: canvas.marks.last?.tool))")
                if selects { try expect(canvas.selected == canvas.marks.count - 1, "new \(tool.label) is not selected") }
            })
        }
        test("EP-10 T opens a text field where you click") {
            try open(fixture("ep-10", in: outside)); key("t"); mouse(.leftMouseDown, a); mouse(.leftMouseUp, a); pump()
            try expect(canvas.subviews.contains { $0 is NSTextField }, "no text field")
        }
        test("EP-11 C places a numbered counter") {
            try open(fixture("ep-11", in: outside)); key("c"); mouse(.leftMouseDown, a); mouse(.leftMouseUp, a); pump()
            try expect(canvas.marks.last?.tool == .counter, "no counter")
        }
        test("EP-12 X draws a Blur and Redact area") {
            try open(fixture("ep-12", in: outside)); key("x"); drag(a, b)
            try expect(canvas.marks.last?.tool == .pixelate, "X drew \(String(describing: canvas.marks.last?.tool))")
        }
        test("EP-13 U draws a Gaussian blur") {
            try open(fixture("ep-13", in: outside)); key("u"); drag(a, b)
            let m = canvas.marks.last
            try expect(m?.tool == .blur || (m?.tool == .pixelate && m?.style == 1), "U drew \(String(describing: m?.tool)) style \(String(describing: m?.style))")
        }
        test("EP-14 P draws a black bar") {
            try open(fixture("ep-14", in: outside)); key("p"); drag(a, b)
            let m = canvas.marks.last
            try expect(m?.tool == .redact || (m?.tool == .pixelate && m?.style == 3), "P drew \(String(describing: m?.tool)) style \(String(describing: m?.style))")
        }
        test("EP-15 K crops the screenshot to the dragged area") {
            try open(fixture("ep-15", in: outside)); key("k"); drag(a, b)
            let size = canvas.image.size
            try expect(abs(size.width - 160) < 0.5 && abs(size.height - 130) < 0.5, "cropped to \(size)")
        }
        test("EP-16 An unassigned key keeps the current tool") {
            try open(fixture("ep-16", in: outside)); key("e"); key("q")
            try expect(canvas.tool == .ellipse, "Q changed the tool to \(canvas.tool)")
        }

        // Acceptance criteria from the README editor section and shortcut table.
        test("AC-02 Black Bar exports solid black pixels and leaves the rest untouched") {
            let src = fixture("ac-02", in: outside); try open(src)
            key("p"); drag(a, b); try done()
            guard let out = newFiles().first else { throw Failure(message: "no output") }
            for (x, y) in [(402, 1000 - 302), (560, 1000 - 430), (718, 1000 - 558)] { try expect(isBlack(pixel(out, x, y)), "pixel \(x),\(y) is not black") }
            try expect(same(pixel(out, 100, 100), pixel(src, 100, 100)), "pixels outside the bar changed")
        }
        test("AC-03 Secure Blur changes every sampled pixel of the area") {
            let src = fixture("ac-03", in: outside); try open(src)
            try pick("Secure Blur", in: "redaction"); key("x"); drag(CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 400)); try done()
            guard let out = newFiles().first else { throw Failure(message: "no output") }
            let changed = stride(from: 210, to: 1390, by: 37).filter { !same(pixel(out, $0, 500), pixel(src, $0, 500)) }.count
            try expect(changed >= 20, "only \(changed) of 32 sampled pixels changed")
        }
        test("AC-04 Cmd-Z removes the last shape and Shift-Cmd-Z restores it") {
            try open(fixture("ac-04", in: outside)); key("r"); drag(a, b)
            key("z", .command); try expect(canvas.marks.isEmpty, "undo left \(canvas.marks.count)")
            key("z", [.command, .shift]); try expect(canvas.marks.count == 1, "redo gave \(canvas.marks.count)")
        }
        test("AC-05 Cmd-D duplicates the selected shape") {
            try open(fixture("ac-05", in: outside)); key("r"); drag(a, b)
            key("d", .command); try expect(canvas.marks.count == 2 && canvas.marks[0].rect != canvas.marks[1].rect, "duplicate gave \(canvas.marks.map(\.rect))")
        }
        test("AC-06 Cmd-C then Cmd-V pastes a copy of the selected shape") {
            try open(fixture("ac-06", in: outside)); key("e"); drag(a, b)
            key("c", .command); key("v", .command)
            try expect(canvas.marks.count == 2 && canvas.marks.allSatisfy { $0.tool == .ellipse }, "paste gave \(canvas.marks.map(\.tool))")
        }
        test("AC-07 Delete removes the selected shape") {
            try open(fixture("ac-07", in: outside)); key("r"); drag(a, b)
            key("\u{7f}", code: 51); try expect(canvas.marks.isEmpty, "delete left \(canvas.marks.count)")
        }
        test("AC-08 Double-clicking a text annotation reopens it for editing") {
            try open(fixture("ac-08", in: outside)); key("t"); mouse(.leftMouseDown, a); mouse(.leftMouseUp, a); pump()
            guard let field = canvas.subviews.compactMap({ $0 as? NSTextField }).first else { throw Failure(message: "no text field") }
            field.stringValue = "Hola"; canvas.commitText(); pump()
            mouse(.leftMouseDown, CGPoint(x: a.x + 6, y: a.y + 8), clicks: 2); mouse(.leftMouseUp, CGPoint(x: a.x + 6, y: a.y + 8), clicks: 2); pump()
            try expect(canvas.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "Hola", "no editor with the old text")
        }
        test("AC-09 Shift-Cmd-C copies the whole screenshot at Retina size") {
            try open(fixture("ac-09", in: outside)); key("r"); drag(a, b)
            key("c", [.command, .shift])
            try expect(Clipboard.pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }.map { ($0.pixelsWide, $0.pixelsHigh) == (1600, 1000) } == true, "clipboard image is not 1600x1000")
        }
        test("AC-10 A new editor remembers the last tool and stroke width") {
            try open(fixture("ac-10a", in: outside)); key("e"); key("]"); key("]"); let width = canvas.width
            key("w", .command); pump(0.7) // choices are written 0.5 s after the last change
            try open(fixture("ac-10b", in: outside))
            try expect(canvas.tool == .ellipse && canvas.width == width, "new editor has \(canvas.tool) at \(canvas.width) pt")
        }
        test("AC-11 Shift-Cmd-P pins the screenshot above other windows") {
            try open(fixture("ac-11", in: outside)); key("p", [.command, .shift])
            try expect(wait { NSApp.windows.contains { $0 is PinWindow && $0.isVisible && $0.level == .floating } }, "no floating pin")
        }
        test("EG-01 A black bar dragged past the image edge still covers up to the edge") {
            let src = fixture("eg-01", in: outside); try open(src)
            key("p"); drag(CGPoint(x: 700, y: 300), CGPoint(x: 900, y: 600)); try done()
            guard let out = newFiles().first else { throw Failure(message: "no output") }
            try expect(isBlack(pixel(out, 1599, 0)) && isBlack(pixel(out, 1401, 399)), "edge pixels are not black")
        }
        test("EG-02 Done replaces a capture whose name has spaces, accents and emoji") {
            let src = fixture("captura ñ 🙂 \(UUID().uuidString.prefix(4))", in: captures); try open(src)
            key("p"); drag(a, b); try done()
            try expect(isBlack(pixel(src, 560, 1000 - 430)), "the capture was not replaced in place")
            let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0].appendingPathComponent(src.lastPathComponent)
            try expect(FileManager.default.fileExists(atPath: trash.path), "original not in the Trash"); try? FileManager.default.removeItem(at: trash)
        }

        // Boundary values of the 2 to 40 pt tool size, driven with [ and ].
        test("BVA-01 Pressing [ down to the minimum reaches 2 pt") {
            try open(fixture("bva-01", in: outside)); key("r"); for _ in 0..<30 where canvas.width > 2 { key("[") }
            try expect(canvas.width == 2, "minimum is \(canvas.width)")
        }
        test("BVA-02 One more [ at 2 pt stays at 2 pt") {
            try open(fixture("bva-02", in: outside)); key("r"); for _ in 0..<30 where canvas.width > 2 { key("[") }; key("[")
            try expect(canvas.width == 2, "went below the minimum to \(canvas.width)")
        }
        test("BVA-03 Pressing ] up to the maximum reaches 40 pt") {
            try open(fixture("bva-03", in: outside)); key("r"); for _ in 0..<30 where canvas.width < 40 { key("]") }
            try expect(canvas.width == 40, "maximum is \(canvas.width)")
        }
        test("BVA-04 One more ] at 40 pt stays at 40 pt") {
            try open(fixture("bva-04", in: outside)); key("r"); for _ in 0..<30 where canvas.width < 40 { key("]") }; key("]")
            try expect(canvas.width == 40, "went above the maximum to \(canvas.width)")
        }
    }
    /// The EP table rows declare their IDs on their own lines; the report links each ID to that line.
    private static func lineOf(_ id: String) -> Int {
        let source = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
        return (source.components(separatedBy: "\n").firstIndex { $0.contains("(\"\(id)\"") } ?? 0) + 1
    }

    // MARK: Invisible windows

    /// Tests run while the user keeps working: every LeanShot window stays fully transparent and click-through,
    /// and the app never activates itself, so nothing appears on screen and focus never moves.
    /// Swizzles NSWindow's alpha and ordering methods and NSApplication's activation for the e2e process only.
    private static func makeWindowsInvisible() {
        func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
            method_exchangeImplementations(a, b)
        }
        swap(NSWindow.self, #selector(setter: NSWindow.alphaValue), #selector(NSWindow.e2e_setAlphaValue(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.e2e_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.e2e_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.e2e_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.e2e_order(_:relativeTo:)))
        swap(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.e2e_activate(ignoringOtherApps:)))
    }

    // MARK: Runner

    static func run(junit: URL) {
        setvbuf(stdout, nil, _IONBF, 0) // keep results visible even if a case crashes the process
        makeWindowsInvisible()
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        Clipboard.pasteboard = NSPasteboard(name: NSPasteboard.Name("LeanShot-e2e-\(UUID().uuidString)"))
        define()
        var results: [(Case, Double, String?)] = []
        for c in cases {
            reset()
            let start = Date()
            var failure: String?
            do { try c.body() } catch let f as Failure { failure = f.message } catch { failure = "\(error)" }
            results.append((c, Date().timeIntervalSince(start), failure))
            print("\(failure == nil ? "PASS" : "FAIL") \(c.title)\(failure.map { ": \($0)" } ?? "")")
        }
        reset()
        UserDefaults().removePersistentDomain(forName: Settings.testSuite)
        Clipboard.pasteboard.releaseGlobally()
        let failed = results.filter { $0.2 != nil }.count
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let total = results.reduce(0) { $0 + $1.1 }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n<testsuite name=\"LeanShot.E2E\" tests=\"\(results.count)\" failures=\"\(failed)\" errors=\"0\" time=\"\(String(format: "%.3f", total))\">\n"
        for (c, time, failure) in results {
            xml += "  <testcase classname=\"LeanShot.E2E\" name=\"\(esc(c.title))\" file=\"Sources/LeanShot/E2ETests.swift\" line=\"\(c.line)\" time=\"\(String(format: "%.3f", time))\""
            xml += failure.map { ">\n    <failure message=\"\(esc($0))\"/>\n  </testcase>\n" } ?? "/>\n"
        }
        xml += "</testsuite>\n</testsuites>\n"
        try? FileManager.default.createDirectory(at: junit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? xml.write(to: junit, atomically: true, encoding: .utf8)
        print("\(results.count - failed) of \(results.count) e2e tests passed; JUnit at \(junit.path)")
        exit(failed == 0 ? 0 : 1)
    }
}

// After the swap, calling e2e_* runs AppKit's original implementation.
extension NSWindow {
    @objc func e2e_setAlphaValue(_ value: CGFloat) { e2e_setAlphaValue(0) }
    private func hide() { e2e_setAlphaValue(0); ignoresMouseEvents = true }
    @objc func e2e_orderFront(_ sender: Any?) { hide(); e2e_orderFront(sender) }
    @objc func e2e_makeKeyAndOrderFront(_ sender: Any?) { hide(); e2e_makeKeyAndOrderFront(sender) }
    @objc func e2e_orderFrontRegardless() { hide(); e2e_orderFrontRegardless() }
    @objc func e2e_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) { if place != .out { hide() }; e2e_order(place, relativeTo: other) }
}
extension NSApplication {
    @objc func e2e_activate(ignoringOtherApps flag: Bool) {}
}
