import AppKit
import ServiceManagement

enum Settings {
    static let defaults = UserDefaults.standard
    static var corner: Int { get { defaults.integer(forKey: "overlayCorner") } set { defaults.set(newValue, forKey: "overlayCorner") } }
    static var overlayWidth: CGFloat { get { let v = defaults.double(forKey: "overlayWidth"); return v > 0 ? v : 280 } set { defaults.set(newValue, forKey: "overlayWidth") } }
    static var autoClose: Double { get { defaults.double(forKey: "overlayAutoClose") } set { defaults.set(newValue, forKey: "overlayAutoClose") } }
    static var copyOnCapture: Bool { get { defaults.object(forKey: "copyOnCapture") as? Bool ?? true } set { defaults.set(newValue, forKey: "copyOnCapture") } }
    static var windowShadow: Bool { get { defaults.object(forKey: "windowShadow") as? Bool ?? true } set { defaults.set(newValue, forKey: "windowShadow") } }
    static var captureCursor: Bool { get { defaults.bool(forKey: "captureCursor") } set { defaults.set(newValue, forKey: "captureCursor") } }
    static var recordingFPS: Int { get { defaults.integer(forKey: "recordingFPS") == 60 ? 60 : 30 } set { defaults.set(newValue, forKey: "recordingFPS") } }
    static var recordingAudio: Bool { get { defaults.bool(forKey: "recordingAudio") } set { defaults.set(newValue, forKey: "recordingAudio") } }
    static var recordingMicrophone: Bool { get { defaults.bool(forKey: "recordingMicrophone") } set { defaults.set(newValue, forKey: "recordingMicrophone") } }
    static var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("LeanShot")
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }
}

final class SettingsWindow: NSWindow {
    private static var instance: SettingsWindow?
    static func show() {
        if let w = instance { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LeanShot Settings"
        w.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.frame = NSRect(x: 28, y: 24, width: 424, height: 508)
        func toggle(_ title: String, _ value: Bool, _ change: @escaping (Bool) -> Void) {
            let b = ClosureButton(frame: .zero) {}
            b.setButtonType(.switch); b.title = title; b.state = value ? .on : .off
            b.setHandler { [weak b] in change(b?.state == .on) }
            stack.addArrangedSubview(b)
        }
        func popup(_ title: String, _ choices: [String], _ selected: Int, _ change: @escaping (Int) -> Void) {
            let row = NSStackView(); row.spacing = 12
            row.addArrangedSubview(NSTextField(labelWithString: title))
            let p = ClosurePopup(choices: choices, selected: selected, change: change)
            row.addArrangedSubview(p); stack.addArrangedSubview(row)
        }
        toggle("Copy captures to clipboard", Settings.copyOnCapture) { Settings.copyOnCapture = $0 }
        toggle("Include window shadows", Settings.windowShadow) { Settings.windowShadow = $0 }
        toggle("Include pointer in screenshots / recordings", Settings.captureCursor) { Settings.captureCursor = $0 }
        popup("Overlay position", ["Bottom left", "Bottom right", "Top left", "Top right"], Settings.corner) { Settings.corner = $0 }
        popup("Thumbnail size", ["Small", "Medium", "Large"], [220, 280, 340].firstIndex(of: Int(Settings.overlayWidth)) ?? 1) { Settings.overlayWidth = CGFloat([220, 280, 340][$0]) }
        popup("Close overlays", ["Manually", "After 10 seconds", "After 30 seconds", "After 60 seconds"], [0.0, 10, 30, 60].firstIndex(of: Settings.autoClose) ?? 0) { Settings.autoClose = [0, 10, 30, 60][$0] }
        popup("Recording frame rate", ["30 fps", "60 fps"], Settings.recordingFPS == 60 ? 1 : 0) { Settings.recordingFPS = $0 == 1 ? 60 : 30 }
        toggle("Record computer audio", Settings.recordingAudio) { Settings.recordingAudio = $0 }
        toggle("Record microphone (macOS 15+)", Settings.recordingMicrophone) { Settings.recordingMicrophone = $0 }
        toggle("Launch at login", SMAppService.mainApp.status == .enabled) { enabled in
            do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSAlert(error: error).runModal() }
        }
        let folder = ClosureButton(frame: .zero) {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
            if p.runModal() == .OK, let url = p.url { Settings.saveFolder = url }
        }
        folder.title = "Choose Captures Folder…"; folder.bezelStyle = .rounded; stack.addArrangedSubview(folder)
        w.contentView?.addSubview(stack)
        w.center(); instance = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}

final class ClosurePopup: NSPopUpButton {
    private let change: (Int) -> Void
    init(choices: [String], selected: Int, change: @escaping (Int) -> Void) {
        self.change = change
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: choices); selectItem(at: selected)
        target = self; action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { change(indexOfSelectedItem) }
}

enum CaptureHistory {
    static func files(in folder: URL = Capture.folder) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["png", "jpg", "jpeg", "mov", "mp4", "gif", "leanshot"].contains($0.pathExtension.lowercased()) }
            .sorted { date($0) > date($1) }
    }
    private static func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
}
