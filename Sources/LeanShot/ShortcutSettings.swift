import AppKit
import Carbon

enum ShortcutSettings {
    static func show() { SettingsWindow.show(tab: 4) }
    static func stopRecording() { ShortcutRecorder.active?.stop() }
    static func pane() -> NSView {
        let names: [(String, Int)] = [("All-in-One", kVK_ANSI_1), ("Capture Area", kVK_ANSI_4), ("Capture Window", kVK_ANSI_5), ("Capture Fullscreen", kVK_ANSI_3), ("Capture Text / QR", kVK_ANSI_2), ("Record Screen", kVK_ANSI_6)]
        let editor: [(String, String)] = EditorShortcut.allCases.map { ($0.title, $0.display) } + [
            ("Done", "↩"), ("Nudge (⇧ = 10 pt)", "←↑→↓"), ("Deselect", "Esc"), ("Delete", "⌫")]
        let tools = Tool.visible.filter { !$0.key.isEmpty }.map { ($0.label, $0.key.uppercased()) }
        return SettingsWindow.pane([
            SettingsWindow.section("Global", names.map { SettingsWindow.row($0.0, ShortcutRecorder(code: UInt32($0.1))) },
                                   footer: "Click a shortcut, then press a combination with ⌘, ⌃ or ⌥. Esc cancels, ⌫ removes it."),
            SettingsWindow.section("More actions", AppDelegate.extraShortcuts.map { SettingsWindow.row($0.0, ShortcutRecorder(code: $0.1)) }),
            SettingsWindow.section("Annotate", editor.map { SettingsWindow.row($0.0, keycap($0.1)) }),
            SettingsWindow.section("Annotate tools", tools.map { SettingsWindow.row($0.0, keycap($0.1)) }),
        ])
    }
    private static func keycap(_ keys: String) -> NSView {
        let label = NSTextField(labelWithString: keys); label.font = .systemFont(ofSize: 12, weight: .medium); label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.cornerRadius = 5; box.borderWidth = 1; box.borderColor = .separatorColor; box.fillColor = .quaternarySystemFill
        box.contentView?.addSubview(label)
        if let content = box.contentView {
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: content.topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
                                         label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                                         box.widthAnchor.constraint(greaterThanOrEqualToConstant: 28)])
            label.alignment = .center
        }
        return box
    }
}

private final class ShortcutRecorder: NSButton {
    static weak var active: ShortcutRecorder?
    private let code: UInt32
    private var monitor: Any?
    init(code: UInt32) {
        self.code = code
        super.init(frame: .zero); bezelStyle = .push; title = Hotkeys.label(code)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        target = self; action = #selector(record); toolTip = "Record a new global shortcut"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func record() {
        Self.active?.stop(); Self.active = self; Hotkeys.suspend(); title = "Record shortcut"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            if event.keyCode == 51 { Hotkeys.clear(self.code); self.stop(); return nil } // ⌫ removes the shortcut
            if Hotkeys.rebind(self.code, event: event) { self.stop() } else { NSSound.beep() }
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil; Hotkeys.resume() }
        title = Hotkeys.label(code); if Self.active === self { Self.active = nil }
    }
}
