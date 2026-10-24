import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastCapture: URL? = CaptureHistory.files().first(where: Thumbnail.isImage)
    private var recordItem: NSMenuItem?
    private var quitAfterRecording = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved annotations: show the editor's own Save / Discard sheet instead of quitting.
        if let edited = NSApp.windows.first(where: { $0 is AnnotateWindow && $0.isDocumentEdited && $0.isVisible }) {
            NSApp.activate(ignoringOtherApps: true); edited.makeKeyAndOrderFront(nil); edited.performClose(nil); return .terminateCancel
        }
        if #available(macOS 15.0, *), Recorder.shared.busy {
            if Recorder.shared.stopForTermination({ NSApp.reply(toApplicationShouldTerminate: $0) }) { return .terminateLater }
            Toast.show("Wait for recording startup or saving to finish before quitting"); return .terminateCancel
        }
        if let process = Capture.current, process.arguments?.contains("-v") == true {
            guard process.isRunning else { return .terminateCancel }
            quitAfterRecording = true; process.interrupt(); return .terminateLater
        }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let commands: [String: Selector] = ["capture": #selector(captureArea), "area": #selector(captureArea), "window": #selector(captureWindow), "fullscreen": #selector(captureFullscreen), "text": #selector(captureText), "record": #selector(recordScreen), "all-in-one": #selector(allInOne), "history": #selector(history), "restore": #selector(restoreOverlay)]
        for url in urls {
            if url.scheme == "leanshot", let host = url.host, let action = commands[host] { perform(action) }
            else if url.isFileURL {
                if ["mp4", "mov"].contains(url.pathExtension.lowercased()) { VideoEditor.open(url) }
                else { AnnotateWindow.open(url) }
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "LeanShot")

        let menu = NSMenu()
        // Default macOS shortcuts (⌘⇧3/4/5) belong to the system, so LeanShot uses ⌃⇧.
        let items: [(String, UInt32, String, Selector)] = [
            ("All-in-One…", UInt32(kVK_ANSI_1), "1", #selector(allInOne)),
            ("Capture Area", UInt32(kVK_ANSI_4), "4", #selector(captureArea)),
            ("Capture Window", UInt32(kVK_ANSI_5), "5", #selector(captureWindow)),
            ("Capture Fullscreen", UInt32(kVK_ANSI_3), "3", #selector(captureFullscreen)),
            ("Capture Text (OCR)", UInt32(kVK_ANSI_2), "2", #selector(captureText)),
            ("Record Screen", UInt32(kVK_ANSI_6), "6", #selector(recordScreen)),
        ]
        for (title, keyCode, key, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .shift]
            item.target = self
            menu.addItem(item)
            if action == #selector(recordScreen) { recordItem = item }
            item.tag = Int(keyCode)
            Hotkeys.register(keyCode: keyCode, modifiers: UInt32(controlKey | shiftKey), key: key) { [weak self] in
                self?.perform(action)
            }
            if let shortcut = Hotkeys.display(keyCode) { item.keyEquivalent = shortcut.key; item.keyEquivalentModifierMask = shortcut.flags }
            else { item.keyEquivalent = "" } // taken by another app: show no shortcut rather than a dead one
        }
        let taken = items.filter { Hotkeys.unavailable($0.1) }.map(\.0)
        if !taken.isEmpty { Toast.show("Another app uses the shortcut for \(taken.joined(separator: ", ")). Pick a new one in Settings → Shortcuts.", symbol: "keyboard") }
        menu.addItem(.separator())
        for (index, (title, action)) in [("Capture Area in 5 s", #selector(captureAreaTimer)),
                                ("Annotate Last Capture", #selector(annotateLast)),
                                ("Pin Last Capture", #selector(pinLast)),
                                ("Unlock Floating Screenshots", #selector(unlockPins)),
                                ("Restore Quick Access", #selector(restoreOverlay)),
                                ("Hide Quick Access", #selector(hideOverlay)),
                                ("Capture History…", #selector(history)),
                                ("Capture Frozen Area…", #selector(captureFrozen)),
                                ("Scrolling Capture (Vertical)…", #selector(scrollVertical)),
                                ("Scrolling Capture (Horizontal)…", #selector(scrollHorizontal)),
                                ("Record Area…", #selector(recordArea)),
                                ("Record Window…", #selector(recordWindow)),
                                ("Open Image…", #selector(openImage)),
                                ("Settings…", #selector(settings)),
                                ("Keyboard Shortcuts…", #selector(shortcuts)),
                                ("Open Captures Folder", #selector(openFolder))].enumerated() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            // Every other action can get a global shortcut in Settings → Shortcuts; none is set by default.
            guard ![#selector(settings), #selector(shortcuts)].contains(action) else { continue }
            let id = Hotkeys.extraBase + UInt32(index)
            item.tag = Int(id); AppDelegate.extraShortcuts.append((title.replacingOccurrences(of: "…", with: ""), id))
            Hotkeys.register(keyCode: id, modifiers: 0, key: "", optional: true) { [weak self] in self?.perform(action) }
            if let shortcut = Hotkeys.display(id) { item.keyEquivalent = shortcut.key; item.keyEquivalentModifierMask = shortcut.flags }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LeanShot", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        let symbols = ["All-in-One…": "rectangle.dashed.badge.record", "Capture Area": "rectangle.dashed", "Capture Window": "macwindow", "Capture Fullscreen": "display",
                       "Capture Text (OCR)": "text.viewfinder", "Record Screen": "record.circle", "Capture Area in 5 s": "timer", "Annotate Last Capture": "pencil.tip.crop.circle",
                       "Pin Last Capture": "pin", "Unlock Floating Screenshots": "lock.open", "Restore Quick Access": "rectangle.stack", "Hide Quick Access": "eye.slash",
                       "Capture History…": "clock.arrow.circlepath", "Capture Frozen Area…": "snowflake", "Scrolling Capture (Vertical)…": "arrow.down.doc",
                       "Scrolling Capture (Horizontal)…": "arrow.left.and.right.text.vertical", "Record Area…": "rectangle.dashed.badge.record", "Record Window…": "macwindow.badge.plus",
                       "Open Image…": "photo", "Settings…": "gearshape", "Keyboard Shortcuts…": "keyboard", "Open Captures Folder": "folder", "Quit LeanShot": "power"]
        for item in menu.items { item.image = symbols[item.title].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.title) } }
        statusItem.menu = menu
        Hotkeys.onChange = { [weak self] in
            for item in self?.statusItem.menu?.items ?? [] {
                guard item.tag > 0 else { continue }
                if let shortcut = Hotkeys.display(UInt32(item.tag)) { item.keyEquivalent = shortcut.key; item.keyEquivalentModifierMask = shortcut.flags }
                else { item.keyEquivalent = "" }
            }
        }
        if #available(macOS 15.0, *) {
            Recorder.shared.onStatus = { [weak self] status in
                guard let self else { return }
                self.statusItem.length = status == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
                self.statusItem.button?.title = status ?? ""
                self.statusItem.button?.image = NSImage(systemSymbolName: status == nil ? "camera.viewfinder" : "record.circle", accessibilityDescription: status == nil ? "LeanShot" : "Recording")
                self.recordItem?.title = status == nil ? "Record Screen" : "Stop Recording"
                self.recordItem?.image = NSImage(systemSymbolName: status == nil ? "record.circle" : "stop.circle", accessibilityDescription: self.recordItem?.title)
            }
        }

        // Editor windows make LeanShot a regular app (Dock + ⌘-Tab); it returns to menu-bar only when they close.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { AppDelegate.updateActivationPolicy() }
            }
        }
        NSApp.mainMenu = AppDelegate.mainMenu()
        ImageTools.warmUp()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    /// Menu actions without a default shortcut that users may bind: (title, hotkey id).
    static var extraShortcuts: [(String, UInt32)] = []

    static func updateActivationPolicy() {
        let documents = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = documents ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Shown only while an editor makes the app regular; Edit gives text fields ⌘C/⌘V.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [(String, Selector?, String)]) {
            let menu = NSMenu(title: title)
            for (name, action, key) in items { if name.isEmpty { menu.addItem(.separator()) } else { menu.addItem(withTitle: name, action: action, keyEquivalent: key) } }
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        add("LeanShot", [("About LeanShot", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), ("", nil, ""),
                         ("Settings…", #selector(AppDelegate.settings), ","), ("", nil, ""),
                         ("Hide LeanShot", #selector(NSApplication.hide(_:)), "h"), ("Quit LeanShot", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                     ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), ("Close", #selector(NSWindow.performClose(_:)), "w")])
        return main
    }

    @objc func captureArea() { shoot(["-i", "-s"]) }
    @objc func allInOne() {
        let modes: [(String, Selector)] = [("Frozen Area (remember selection)", #selector(captureFrozen)), ("Area", #selector(captureArea)), ("Window", #selector(captureWindow)), ("Fullscreen", #selector(captureFullscreen)), ("Text / QR Code", #selector(captureText)), ("Scrolling (Vertical)", #selector(scrollVertical)), ("Scrolling (Horizontal)", #selector(scrollHorizontal)), ("Record Display", #selector(recordScreen)), ("Record Area", #selector(recordArea)), ("Record Window", #selector(recordWindow))]
        let alert = NSAlert(); alert.messageText = "LeanShot"; alert.informativeText = "Choose a capture mode"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30)); picker.addItems(withTitles: modes.map(\.0))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.addArrangedSubview(picker); stack.addArrangedSubview(NSTextField(labelWithString: "Optional frozen-area dimensions (points)"))
        let row = NSStackView(); let width = NSTextField(string: ""); let height = NSTextField(string: "")
        width.placeholderString = "Width"; height.placeholderString = "Height"
        for field in [width, height] { field.widthAnchor.constraint(equalToConstant: 130).isActive = true; row.addArrangedSubview(field) }
        stack.addArrangedSubview(row); stack.frame = NSRect(x: 0, y: 0, width: 320, height: 100); alert.accessoryView = stack
        let aspect = NSPopUpButton(); aspect.addItems(withTitles: ["Free aspect", "Square 1:1", "Landscape 16:9", "4:3", "Portrait 9:16"])
        stack.addArrangedSubview(aspect); stack.frame.size.height = 140
        alert.addButton(withTitle: "Capture"); alert.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if picker.indexOfSelectedItem == 0, !width.stringValue.isEmpty || !height.stringValue.isEmpty {
                guard let w = Double(width.stringValue), let h = Double(height.stringValue), w.isFinite, h.isFinite, w >= 3, h >= 3 else { return Toast.show("Enter a valid width and height of at least 3 points") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.captureFrozenSize(CGSize(width: w, height: h)) }; return
            }
            if picker.indexOfSelectedItem == 0 {
                let ratio = [0.0, 1, 16.0 / 9, 4.0 / 3, 9.0 / 16][aspect.indexOfSelectedItem]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.captureFrozenSize(nil, aspect: ratio) }; return
            }
            let action = modes[picker.indexOfSelectedItem].1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.perform(action) }
        }
    }
    @objc func captureWindow() { shoot(["-i", "-w"] + (Settings.windowShadow ? [] : ["-o"])) }
    @objc func captureFullscreen() { shoot([]) }
    /// Select first, then a visible 5…1 countdown, then capture: time to open a menu or hover a button.
    @objc func captureAreaTimer() {
        RegionSelector.choose { [weak self] region, _ in
            guard let region else { return }
            for n in 0..<5 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(n)) { Toast.show("Capturing in \(5 - n)…", symbol: "timer") } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let r = region.globalRect
                self?.shoot(["-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"])
            }
        }
    }
    @objc func recordScreen() {
        if #available(macOS 15.0, *) {
            if Recorder.shared.busy { Recorder.shared.stop() }
            else { Recorder.shared.startDisplay { [weak self] in self?.recordingFinished($0) } }
            return
        }
        if let p = Capture.current {
            if p.isRunning, p.arguments?.contains("-v") == true { p.interrupt() } else { NSSound.beep() }
            return
        }
        recordItem?.title = "Stop Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording")
        shoot(["-v", "-D", "1"], ext: "mov") { [weak self] in
            self?.recordItem?.title = "Record Screen"
            self?.statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "LeanShot")
            if self?.quitAfterRecording == true { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
    @objc func recordArea() {
        guard #available(macOS 15.0, *) else { return Toast.show("Area recording requires macOS 15+") }
        guard !Recorder.shared.busy else { return NSSound.beep() }
        RegionSelector.choose { [weak self] region, _ in
            if let region { Recorder.shared.startDisplay(region: region) { [weak self] in self?.recordingFinished($0) } }
        }
    }
    @objc func scrollVertical() { ScrollingSession.start(horizontal: false) }
    @objc func scrollHorizontal() { ScrollingSession.start(horizontal: true) }
    @objc func recordWindow() {
        if #available(macOS 15.0, *) { Recorder.shared.chooseWindow { [weak self] in self?.recordingFinished($0) } }
        else { Toast.show("Window recording requires macOS 15+") }
    }
    private func recordingFinished(_ url: URL?) {
        guard let url else { return }; lastCapture = url; QuickAccess.show(url)
    }
    @objc func captureFrozen() {
        captureFrozenSize(nil)
    }
    private func captureFrozenSize(_ size: CGSize?, aspect: CGFloat = 0) {
        RegionSelector.choose(size: size, aspect: aspect) { [weak self] _, image in
            guard let image, let data = ImageTools.png(image) else { return }
            let url = Capture.newURL("png")
            do { try data.write(to: url, options: .atomic); self?.lastCapture = url; if Settings.copyOnCapture { Clipboard.copy(url) }; QuickAccess.show(url) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    @objc func captureText() {
        Capture.run(["-i", "-s"], to: Capture.tempURL("png")) { url in
            guard let url, let image = NSImage(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            OCR.recognize(image) { text in
                guard !text.isEmpty else { return Toast.show("No text found") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
            }
        }
    }

    @objc func annotateLast() {
        guard let url = lastCapture else { return Toast.show("No captures yet") }
        if Thumbnail.isImage(url) { AnnotateWindow.open(url) } else { VideoEditor.open(url) }
    }
    @objc func pinLast() { if let url = lastCapture, let image = NSImage(contentsOf: url) { PinWindow.pin(image) } }
    @objc func openFolder() { NSWorkspace.shared.open(Capture.folder) }
    @objc func restoreOverlay() { QuickAccess.restore() }
    @objc func unlockPins() { PinWindow.unlockAll() }
    @objc func hideOverlay() { QuickAccess.hide() }
    @objc func history() { HistoryWindow.show() }
    @objc func settings() { SettingsWindow.show() }
    @objc func shortcuts() { ShortcutSettings.show() }
    @objc func openImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { AnnotateWindow.open(url) }
    }

    private func shoot(_ args: [String], ext: String = "png", finished: (() -> Void)? = nil) {
        // Without the grant screencapture silently saves only the wallpaper.
        guard CGPreflightScreenCaptureAccess() else { Permissions.explain(CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission declined"])); return }
        QuickAccess.hide() // restore older thumbnails once capture finishes
        let started = Capture.run(args + (Settings.captureCursor && ext == "png" ? ["-C"] : []), to: Capture.newURL(ext)) { [weak self] url in
            finished?()
            QuickAccess.resume()
            guard let url else { return }
            self?.lastCapture = url
            if Settings.copyOnCapture { Clipboard.copy(url) }
            QuickAccess.show(url)
        }
        if !started { finished?() }
    }
}

enum Hotkeys {
    private struct Binding {
        var code: UInt32; var modifiers: UInt32; var key: String; var ref: EventHotKeyRef?; var id: UInt32
        var failed = false // another app owns the combination; the menu must not show it as live
        var unset = false // no shortcut: optional actions start here, and ⌫ in the recorder returns here
    }
    static let extraBase: UInt32 = 1000
    /// Stored in place of a key code when the user cleared a shortcut.
    private static let cleared = UInt32.max
    static func unavailable(_ defaultCode: UInt32) -> Bool { bindings[defaultCode]?.failed ?? false }
    private static var bindings: [UInt32: Binding] = [:]
    static var onChange: (() -> Void)?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var suspended = false

    static func register(keyCode: UInt32, modifiers: UInt32, key: String, optional: Bool = false, _ handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { if !Hotkeys.suspended { Hotkeys.handlers[id.id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        let stored = Settings.defaults.object(forKey: Settings.hotkeyKey(keyCode, .code)) as? UInt32
        guard (stored ?? (optional ? cleared : keyCode)) != cleared else {
            bindings[keyCode] = Binding(code: 0, modifiers: 0, key: "", ref: nil, id: id, unset: true); return
        }
        let code = stored ?? keyCode
        let mods = Settings.defaults.object(forKey: Settings.hotkeyKey(keyCode, .modifiers)) as? UInt32 ?? modifiers
        let character = Settings.defaults.string(forKey: Settings.hotkeyKey(keyCode, .key)) ?? key
        var binding = Binding(code: code, modifiers: mods, key: character, ref: nil, id: id)
        binding.failed = activate(&binding) != noErr; bindings[keyCode] = binding
    }
    private static func activate(_ binding: inout Binding) -> OSStatus {
        RegisterEventHotKey(binding.code, binding.modifiers, EventHotKeyID(signature: OSType(0x4C53_4854), id: binding.id), GetApplicationEventTarget(), 0, &binding.ref)
    }
    static func display(_ defaultCode: UInt32) -> (key: String, flags: NSEvent.ModifierFlags)? {
        guard let binding = bindings[defaultCode], !binding.failed, !binding.unset else { return nil }
        var flags = NSEvent.ModifierFlags()
        for (carbon, cocoa) in [(cmdKey, NSEvent.ModifierFlags.command), (controlKey, .control), (optionKey, .option), (shiftKey, .shift)] {
            if binding.modifiers & UInt32(carbon) != 0 { flags.insert(cocoa) }
        }
        return (binding.key, flags)
    }
    static func label(_ defaultCode: UInt32) -> String {
        if bindings[defaultCode]?.unset == true { return "None" }
        guard let value = display(defaultCode) else { return "Unavailable" }
        let f = value.flags
        return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + (value.key == " " ? "Space" : value.key.uppercased())
    }
    static func suspend() {
        suspended = true
        for code in Array(bindings.keys) { if let ref = bindings[code]?.ref { UnregisterEventHotKey(ref); bindings[code]?.ref = nil } }
    }
    static func resume() {
        for code in Array(bindings.keys) { if var binding = bindings[code], binding.ref == nil, !binding.unset { binding.failed = activate(&binding) != noErr; bindings[code] = binding } }
        suspended = false
    }
    static func clear(_ defaultCode: UInt32) {
        guard var binding = bindings[defaultCode] else { return }
        if let ref = binding.ref { UnregisterEventHotKey(ref) }
        binding.ref = nil; binding.unset = true; binding.failed = false; bindings[defaultCode] = binding
        Settings.defaults.set(cleared, forKey: Settings.hotkeyKey(defaultCode, .code)); onChange?()
    }
    static func rebind(_ defaultCode: UInt32, event: NSEvent) -> Bool {
        guard var original = bindings[defaultCode], let key = event.charactersIgnoringModifiers, !key.isEmpty else { return false }
        let f = event.modifierFlags
        var modifiers: UInt32 = 0
        for (carbon, cocoa) in [(cmdKey, NSEvent.ModifierFlags.command), (controlKey, .control), (optionKey, .option), (shiftKey, .shift)] {
            if f.contains(cocoa) { modifiers |= UInt32(carbon) }
        }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { return false }
        if bindings.contains(where: { $0.key != defaultCode && !$0.value.unset && $0.value.code == UInt32(event.keyCode) && $0.value.modifiers == modifiers }) { Toast.show("Another LeanShot action already uses that shortcut"); return false }
        let wasRegistered = original.ref != nil
        if let ref = original.ref { UnregisterEventHotKey(ref); original.ref = nil }
        var updated = Binding(code: UInt32(event.keyCode), modifiers: modifiers, key: key.lowercased(), ref: nil, id: original.id)
        guard activate(&updated) == noErr else { if wasRegistered { _ = activate(&original) }; bindings[defaultCode] = original; Toast.show("That shortcut is already in use"); return false }
        bindings[defaultCode] = updated
        Settings.defaults.set(updated.code, forKey: Settings.hotkeyKey(defaultCode, .code)); Settings.defaults.set(updated.modifiers, forKey: Settings.hotkeyKey(defaultCode, .modifiers)); Settings.defaults.set(updated.key, forKey: Settings.hotkeyKey(defaultCode, .key))
        onChange?(); return true
    }
}

if CommandLine.arguments.contains("--bench") { Bench.run() }
if CommandLine.arguments.contains("--selftest") {
    do { try EditorTests.run() } catch { fatalError("Regression tests: \(error)") }
    var videoTestsFinished = false
    Task { @MainActor in
        do { try await EditorTests.runVideo() } catch { fatalError("Video regression: \(error)") }
        videoTestsFinished = true
    }
    while !videoTestsFinished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--overlay-preview"), CommandLine.arguments.count > i + 2 {
    app.setActivationPolicy(.accessory)
    QuickAccess.preview(URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > i + 2 {
    app.setActivationPolicy(.accessory)
    AnnotateWindow.preview(URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--settings-preview"), CommandLine.arguments.count > i + 2 {
    app.setActivationPolicy(.accessory)
    SettingsWindow.preview(tab: Int(CommandLine.arguments[i + 1]) ?? 0, to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
