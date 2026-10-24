import AppKit
import UniformTypeIdentifiers

/// Sidebar that edits the backdrop live: presets, gradients, wallpapers, blurred, plain colors, layout.
final class BackgroundInspector: NSViewController {
    var style: ShotBackground? { didSet { if style != oldValue { onChange?(style); refresh() } } }
    var onChange: ((ShotBackground?) -> Void)?
    /// Last non-empty style, so layout sliders work before a fill is picked.
    private var working = BackgroundInspector.lastUsed ?? ShotBackground()
    private let stack = NSStackView()
    private var swatches: [(SwatchButton, (ShotBackground) -> Bool)] = []
    private var noneButton: NSButton!
    private var sliders: [(NSSlider, WritableKeyPath<ShotBackground, CGFloat>)] = []
    private var positions: [NSButton] = []
    private var ratio: NSPopUpButton!
    private var presets: NSPopUpButton!
    private var wallpaperRow: NSStackView!
    private var blurredRow: NSStackView!

    // Wallpaper backgrounds embed ~1 MB of JPEG, so they live in Application Support files, not UserDefaults.
    // Values older builds kept in defaults move over on first read.
    static var lastUsed: ShotBackground? {
        get { stored("Background.json", legacy: Settings.backgroundPreset) { Settings.backgroundPreset = nil } }
        set { store(newValue, "Background.json") }
    }
    private static var saved: [String: ShotBackground] {
        get { stored("Background Presets.json", legacy: Settings.backgroundPresets) { Settings.backgroundPresets = nil } ?? [:] }
        set { store(newValue, "Background Presets.json") }
    }
    private static func stored<T: Decodable>(_ name: String, legacy: Data?, clearLegacy: () -> Void) -> T? {
        let file = wallpaperFolder.deletingLastPathComponent().appendingPathComponent(name)
        if let data = try? Data(contentsOf: file) { return try? JSONDecoder().decode(T.self, from: data) }
        guard let old = legacy, let value = try? JSONDecoder().decode(T.self, from: old) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? old.write(to: file, options: .atomic)) != nil { clearLegacy() }
        return value
    }
    private static func store<T: Encodable>(_ value: T?, _ name: String) {
        let file = wallpaperFolder.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let value, let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
    }
    private static var wallpaperFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LeanShot/Wallpapers", isDirectory: true)
    }
    /// The current desktop picture plus wallpapers the user added.
    private static func wallpapers() -> [URL] {
        let desktop = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.map { [$0] } ?? []
        let added = (try? FileManager.default.contentsOfDirectory(at: wallpaperFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return (desktop + added.sorted { $0.lastPathComponent < $1.lastPathComponent }).filter(Thumbnail.isImage)
    }

    override func loadView() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 268, height: 600))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack); scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
        build()
        refresh()
    }

    private func build() {
        presets = NSPopUpButton(frame: .zero, pullsDown: true)
        presets.target = self; presets.action = #selector(pickPreset)
        let add = ClosureButton(frame: .zero) { [weak self] in self?.savePreset() }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Save Preset"); add.isBordered = false; add.toolTip = "Save current background as a preset"
        let top = NSStackView(views: [presets, add]); top.spacing = 6
        presets.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(top)

        noneButton = ClosureButton(frame: .zero) { [weak self] in self?.style = nil }
        noneButton.title = "None"; noneButton.bezelStyle = .rounded; noneButton.controlSize = .large
        noneButton.widthAnchor.constraint(equalToConstant: 236).isActive = true
        stack.addArrangedSubview(noneButton)

        section("Gradients")
        grid(ShotBackground.gradients.indices.map { i in
            swatch({ var s = ShotBackground(); s.palette = i; return s }(), label: "Gradient \(i + 1)", select: { $0.customImage == nil && $0.color == nil && $0.palette == i }) { $0.palette = i; $0.color = nil; $0.customImage = nil; $0.blur = 0 }
        }, columns: 5)

        section("Wallpapers")
        wallpaperRow = NSStackView(); wallpaperRow.spacing = 8; stack.addArrangedSubview(wallpaperRow)
        section("Blurred")
        blurredRow = NSStackView(); blurredRow.spacing = 8; stack.addArrangedSubview(blurredRow)
        loadWallpapers()

        section("Plain color")
        var colors: [NSView] = ShotBackground.plainColors.enumerated().map { index, hex in
            swatch({ var s = ShotBackground(); s.color = ShotBackground.rgba(hex); return s }(), label: "Plain color \(index + 1)", size: 22, round: true,
                   select: { $0.customImage == nil && $0.color == ShotBackground.rgba(hex) }) { $0.color = ShotBackground.rgba(hex); $0.customImage = nil }
        }
        colors.insert(swatch(nil, label: "Transparent", size: 22, round: true, select: { $0.isTransparent }) { $0.color = [0, 0, 0, 0]; $0.customImage = nil }, at: 8)
        let well = ClosureButton(frame: .zero) { [weak self] in
            let panel = NSColorPanel.shared; panel.setTarget(self); panel.setAction(#selector(self?.customColor(_:))); panel.orderFront(nil)
        }
        well.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Custom Color"); well.isBordered = false; well.toolTip = "Custom color"
        well.widthAnchor.constraint(equalToConstant: 22).isActive = true
        colors.append(well)
        grid(colors, columns: 9, spacing: 4)

        let divider = NSBox(); divider.boxType = .separator; divider.widthAnchor.constraint(equalToConstant: 236).isActive = true
        stack.addArrangedSubview(divider)
        slider("Padding", \.padding, 0...240)
        slider("Inset", \.inset, 0...80)
        let pair = NSStackView(views: [labeled("Shadow", sliderControl(\.shadow, 0...1, width: 110)), labeled("Corners", sliderControl(\.radius, 0...48, width: 110))])
        pair.spacing = 16; pair.alignment = .top; stack.addArrangedSubview(pair)

        let gridView = NSGridView(numberOfColumns: 3, rows: 0); gridView.rowSpacing = 6; gridView.columnSpacing = 6
        for row in 0..<3 {
            gridView.addRow(with: (0..<3).map { column in
                let index = row * 3 + column
                let b = ClosureButton(frame: .zero) { [weak self] in self?.update { $0.position = index } }
                b.image = Self.positionGlyph(index); b.isBordered = false; b.setButtonType(.toggle)
                let name = ["Top left", "Top", "Top right", "Left", "Center", "Right", "Bottom left", "Bottom", "Bottom right"][index]
                b.toolTip = "Align screenshot: \(name)"; b.setAccessibilityLabel("Align \(name)")
                positions.append(b); return b
            })
        }
        ratio = NSPopUpButton(frame: .zero, pullsDown: false)
        ratio.addItems(withTitles: ShotBackground.ratios.map(\.0)); ratio.target = self; ratio.action = #selector(pickRatio)
        let bottom = NSStackView(views: [labeled("Alignment", gridView), labeled("Ratio", ratio)]); bottom.spacing = 28; bottom.alignment = .top
        stack.addArrangedSubview(bottom)
    }

    // MARK: Building blocks

    private func section(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? stack)
        stack.addArrangedSubview(label)
    }
    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
        control.setAccessibilityLabel(title) // VoiceOver reads "Shadow, slider" instead of an unnamed control
        let v = NSStackView(views: [label, control]); v.orientation = .vertical; v.alignment = .leading; v.spacing = 6
        return v
    }
    private func grid(_ views: [NSView], columns: Int, spacing: CGFloat = 8) {
        let g = NSGridView(numberOfColumns: columns, rows: 0); g.rowSpacing = spacing; g.columnSpacing = spacing
        stride(from: 0, to: views.count, by: columns).forEach { g.addRow(with: Array(views[$0..<min($0 + columns, views.count)])) }
        stack.addArrangedSubview(g)
    }
    private func swatch(_ preview: ShotBackground?, label: String, size: CGFloat = 40, round: Bool = false, select: @escaping (ShotBackground) -> Bool, apply: @escaping (inout ShotBackground) -> Void) -> SwatchButton {
        let b = SwatchButton(size: size, round: round) { [weak self] in self?.update(apply) }
        b.image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            if let preview { preview.drawFill(in: r) } else { Self.checkerboard(r) }
            return true
        }
        b.setAccessibilityLabel(label); b.toolTip = label
        swatches.append((b, select))
        return b
    }
    private func sliderControl(_ key: WritableKeyPath<ShotBackground, CGFloat>, _ range: ClosedRange<Double>, width: CGFloat) -> NSSlider {
        let s = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(slid(_:)))
        s.isContinuous = true; s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        sliders.append((s, key)); return s
    }
    private func slider(_ title: String, _ key: WritableKeyPath<ShotBackground, CGFloat>, _ range: ClosedRange<Double>) {
        stack.addArrangedSubview(labeled(title, sliderControl(key, range, width: 236)))
    }

    private func loadWallpapers() {
        wallpaperRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        blurredRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        swatches.removeAll { $0.0.tag == 7 }
        let add = SwatchButton(size: 40, round: false, dashed: true) { [weak self] in self?.addWallpaper() }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Wallpaper"); add.toolTip = "Add a wallpaper image"
        wallpaperRow.addArrangedSubview(add)
        // Decoding desktop pictures takes a moment; keep the window opening instantly.
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = BackgroundInspector.wallpapers().prefix(4).compactMap { url in
                ShotBackground.wallpaperData(url).flatMap { data in ShotBackground.wallpaperData(url, maxPixels: 120).map { (data, $0) } }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (data, thumb) in loaded {
                    for (row, blur) in [(self.wallpaperRow!, CGFloat(0)), (self.blurredRow!, 40)] {
                        var preview = ShotBackground(); preview.customImage = thumb; preview.blur = blur / 20
                        let b = self.swatch(preview, label: blur > 0 ? "Blurred wallpaper" : "Wallpaper", select: { $0.customImage == data && $0.blur == blur }) { $0.customImage = data; $0.blur = blur; $0.color = nil }
                        b.tag = 7; row.insertArrangedSubview(b, at: row === self.wallpaperRow ? row.arrangedSubviews.count - 1 : row.arrangedSubviews.count)
                    }
                }
                self.refresh()
            }
        }
    }

    private func addWallpaper() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            try? FileManager.default.createDirectory(at: Self.wallpaperFolder, withIntermediateDirectories: true)
            for url in panel.urls {
                let destination = Self.wallpaperFolder.appendingPathComponent(UUID().uuidString + ".jpg")
                try? ShotBackground.wallpaperData(url)?.write(to: destination)
            }
            self.loadWallpapers(); self.refresh()
            if let url = panel.urls.first, let data = ShotBackground.wallpaperData(url) { self.update { $0.customImage = data; $0.blur = 0; $0.color = nil } }
        }
    }

    // MARK: State

    private func update(_ change: (inout ShotBackground) -> Void) {
        var next = style ?? working
        change(&next)
        working = next
        style = next
        // Wallpapers make this ~1 MB of JSON; persist once the sliders settle.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(persist), object: nil)
        perform(#selector(persist), with: nil, afterDelay: 0.5)
    }
    @objc private func persist() { Self.lastUsed = working }
    @objc private func slid(_ sender: NSSlider) {
        guard let key = sliders.first(where: { $0.0 === sender })?.1 else { return }
        update { $0[keyPath: key] = CGFloat(sender.doubleValue) }
    }
    @objc private func pickRatio() { update { $0.aspect = ratio.indexOfSelectedItem } }
    @objc private func customColor(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        update { $0.color = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]; $0.customImage = nil }
    }
    @objc private func pickPreset() {
        guard let title = presets.titleOfSelectedItem, let preset = Self.saved[title] else { return }
        working = preset; style = preset
    }
    @objc private func deletePreset(_ sender: NSMenuItem) { var all = Self.saved; all[sender.title] = nil; Self.saved = all; refresh() }
    private func savePreset() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "Save Background Preset"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.placeholderString = "Preset name"
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty, let self else { return }
            var all = Self.saved; all[name] = self.style ?? self.working; Self.saved = all; self.refresh()
        }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let current = style ?? working
        for (button, matches) in swatches { button.isSelected = style.map(matches) ?? false }
        noneButton.bezelColor = style == nil ? .controlAccentColor : nil
        for (slider, key) in sliders { slider.doubleValue = Double(current[keyPath: key]) }
        for (i, b) in positions.enumerated() { b.state = current.position == i ? .on : .off; b.contentTintColor = current.position == i ? .controlAccentColor : .tertiaryLabelColor }
        ratio.selectItem(at: current.aspect)
        presets.removeAllItems(); presets.addItem(withTitle: "Presets…")
        let names = Self.saved.keys.sorted()
        presets.addItems(withTitles: names)
        if !names.isEmpty {
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: ""), sub = NSMenu()
            for name in names { let item = NSMenuItem(title: name, action: #selector(deletePreset(_:)), keyEquivalent: ""); item.target = self; sub.addItem(item) }
            delete.submenu = sub; presets.menu?.addItem(.separator()); presets.menu?.addItem(delete)
        }
    }

    static func checkerboard(_ rect: NSRect, cell: CGFloat = 6) {
        NSColor.white.setFill(); rect.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        for y in stride(from: rect.minY, to: rect.maxY, by: cell) {
            for x in stride(from: rect.minX, to: rect.maxX, by: cell) where Int((x - rect.minX) / cell + (y - rect.minY) / cell) % 2 == 0 {
                NSRect(x: x, y: y, width: cell, height: cell).intersection(rect).fill()
            }
        }
    }
    private static func positionGlyph(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: true) { r in
            let frame = r.insetBy(dx: 1, dy: 1)
            NSColor.black.setStroke(); let outline = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4); outline.lineWidth = 1.2; outline.stroke()
            let w = frame.width * 0.45, h = frame.height * 0.45
            let x = frame.minX + 3 + CGFloat(index % 3) * (frame.width - 6 - w) / 2, y = frame.minY + 3 + CGFloat(index / 3) * (frame.height - 6 - h) / 2
            NSColor.black.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Rounded thumbnail that shows an accent ring when it matches the current background.
final class SwatchButton: NSButton {
    var isSelected = false { didSet { if isSelected != oldValue { Anim.run(0.15) { needsDisplay = true; ring.animator().alphaValue = isSelected ? 1 : 0 } } } }
    private let ring = NSView()
    private let handler: () -> Void
    init(size: CGFloat, round: Bool, dashed: Bool = false, action: @escaping () -> Void) {
        handler = action
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false; imageScaling = .scaleAxesIndependently; target = self; self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true; heightAnchor.constraint(equalToConstant: size).isActive = true
        let radius = round ? size / 2 : size * 0.24
        wantsLayer = true; layer?.cornerRadius = radius; layer?.masksToBounds = true
        if dashed {
            imageScaling = .scaleNone; layer?.masksToBounds = false
            let border = CAShapeLayer(); border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
            border.fillColor = nil; border.strokeColor = NSColor.tertiaryLabelColor.cgColor; border.lineDashPattern = [4, 3]; border.lineWidth = 1.5
            layer?.addSublayer(border)
        }
        ring.frame = bounds; ring.wantsLayer = true; ring.alphaValue = 0
        ring.layer?.cornerRadius = radius; ring.layer?.borderWidth = 2.5; ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(ring)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
