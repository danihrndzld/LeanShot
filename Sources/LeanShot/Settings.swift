import AppKit
import ServiceManagement

enum Settings {
    /// `--e2e` and `--selftest` run against a throwaway defaults domain, so tests never read or change the user's settings.
    static let testSuite = "com.danisnowman.leanshot.e2e"
    static let defaults = ["--e2e", "--selftest"].contains(where: CommandLine.arguments.contains) ? UserDefaults(suiteName: testSuite)! : .standard
    // Every UserDefaults key lives here; interpolated keys go through these builders so a typo cannot reset a value.
    enum HotkeyPart: String { case code, modifiers, key }
    static func hotkeyKey(_ defaultCode: UInt32, _ part: HotkeyPart) -> String { "hotkey.\(defaultCode).\(part.rawValue)" }
    static func lastRegionKey(_ displayID: UInt32) -> String { "lastRegion.\(displayID)" }
    /// Last-used editor choices, restored in every new editor window.
    static var editorChoices: [String: Double] {
        get { defaults.dictionary(forKey: "editorChoices") as? [String: Double] ?? [:] } set { defaults.set(newValue, forKey: "editorChoices") }
    }
    /// Index into AnnotateWindow's Save As formats (PNG, JPEG, HEIC); remembered between saves.
    static var exportFormat: Int { get { defaults.integer(forKey: "exportFormat") } set { defaults.set(newValue, forKey: "exportFormat") } }
    static var focusStart: String { get { defaults.string(forKey: "focusStart") ?? "" } set { defaults.set(newValue, forKey: "focusStart") } }
    static var focusEnd: String { get { defaults.string(forKey: "focusEnd") ?? "" } set { defaults.set(newValue, forKey: "focusEnd") } }
    /// Pre-0.3 background storage, read once to migrate into Application Support files.
    static var backgroundPreset: Data? { get { defaults.data(forKey: "backgroundPreset") } set { defaults.set(newValue, forKey: "backgroundPreset") } }
    static var backgroundPresets: Data? { get { defaults.data(forKey: "backgroundPresets") } set { defaults.set(newValue, forKey: "backgroundPresets") } }
    static var corner: Int { get { defaults.integer(forKey: "overlayCorner") } set { defaults.set(newValue, forKey: "overlayCorner") } }
    static var overlayWidth: CGFloat { get { let v = defaults.double(forKey: "overlayWidth"); return v > 0 ? v : 180 } set { defaults.set(newValue, forKey: "overlayWidth") } }
    static var autoClose: Double { get { defaults.double(forKey: "overlayAutoClose") } set { defaults.set(newValue, forKey: "overlayAutoClose") } }
    static var copyOnCapture: Bool { get { defaults.object(forKey: "copyOnCapture") as? Bool ?? true } set { defaults.set(newValue, forKey: "copyOnCapture") } }
    static var windowShadow: Bool { get { defaults.object(forKey: "windowShadow") as? Bool ?? true } set { defaults.set(newValue, forKey: "windowShadow") } }
    static var captureCursor: Bool { get { defaults.bool(forKey: "captureCursor") } set { defaults.set(newValue, forKey: "captureCursor") } }
    static var recordingFPS: Int { get { defaults.integer(forKey: "recordingFPS") == 60 ? 60 : 30 } set { defaults.set(newValue, forKey: "recordingFPS") } }
    static var recordingAudio: Bool { get { defaults.bool(forKey: "recordingAudio") } set { defaults.set(newValue, forKey: "recordingAudio") } }
    static var recordingMicrophone: Bool { get { defaults.bool(forKey: "recordingMicrophone") } set { defaults.set(newValue, forKey: "recordingMicrophone") } }
    static var recordCamera: Bool { get { defaults.bool(forKey: "recordCamera") } set { defaults.set(newValue, forKey: "recordCamera") } }
    static var recordKeystrokes: Bool { get { defaults.bool(forKey: "recordKeystrokes") } set { defaults.set(newValue, forKey: "recordKeystrokes") } }
    static var commandKeysOnly: Bool { get { defaults.object(forKey: "commandKeysOnly") as? Bool ?? true } set { defaults.set(newValue, forKey: "commandKeysOnly") } }
    static var recordClicks: Bool { get { defaults.bool(forKey: "recordClicks") } set { defaults.set(newValue, forKey: "recordClicks") } }
    static var cameraCorner: Int { get { defaults.object(forKey: "cameraCorner") as? Int ?? 1 } set { defaults.set(newValue, forKey: "cameraCorner") } }
    static var cameraSize: CGFloat { get { let v = defaults.double(forKey: "cameraSize"); return v > 0 ? v : 180 } set { defaults.set(newValue, forKey: "cameraSize") } }
    static var cameraCircle: Bool { get { defaults.object(forKey: "cameraCircle") as? Bool ?? true } set { defaults.set(newValue, forKey: "cameraCircle") } }
    static var keysLight: Bool { get { defaults.bool(forKey: "keysLight") } set { defaults.set(newValue, forKey: "keysLight") } }
    static var keysCorner: Int { get { defaults.integer(forKey: "keysCorner") } set { defaults.set(newValue, forKey: "keysCorner") } }
    static var keysSize: CGFloat { get { let v = defaults.double(forKey: "keysSize"); return v > 0 ? v : 23 } set { defaults.set(newValue, forKey: "keysSize") } }
    static var cameraFullscreen: Bool { get { defaults.bool(forKey: "cameraFullscreen") } set { defaults.set(newValue, forKey: "cameraFullscreen") } }
    static var hideDesktop: Bool { get { defaults.bool(forKey: "hideDesktop") } set { defaults.set(newValue, forKey: "hideDesktop") } }
    static var clickColor: Int { get { defaults.integer(forKey: "clickColor") } set { defaults.set(newValue, forKey: "clickColor") } }
    static var clickSize: CGFloat { get { let v = defaults.double(forKey: "clickSize"); return v > 0 ? v : 40 } set { defaults.set(newValue, forKey: "clickSize") } }
    static var clickFilled: Bool { get { defaults.bool(forKey: "clickFilled") } set { defaults.set(newValue, forKey: "clickFilled") } }
    static var clickAnimated: Bool { get { defaults.object(forKey: "clickAnimated") as? Bool ?? true } set { defaults.set(newValue, forKey: "clickAnimated") } }
    static var recordingResolution: Int { get { let v = defaults.integer(forKey: "recordingResolution"); return [1280, 1920, 3840].contains(v) ? v : 3840 } set { defaults.set(newValue, forKey: "recordingResolution") } }
    static var focusEnabled: Bool { get { defaults.bool(forKey: "focusEnabled") } set { defaults.set(newValue, forKey: "focusEnabled") } }
    static var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("LeanShot")
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }
}

final class SettingsWindow: NSWindow, NSWindowDelegate {
    private static var instance: SettingsWindow?
    static let width: CGFloat = 560
    private let tabs = SettingsTabs()
    /// Tabs: 0 General, 1 Quick Access, 2 Screenshots, 3 Recording, 4 Shortcuts, 5 About. nil keeps the last tab.
    static func show(tab: Int? = nil) {
        let w = instance ?? SettingsWindow(); instance = w
        if let tab { w.tabs.selectedTabViewItemIndex = tab }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
    static func preview(tab: Int, to output: URL) {
        show(tab: tab); instance?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let w = instance else { exit(1) }
            // Real capture when Screen Recording allows it; otherwise the view's own rendering.
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(w.windowNumber)", output.path]
            try? task.run(); task.waitUntilExit()
            if task.terminationStatus != 0, let view = w.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
            }
            exit(0)
        }
    }
    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; delegate = self; toolbarStyle = .preference
        tabs.tabStyle = .toolbar
        let panes: [(String, String, NSView)] = [("General", "gearshape", Self.general()), ("Quick Access", "rectangle.on.rectangle", Self.quickAccess()),
            ("Screenshots", "camera", Self.screenshots()), ("Recording", "video", Self.recording()), ("Shortcuts", "command", ShortcutSettings.pane()), ("About", "info.circle", Self.about())]
        for (title, symbol, view) in panes {
            let vc = NSViewController(); vc.view = view; vc.title = title; vc.preferredContentSize = view.frame.size
            let item = NSTabViewItem(viewController: vc); item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        contentViewController = tabs
    }
    func windowWillClose(_ notification: Notification) { ShortcutSettings.stopRecording() }

    private static func general() -> NSView {
        let folder = ClosureButton(frame: .zero) {}
        func showFolder() {
            folder.title = Settings.saveFolder.lastPathComponent; folder.toolTip = Settings.saveFolder.path
            let icon = NSWorkspace.shared.icon(forFile: Settings.saveFolder.path); icon.size = NSSize(width: 16, height: 16)
            folder.image = icon; folder.imagePosition = .imageLeading
        }
        folder.bezelStyle = .push; showFolder()
        folder.setHandler {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.directoryURL = Settings.saveFolder
            if p.runModal() == .OK, let url = p.url { Settings.saveFolder = url; showFolder() }
        }
        let focus = ClosureButton(frame: .zero) { FocusAutomation.configure() }
        focus.title = "Configure…"; focus.bezelStyle = .push
        return pane([
            section("General", [
                row("Copy captures to clipboard", toggle(Settings.copyOnCapture) { Settings.copyOnCapture = $0 }),
                row("Launch at login", toggle(SMAppService.mainApp.status == .enabled) { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { NSAlert(error: error).runModal() }
                }),
                row("Captures folder", folder),
            ]),
            section("Focus", [
                row("Use Focus shortcuts while recording", toggle(Settings.focusEnabled) { Settings.focusEnabled = $0 }),
                row("Focus shortcuts", "Shortcuts that turn Focus on and off around a recording", focus),
            ]),
        ])
    }

    private static func quickAccess() -> NSView {
        pane([section("Overlay", [
            row("Position", ClosurePopup(choices: ["Bottom left", "Bottom right", "Top left", "Top right"], selected: Settings.corner) { Settings.corner = $0 }),
            row("Thumbnail size", ClosurePopup(choices: ["Small", "Medium", "Large"], selected: [150, 180, 230].firstIndex(of: Int(Settings.overlayWidth)) ?? 1) { Settings.overlayWidth = CGFloat([150, 180, 230][$0]) }),
            row("Close overlays", ClosurePopup(choices: ["Manually", "After 10 seconds", "After 30 seconds", "After 60 seconds"], selected: [0.0, 10, 30, 60].firstIndex(of: Settings.autoClose) ?? 0) { Settings.autoClose = [0, 10, 30, 60][$0] }),
        ])])
    }

    private static func screenshots() -> NSView {
        pane([section("Capture", [
            row("Include window shadows", toggle(Settings.windowShadow) { Settings.windowShadow = $0 }),
            row("Include pointer", "Also applies to recordings", toggle(Settings.captureCursor) { Settings.captureCursor = $0 }),
        ])])
    }

    private static func recording() -> NSView {
        let corners = ["Bottom left", "Bottom right", "Top left", "Top right"], sizes = ["Small", "Medium", "Large"]
        return pane([
            section("Video", [
                row("Frame rate", ClosurePopup(choices: ["30 fps", "60 fps"], selected: Settings.recordingFPS == 60 ? 1 : 0) { Settings.recordingFPS = $0 == 1 ? 60 : 30 }),
                row("Resolution limit", ClosurePopup(choices: ["1280 px", "1920 px", "3840 px (4K)"], selected: [1280, 1920, 3840].firstIndex(of: Settings.recordingResolution) ?? 2) { Settings.recordingResolution = [1280, 1920, 3840][$0] }),
                row("Hide desktop icons while recording", toggle(Settings.hideDesktop) { Settings.hideDesktop = $0 }),
            ]),
            section("Audio", [
                row("Record computer audio", toggle(Settings.recordingAudio) { Settings.recordingAudio = $0 }),
                row("Record microphone", "macOS 15 or later", toggle(Settings.recordingMicrophone) { Settings.recordingMicrophone = $0 }),
            ]),
            section("Clicks", [
                row("Show clicks", "macOS 15 or later", toggle(Settings.recordClicks) { Settings.recordClicks = $0 }),
                row("Color", "Display and area recordings", ClosurePopup(choices: ["Pink", "Blue", "Green", "Yellow", "White"], selected: Settings.clickColor) { Settings.clickColor = $0 }),
                row("Size", ClosurePopup(choices: sizes, selected: [24, 40, 64].firstIndex(of: Int(Settings.clickSize)) ?? 1) { Settings.clickSize = CGFloat([24, 40, 64][$0]) }),
                row("Filled circles", toggle(Settings.clickFilled) { Settings.clickFilled = $0 }),
                row("Animate circles", toggle(Settings.clickAnimated) { Settings.clickAnimated = $0 }),
            ]),
            section("Camera", [
                row("Record camera", "Display and area recordings, macOS 15 or later", toggle(Settings.recordCamera) { Settings.recordCamera = $0 }),
                row("Position", ClosurePopup(choices: corners, selected: Settings.cameraCorner) { Settings.cameraCorner = $0 }),
                row("Size", ClosurePopup(choices: sizes, selected: [140, 180, 240].firstIndex(of: Int(Settings.cameraSize)) ?? 1) { Settings.cameraSize = CGFloat([140, 180, 240][$0]) }),
                row("Circular frame", toggle(Settings.cameraCircle) { Settings.cameraCircle = $0 }),
                row("Fullscreen camera", toggle(Settings.cameraFullscreen) { Settings.cameraFullscreen = $0 }),
            ]),
            section("Keystrokes", [
                row("Show keystrokes", "Display and area recordings, requires Accessibility", toggle(Settings.recordKeystrokes) { Settings.recordKeystrokes = $0 }),
                row("Only shortcuts with ⌘, ⌃ or ⌥", toggle(Settings.commandKeysOnly) { Settings.commandKeysOnly = $0 }),
                row("Light style", toggle(Settings.keysLight) { Settings.keysLight = $0 }),
                row("Position", ClosurePopup(choices: corners, selected: Settings.keysCorner) { Settings.keysCorner = $0 }),
                row("Size", ClosurePopup(choices: sizes, selected: [17, 23, 30].firstIndex(of: Int(Settings.keysSize)) ?? 1) { Settings.keysSize = CGFloat([17, 23, 30][$0]) }),
            ]),
        ])
    }

    private static func about() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true; icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: "LeanShot"); name.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = NSTextField(labelWithString: "Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
        version.textColor = .secondaryLabelColor
        let blurb = NSTextField(labelWithString: "Native capture and annotation for macOS"); blurb.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, version, blurb]); stack.orientation = .vertical; stack.spacing = 6
        stack.setCustomSpacing(12, after: icon); stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        stack.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
        return pane([stack])
    }

    // System Settings–style building blocks, shared with ShortcutSettings.
    static func pane(_ sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        stack.frame.size = NSSize(width: width, height: stack.fittingSize.height)
        let doc = FlippedView(frame: stack.frame); doc.addSubview(stack)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(stack.frame.height, 640)))
        scroll.documentView = doc; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        if stack.frame.height <= 640 { scroll.verticalScrollElasticity = .none }
        return scroll
    }
    static func section(_ title: String, _ rows: [NSView], footer: String? = nil) -> NSView {
        let list = NSStackView(); list.orientation = .vertical; list.spacing = 0; list.translatesAutoresizingMaskIntoConstraints = false
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox(); line.boxType = .separator; list.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: width - 64).isActive = true
            }
            list.addArrangedSubview(row)
        }
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.cornerRadius = 10; box.borderWidth = 1; box.borderColor = .separatorColor; box.fillColor = .quinarySystemFill
        box.contentView?.addSubview(list)
        if let content = box.contentView {
            NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: content.topAnchor, constant: 2), list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),
                                         list.leadingAnchor.constraint(equalTo: content.leadingAnchor), list.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        }
        let header = NSTextField(labelWithString: title); header.font = .boldSystemFont(ofSize: 13)
        let headerRow = NSStackView(views: [header]); headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        let stack = NSStackView(views: [headerRow, box]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        if let footer {
            let note = NSTextField(wrappingLabelWithString: footer); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = width - 56
            let noteRow = NSStackView(views: [note]); noteRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8); stack.addArrangedSubview(noteRow)
        }
        return stack
    }
    static func row(_ title: String, _ control: NSView) -> NSView { row(title, nil, control) }
    static func row(_ title: String, _ detail: String?, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let text = NSStackView(views: [label]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        if let detail {
            let sub = NSTextField(labelWithString: detail); sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
            text.addArrangedSubview(sub)
        }
        let row = NSStackView(); row.orientation = .horizontal
        row.addView(text, in: .leading); row.addView(control, in: .trailing)
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        row.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }
    static func toggle(_ on: Bool, _ change: @escaping (Bool) -> Void) -> NSView {
        let s = ClosureSwitch(); s.controlSize = .small; s.state = on ? .on : .off; s.change = change
        return s
    }
}

private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem); view.window?.title = tabViewItem?.label ?? ""
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.title = tabViewItems[selectedTabViewItemIndex].label }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class ClosureSwitch: NSSwitch {
    var change: (Bool) -> Void = { _ in }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(changed) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { change(state == .on) }
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
