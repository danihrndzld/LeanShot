import AppKit

enum BackgroundEditor {
    static func choose() -> BackgroundStyle? {
        let alert = NSAlert(); alert.messageText = "Background"; alert.informativeText = "Add padding, rounded corners and a background. Apply can be undone."
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let palette = NSPopUpButton(); palette.addItems(withTitles: BackgroundStyle.names)
        let aspect = NSPopUpButton(); aspect.addItems(withTitles: ["Auto aspect", "Square", "Landscape 16:9", "Portrait 9:16", "4:3"])
        let align = NSPopUpButton(); align.addItems(withTitles: ["Left", "Center (Auto Balance)", "Right"])
        let pad = NSTextField(string: "64"), radius = NSTextField(string: "16"), name = NSTextField(string: "")
        name.placeholderString = "Optional preset name"
        let shadow = NSButton(checkboxWithTitle: "Drop shadow", target: nil, action: nil)
        let data = Settings.defaults.data(forKey: "backgroundPreset")
        var current = data.flatMap { try? JSONDecoder().decode(BackgroundStyle.self, from: $0) } ?? BackgroundStyle()
        var saved = Settings.defaults.data(forKey: "backgroundPresets").flatMap { try? JSONDecoder().decode([String: BackgroundStyle].self, from: $0) } ?? [:]
        let names = saved.keys.sorted()
        func display(_ style: BackgroundStyle) {
            palette.selectItem(at: min(max(0, style.palette), BackgroundStyle.names.count - 1))
            aspect.selectItem(at: min(max(0, style.aspect), 4)); align.selectItem(at: min(max(0, style.alignment), 2))
            pad.stringValue = "\(Int(style.padding))"; radius.stringValue = "\(Int(style.radius))"; shadow.state = style.shadow ? .on : .off
        }
        display(current)
        let presets = ClosurePopup(choices: ["Last Used"] + names, selected: 0) { index in
            if index > 0, let style = saved[names[index - 1]] { current = style; name.stringValue = names[index - 1]; display(style) }
            else if let data, let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) { current = style; display(style); name.stringValue = "" }
        }
        let custom = ClosureButton(frame: .zero) {
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            if p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) { current.customImage = data; palette.selectItem(at: 19) }
        }
        custom.title = "Choose Custom Image…"; custom.bezelStyle = .rounded
        for view in [presets, palette, custom, aspect, align, NSTextField(labelWithString: "Padding (points)"), pad, NSTextField(labelWithString: "Corner radius"), radius, shadow, name] { stack.addArrangedSubview(view) }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 360); alert.accessoryView = stack
        alert.addButton(withTitle: "Apply & Save Preset"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        current.palette = palette.indexOfSelectedItem; current.aspect = aspect.indexOfSelectedItem; current.alignment = align.indexOfSelectedItem
        current.padding = CGFloat(min(512, max(0, pad.doubleValue))); current.radius = CGFloat(min(256, max(0, radius.doubleValue))); current.shadow = shadow.state == .on
        if current.palette == 19, current.customImage == nil {
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return nil }; current.customImage = data
        }
        if current.palette != 19 { current.customImage = nil }
        Settings.defaults.set(try? JSONEncoder().encode(current), forKey: "backgroundPreset")
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { saved[title] = current; Settings.defaults.set(try? JSONEncoder().encode(saved), forKey: "backgroundPresets") }
        return current
    }
}
