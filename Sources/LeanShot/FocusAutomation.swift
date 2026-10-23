import AppKit

/// Focus has no public setter; users provide two macOS shortcuts with Set Focus actions.
final class FocusAutomation {
    private static let queue = DispatchQueue(label: "LeanShot.FocusShortcuts")
    private var endShortcut: String?
    func begin() async throws {
        guard Settings.focusEnabled else { return }
        let start = Settings.defaults.string(forKey: "focusStart") ?? "", end = Settings.defaults.string(forKey: "focusEnd") ?? ""
        guard !start.isEmpty, !end.isEmpty else { throw NSError(domain: "LeanShot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Configure both Focus shortcuts in LeanShot Settings before enabling Focus automation."]) }
        endShortcut = end
        _ = try await Self.command(["run", start])
    }
    func end(completion: (() -> Void)? = nil) {
        guard let name = endShortcut else { if let completion { DispatchQueue.main.async(execute: completion) }; return }; endShortcut = nil
        // Enqueue before another recording can begin, so stop/start automation stays ordered.
        Self.queue.async {
            do { _ = try Self.execute(["run", name]) }
            catch { DispatchQueue.main.async { Toast.show("Could not run the end-of-recording Focus shortcut") } }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    static func configure() {
        Task { @MainActor in
            do {
                let result = try await command(["list"])
                let names = result.split(separator: "\n").map(String.init).sorted()
                let start = NSPopUpButton(), end = NSPopUpButton()
                for picker in [start, end] { picker.addItems(withTitles: ["Disabled"] + names) }
                if let name = Settings.defaults.string(forKey: "focusStart") { start.selectItem(withTitle: name) }
                if let name = Settings.defaults.string(forKey: "focusEnd") { end.selectItem(withTitle: name) }
                let alert = NSAlert(); alert.messageText = "Focus Automation"
                alert.informativeText = "In the Shortcuts app, create a shortcut using Set Focus to enable Do Not Disturb, and another to restore your preferred Focus state. Choose those shortcuts below. LeanShot runs them automatically at recording start/end."
                let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
                for view in [NSTextField(labelWithString: "At recording start"), start, NSTextField(labelWithString: "At recording end"), end] { stack.addArrangedSubview(view) }
                stack.frame = NSRect(x: 0, y: 0, width: 320, height: 120); alert.accessoryView = stack
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    Settings.defaults.set(start.indexOfSelectedItem > 0 ? start.titleOfSelectedItem : "", forKey: "focusStart")
                    Settings.defaults.set(end.indexOfSelectedItem > 0 ? end.titleOfSelectedItem : "", forKey: "focusEnd")
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }
    private static func command(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try execute(arguments)) } catch { continuation.resume(throwing: error) } }
        }
    }
    private static func execute(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { throw NSError(domain: "LeanShot", code: 5, userInfo: [NSLocalizedDescriptionKey: "The Focus shortcut failed or timed out. Check it in the Shortcuts app."]) }
        return String(decoding: data, as: UTF8.self)
    }
}
