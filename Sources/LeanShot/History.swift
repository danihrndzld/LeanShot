import AppKit

final class HistoryWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var instance: HistoryWindow?
    private var files: [URL] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSPopUpButton()

    static func show() {
        let w = instance ?? HistoryWindow()
        instance = w; w.reload(); w.center(); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Capture History"; isReleasedWhenClosed = false; minSize = NSSize(width: 640, height: 340)
        guard let content = contentView else { return }
        search.frame = NSRect(x: 20, y: 468, width: 480, height: 28)
        search.placeholderString = "Search captures by name"; search.delegate = self; search.autoresizingMask = [.width, .minYMargin]
        content.addSubview(search)
        filter.frame = NSRect(x: 520, y: 468, width: 200, height: 28)
        filter.addItems(withTitles: ["All Captures", "Images", "Recordings", "Projects"])
        filter.target = self; filter.action = #selector(reload); filter.autoresizingMask = [.minXMargin, .minYMargin]; content.addSubview(filter)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 700, height: 390))
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("capture")); column.title = "Captures stored in your captures folder"; column.width = 690
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 68
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        scroll.documentView = table; content.addSubview(scroll)
        let actions: [(String, Selector)] = [("Open", #selector(openSelected)), ("Copy", #selector(copySelected)), ("Show in Finder", #selector(reveal)), ("Move to Trash", #selector(trash))]
        for (i, pair) in actions.enumerated() {
            let b = NSButton(title: pair.0, target: self, action: pair.1)
            b.frame = NSRect(x: 20 + i * 150, y: 18, width: 140, height: 30); b.bezelStyle = .rounded
            content.addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func reload() {
        let query = search.stringValue
        files = CaptureHistory.files().filter {
            let ext = $0.pathExtension.lowercased()
            let typeMatches: Bool
            switch filter.indexOfSelectedItem {
            case 1: typeMatches = ["png", "jpg", "jpeg", "gif"].contains(ext)
            case 2: typeMatches = ["mov", "mp4"].contains(ext)
            case 3: typeMatches = ext == "leanshot"
            default: typeMatches = true
            }
            return typeMatches && (query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query))
        }
        table.reloadData()
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = files[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 68))
        let thumb = DragImageView(frame: NSRect(x: 4, y: 6, width: 88, height: 56))
        thumb.url = url; thumb.image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        thumb.doubleClick = {
            if url.pathExtension == "leanshot" || NSImage(contentsOf: url) != nil { AnnotateWindow.open(url) }
            else { VideoEditor.open(url) }
        }
        thumb.imageScaling = .scaleProportionallyUpOrDown; cell.addSubview(thumb)
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.frame = NSRect(x: 108, y: 34, width: max(100, cell.bounds.width - 120), height: 20)
        name.lineBreakMode = .byTruncatingMiddle; cell.addSubview(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let detail = NSTextField(labelWithString: "\(url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12); detail.frame = NSRect(x: 108, y: 12, width: 400, height: 18)
        cell.addSubview(detail); return cell
    }
    private var selected: URL? { files.indices.contains(table.selectedRow) ? files[table.selectedRow] : nil }
    @objc private func openSelected() {
        guard let url = selected else { return }
        if url.pathExtension == "leanshot" || NSImage(contentsOf: url) != nil { AnnotateWindow.open(url) }
        else { VideoEditor.open(url) }
    }
    @objc private func copySelected() { if let url = selected { Clipboard.copy(url); Toast.show("Copied") } }
    @objc private func reveal() { if let url = selected { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func trash() {
        guard let url = selected else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); reload() }
        catch { NSAlert(error: error).runModal() }
    }
}
