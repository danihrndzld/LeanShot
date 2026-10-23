import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastCapture: URL? = CaptureHistory.files().first { NSImage(contentsOf: $0) != nil }
    private var recordItem: NSMenuItem?

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
            Hotkeys.register(keyCode: keyCode, modifiers: UInt32(controlKey | shiftKey)) { [weak self] in
                self?.perform(action)
            }
        }
        menu.addItem(.separator())
        for (title, action) in [("Capture Area in 5 s", #selector(captureAreaTimer)),
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
                                ("Open Captures Folder", #selector(openFolder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LeanShot", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        if #available(macOS 15.0, *) {
            Recorder.shared.onStatus = { [weak self] status in
                guard let self else { return }
                self.statusItem.length = status == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
                self.statusItem.button?.title = status ?? ""
                self.statusItem.button?.image = NSImage(systemSymbolName: status == nil ? "camera.viewfinder" : "record.circle", accessibilityDescription: status == nil ? "LeanShot" : "Recording")
                self.recordItem?.title = status == nil ? "Record Screen" : "Stop Recording"
            }
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    @objc func captureArea() { shoot(["-i", "-s"]) }
    @objc func allInOne() {
        let modes: [(String, Selector)] = [("Frozen Area (remember selection)", #selector(captureFrozen)), ("Area", #selector(captureArea)), ("Window", #selector(captureWindow)), ("Fullscreen", #selector(captureFullscreen)), ("Text / QR Code", #selector(captureText)), ("Scrolling (Vertical)", #selector(scrollVertical)), ("Scrolling (Horizontal)", #selector(scrollHorizontal)), ("Record Display", #selector(recordScreen)), ("Record Area", #selector(recordArea)), ("Record Window", #selector(recordWindow))]
        let alert = NSAlert(); alert.messageText = "LeanShot"; alert.informativeText = "Choose a capture mode"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30)); picker.addItems(withTitles: modes.map(\.0)); alert.accessoryView = picker
        alert.addButton(withTitle: "Capture"); alert.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let action = modes[picker.indexOfSelectedItem].1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.perform(action) }
        }
    }
    @objc func captureWindow() { shoot(["-i", "-w"] + (Settings.windowShadow ? [] : ["-o"])) }
    @objc func captureFullscreen() { shoot([]) }
    @objc func captureAreaTimer() { shoot(["-i", "-s", "-T", "5"]) }
    /// Toggle. screencapture rejects -v with -i, so this records the whole main display.
    // ponytail: full-screen only; region recording needs SCStream + SCRecordingOutput.
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
        RegionSelector.choose { [weak self] _, image in
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
                Toast.show("Copied \(text.count) characters")
            }
        }
    }

    @objc func annotateLast() { if let url = lastCapture { AnnotateWindow.open(url) } }
    @objc func pinLast() { if let url = lastCapture, let image = NSImage(contentsOf: url) { PinWindow.pin(image) } }
    @objc func openFolder() { NSWorkspace.shared.open(Capture.folder) }
    @objc func restoreOverlay() { QuickAccess.restore() }
    @objc func unlockPins() { PinWindow.unlockAll() }
    @objc func hideOverlay() { QuickAccess.hide() }
    @objc func history() { HistoryWindow.show() }
    @objc func settings() { SettingsWindow.show() }
    @objc func openImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .data]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { AnnotateWindow.open(url) }
    }

    private func shoot(_ args: [String], ext: String = "png", finished: (() -> Void)? = nil) {
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
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { Hotkeys.handlers[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4C53_4854), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("LeanShot: hotkey \(keyCode) unavailable (\(status))") }
    }
}

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
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
