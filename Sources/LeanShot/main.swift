import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastCapture: URL?
    private var recordItem: NSMenuItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "LeanShot")

        let menu = NSMenu()
        // Default macOS shortcuts (⌘⇧3/4/5) belong to the system, so LeanShot uses ⌃⇧.
        let items: [(String, UInt32, String, Selector)] = [
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
                                ("Open Captures Folder", #selector(openFolder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LeanShot", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    @objc func captureArea() { shoot(["-i", "-s"]) }
    @objc func captureWindow() { shoot(["-i", "-w"]) }
    @objc func captureFullscreen() { shoot([]) }
    @objc func captureAreaTimer() { shoot(["-i", "-s", "-T", "5"]) }
    /// Toggle. screencapture rejects -v with -i, so this records the whole main display.
    // ponytail: full-screen only; region recording needs SCStream + SCRecordingOutput.
    @objc func recordScreen() {
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

    private func shoot(_ args: [String], ext: String = "png", finished: (() -> Void)? = nil) {
        QuickAccess.dismiss() // keep the overlay out of the next shot
        let started = Capture.run(args, to: Capture.newURL(ext)) { [weak self] url in
            finished?()
            guard let url else { return }
            self?.lastCapture = url
            Clipboard.copy(url)
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
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > i + 2 {
    app.setActivationPolicy(.accessory)
    AnnotateWindow.preview(URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
