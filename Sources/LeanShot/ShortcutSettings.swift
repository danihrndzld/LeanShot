import AppKit
import Carbon

final class ShortcutSettings: NSWindow, NSWindowDelegate {
    private static var instance: ShortcutSettings?
    private var recorders: [ShortcutRecorder] = []
    static func show() {
        let window = instance ?? ShortcutSettings(); instance = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"; isReleasedWhenClosed = false; delegate = self
        let names: [(String, Int)] = [("All-in-One", kVK_ANSI_1), ("Capture Area", kVK_ANSI_4), ("Capture Window", kVK_ANSI_5), ("Capture Fullscreen", kVK_ANSI_3), ("Capture Text / QR", kVK_ANSI_2), ("Record Screen", kVK_ANSI_6)]
        for (i, (name, code)) in names.enumerated() {
            let y = 284 - i * 42
            let label = NSTextField(labelWithString: name); label.frame = NSRect(x: 24, y: y + 4, width: 200, height: 24); contentView?.addSubview(label)
            let recorder = ShortcutRecorder(code: UInt32(code)); recorder.frame = NSRect(x: 230, y: y, width: 246, height: 32)
            contentView?.addSubview(recorder); recorders.append(recorder)
        }
        let help = NSTextField(labelWithString: "Click a shortcut, then press a combination with ⌘, ⌃ or ⌥.")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor; help.frame = NSRect(x: 24, y: 20, width: 452, height: 20); contentView?.addSubview(help)
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { recorders.forEach { $0.stop() } }
}

private final class ShortcutRecorder: NSButton {
    private static weak var active: ShortcutRecorder?
    private let code: UInt32
    private var monitor: Any?
    init(code: UInt32) {
        self.code = code
        super.init(frame: .zero); bezelStyle = .rounded; title = Hotkeys.label(code)
        target = self; action = #selector(record); toolTip = "Record a new global shortcut"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func record() {
        Self.active?.stop(); Self.active = self; Hotkeys.suspend(); title = "Press shortcut… Esc to cancel"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            if Hotkeys.rebind(self.code, event: event) { self.stop() } else { NSSound.beep() }
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil; Hotkeys.resume() }
        title = Hotkeys.label(code); if Self.active === self { Self.active = nil }
    }
}
