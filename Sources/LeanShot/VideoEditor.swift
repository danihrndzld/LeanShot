import AppKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage

final class VideoEditor: NSWindow, NSWindowDelegate {
    private static var windows: [VideoEditor] = []
    private let url: URL
    private let playerView = AVPlayerView()
    private let startField = NSTextField(string: "0")
    private let endField = NSTextField(string: "0")
    private let speed = NSPopUpButton()
    private let aspect = NSPopUpButton()
    private let background = NSPopUpButton()
    private let mute = NSButton(checkboxWithTitle: "Mute audio", target: nil, action: nil)
    private let smartZoom = NSButton(checkboxWithTitle: "Smart zoom", target: nil, action: nil)
    private let smoothTracking = NSButton(checkboxWithTitle: "Smooth tracking", target: nil, action: nil)
    private let motionBlur = NSButton(checkboxWithTitle: "Motion blur", target: nil, action: nil)
    private var motion: MotionTimeline?
    private let progress = NSTextField(labelWithString: "Loading video…")
    private var duration: Double = 0
    private var exporting = false
    private let cursorStyle = NSPopUpButton()
    private let cursorSize = NSPopUpButton()
    private let smoothCursor = NSButton(checkboxWithTitle: "Smooth cursor", target: nil, action: nil)
    /// Seconds in the user's locale ("1,50" in es-GT); parsing also accepts a dot.
    private static let seconds: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; return f }()
    private static func parse(_ text: String) -> Double? {
        seconds.number(from: text)?.doubleValue ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    static func open(_ url: URL) {
        let w = VideoEditor(url: url); windows.append(w)
        if let screen = NSScreen.underPointer?.visibleFrame {
            w.minSize = NSSize(width: min(760, screen.width * 0.9), height: min(620, screen.height * 0.85))
            w.setContentSize(NSSize(width: min(960, screen.width * 0.9), height: min(740, screen.height * 0.85)))
        }
        if !w.setFrameUsingName("VideoEditor") { w.centerOnPointerScreen() }; w.setFrameAutosaveName("VideoEditor")
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
    private init(url: URL) {
        self.url = url
        super.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Edit Recording — \(url.lastPathComponent)"; delegate = self; isReleasedWhenClosed = false
        minSize = NSSize(width: 760, height: 620)
        guard let content = contentView else { return }
        playerView.frame = NSRect(x: 20, y: 258, width: 920, height: 462)
        playerView.autoresizingMask = [.width, .height]; playerView.player = AVPlayer(url: url); playerView.controlsStyle = .floating
        content.addSubview(playerView)
        let row = NSStackView(frame: NSRect(x: 20, y: 204, width: 920, height: 32)); row.spacing = 12; row.autoresizingMask = [.width]
        // "Set" takes the playhead, so trimming is scrub-then-click instead of reading times off the player.
        func playheadButton(_ field: NSTextField) -> NSButton {
            let b = ClosureButton(frame: .zero) { [weak self] in
                if let t = self?.playerView.player?.currentTime().seconds, t.isFinite { field.stringValue = Self.seconds.string(from: NSNumber(value: t)) ?? "\(t)" }
            }
            b.title = "Set"; b.bezelStyle = .rounded; b.toolTip = "Use the playhead position"; return b
        }
        row.addArrangedSubview(NSTextField(labelWithString: "Trim from (s)")); startField.widthAnchor.constraint(equalToConstant: 70).isActive = true; row.addArrangedSubview(startField); row.addArrangedSubview(playheadButton(startField))
        row.addArrangedSubview(NSTextField(labelWithString: "to")); endField.widthAnchor.constraint(equalToConstant: 70).isActive = true; row.addArrangedSubview(endField); row.addArrangedSubview(playheadButton(endField))
        speed.addItems(withTitles: ["0.5×", "1×", "1.5×", "2×"]); speed.selectItem(at: 1); row.addArrangedSubview(speed)
        row.addArrangedSubview(mute); content.addSubview(row)
        let style = NSStackView(frame: NSRect(x: 20, y: 158, width: 920, height: 32)); style.spacing = 12; style.autoresizingMask = [.width]
        aspect.addItems(withTitles: ["Original", "Landscape 16:9", "Square", "Portrait 9:16"])
        background.addItems(withTitles: ["Black", "White", "Lavender", "Ocean", "Peach", "Mint"])
        style.addArrangedSubview(NSTextField(labelWithString: "Format")); style.addArrangedSubview(aspect)
        style.addArrangedSubview(NSTextField(labelWithString: "Background")); style.addArrangedSubview(background); content.addSubview(style)
        let effects = NSStackView(frame: NSRect(x: 20, y: 118, width: 920, height: 32)); effects.spacing = 16; effects.autoresizingMask = [.width]
        effects.addArrangedSubview(smartZoom); effects.addArrangedSubview(smoothTracking); effects.addArrangedSubview(motionBlur); content.addSubview(effects); smoothTracking.state = .on
        motion = MotionTimeline.read(for: url); smartZoom.isEnabled = motion != nil; smoothTracking.isEnabled = motion != nil
        motionBlur.isEnabled = motion != nil
        let cursorRow = NSStackView(frame: NSRect(x: 20, y: 78, width: 920, height: 32)); cursorRow.spacing = 12; cursorRow.autoresizingMask = [.width]
        cursorStyle.addItems(withTitles: ["Original cursor", "White arrow", "Black arrow", "Accent dot"])
        cursorSize.addItems(withTitles: ["1×", "1.5×", "2×"]); smoothCursor.state = .on
        cursorRow.addArrangedSubview(NSTextField(labelWithString: "Cursor")); cursorRow.addArrangedSubview(cursorStyle); cursorRow.addArrangedSubview(cursorSize); cursorRow.addArrangedSubview(smoothCursor); content.addSubview(cursorRow)
        let editable = motion != nil && motion?.sourceHasCursor == false
        cursorStyle.isEnabled = editable; cursorSize.isEnabled = editable; smoothCursor.isEnabled = editable
        cursorStyle.toolTip = "Record with the pointer disabled to replace, resize and smooth it at export"
        smartZoom.toolTip = "Cursor-following zooms around clicks in LeanShot display/area recordings"
        progress.frame = NSRect(x: 20, y: 24, width: 500, height: 24); progress.autoresizingMask = [.width]; content.addSubview(progress)
        for (i, title) in ["Export MP4…", "Export GIF…"].enumerated() {
            let b = ClosureButton(frame: NSRect(x: 640 + i * 154, y: 20, width: 144, height: 32)) { [weak self] in self?.export(gif: i == 1) }
            b.title = title; b.bezelStyle = .rounded; b.autoresizingMask = [.minXMargin]; content.addSubview(b)
        }
        Task { @MainActor in
            do {
                duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                endField.stringValue = Self.seconds.string(from: NSNumber(value: duration)) ?? "\(duration)"; progress.stringValue = String(format: "%.1f seconds · Original capture stays intact", duration)
            } catch { progress.stringValue = error.localizedDescription }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func export(gif: Bool) {
        guard !exporting else { return NSSound.beep() }
        guard let start = Self.parse(startField.stringValue), let end = Self.parse(endField.stringValue), start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.02 else {
            Toast.show("Choose valid start and end times within the recording"); return
        }
        let p = NSSavePanel(); p.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        p.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (edited)." + (gif ? "gif" : "mp4")
        p.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let destination = p.url else { return }
            guard destination.standardizedFileURL != self.url.standardizedFileURL else { Toast.show("Choose a different file to preserve your recording"); return }
            let rate = [0.5, 1.0, 1.5, 2.0][self.speed.indexOfSelectedItem]
            self.exporting = true; self.progress.stringValue = "Exporting…"; self.playerView.player?.pause()
            let aspect = self.aspect.indexOfSelectedItem, bg = self.background.indexOfSelectedItem, muted = self.mute.state == .on
            let motion = self.smartZoom.state == .on ? (self.smoothTracking.state == .on ? self.motion?.smoothed() : self.motion) : nil
            let blur = self.motionBlur.state == .on
            let cursorStyle = self.cursorStyle.indexOfSelectedItem, cursorScale = [1.0, 1.5, 2.0][self.cursorSize.indexOfSelectedItem]
            let cursorMotion = self.smoothCursor.state == .on ? self.motion?.smoothed() : self.motion
            let temporary = Capture.tempURL(gif ? "gif" : "mp4")
            let intermediate = Capture.tempURL("mp4")
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: intermediate) }
                do {
                    let composition = try await Self.composition(url: self.url, start: start, end: end, rate: rate, muted: muted)
                    let video = try await Self.videoComposition(composition, aspect: aspect, background: bg, motion: motion, start: start, rate: rate)
                    var exportAsset: AVAsset = composition, exportVideo = video
                    if let cursorMotion, blur && motion != nil || cursorStyle > 0 {
                        try await Self.exportMP4(asset: composition, video: video, to: intermediate)
                        let asset = AVURLAsset(url: intermediate)
                        _ = try await asset.load(.duration); _ = try await asset.loadTracks(withMediaType: .video)
                        let effects = VideoEffects(motion: cursorMotion, zoom: motion, start: start, rate: rate, aspect: aspect, blur: blur, cursorStyle: cursorStyle, cursorScale: cursorScale)
                        exportAsset = asset; exportVideo = effects.composition(for: asset)
                    }
                    if gif {
                        try await Self.exportGIF(asset: exportAsset, video: exportVideo, to: temporary) { [weak self] percent in self?.progress.stringValue = "Exporting GIF… \(percent)%" }
                    }
                    else {
                        try await Self.exportMP4(asset: exportAsset, video: exportVideo, to: temporary)
                    }
                    // Commit only a fully finished export; cancellation/errors leave destination unchanged.
                    try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: destination, options: .atomic)
                    self.progress.stringValue = "Exported \(destination.lastPathComponent)"; QuickAccess.show(destination)
                } catch { self.progress.stringValue = "Export failed"; NSAlert(error: error).runModal() }
                try? FileManager.default.removeItem(at: temporary); self.exporting = false
            }
        }
    }
    static func exportMP4(asset: AVAsset, video: AVVideoComposition, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw CocoaError(.featureUnsupported) }
        session.outputURL = url; session.outputFileType = .mp4; session.videoComposition = video; session.shouldOptimizeForNetworkUse = true
        await session.export(); guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func composition(url: URL, start: Double, end: Double, rate: Double, muted: Bool) async throws -> AVMutableComposition {
        let source = AVURLAsset(url: url), composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let video = try await source.loadTracks(withMediaType: .video)
        guard !video.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let tracks = muted ? video : video + (try await source.loadTracks(withMediaType: .audio))
        for track in tracks {
            guard let inserted = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try inserted.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video { inserted.preferredTransform = try await track.load(.preferredTransform) }
        }
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: CMTime(seconds: (end - start) / rate, preferredTimescale: 600))
        return composition
    }
    static func videoComposition(_ asset: AVAsset, aspect: Int, background: Int, motion: MotionTimeline? = nil, start: Double = 0, rate: Double = 1) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
        var size = oriented.size
        let ratios: [CGFloat] = [0, 16 / 9, 1, 9 / 16]
        let ratio = ratios[min(max(0, aspect), 3)]
        if ratio > 0 { if size.width / size.height > ratio { size.height = size.width / ratio } else { size.width = size.height * ratio } }
        let limit = min(1, 3840 / max(size.width, size.height)); size = NSSize(width: max(2, floor(size.width * limit / 2) * 2), height: max(2, floor(size.height * limit / 2) * 2))
        let padding: CGFloat = aspect == 0 ? 0 : min(40, min(size.width, size.height) * 0.08)
        let scale = min((size.width - padding * 2) / oriented.width, (size.height - padding * 2) / oriented.height)
        let x = (size.width - oriented.width * scale) / 2, y = (size.height - oriented.height * scale) / 2
        let adjusted = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: x, y: y))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track); layer.setTransform(adjusted, at: .zero)
        let duration = try await asset.load(.duration)
        if let motion {
            let clicks = motion.samples.filter(\.click).map(\.time)
            func state(_ time: Double) -> (CGAffineTransform, CGRect) {
                let sourceTime = start + time * rate, zoom = motion.zoom(at: sourceTime, clicks: clicks)
                let point = motion.position(at: sourceTime), margin = 0.5 / zoom
                let cx = min(1 - margin, max(margin, point.x)), cy = min(1 - margin, max(margin, 1 - point.y))
                let crop = CGRect(x: (cx - margin) * natural.width, y: (cy - margin) * natural.height, width: natural.width / zoom, height: natural.height / zoom)
                let t = CGAffineTransform(scaleX: scale * zoom, y: scale * zoom).concatenating(CGAffineTransform(translationX: x - crop.minX * scale * zoom, y: y - crop.minY * scale * zoom))
                return (t, crop)
            }
            var previous = state(0); layer.setTransform(previous.0, at: .zero); layer.setCropRectangle(previous.1, at: .zero)
            var time = 0.0
            while time < duration.seconds {
                let next = min(duration.seconds, time + 0.1), current = state(next)
                let range = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), end: CMTime(seconds: next, preferredTimescale: 600))
                layer.setTransformRamp(fromStart: previous.0, toEnd: current.0, timeRange: range); layer.setCropRectangleRamp(fromStartCropRectangle: previous.1, toEndCropRectangle: current.1, timeRange: range)
                time = next; previous = current
            }
        }
        let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = CMTimeRange(start: .zero, duration: duration); instruction.layerInstructions = [layer]
        let colors: [NSColor] = [.black, .white, NSColor(srgbRed: 0.8, green: 0.77, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1), NSColor(srgbRed: 0.95, green: 0.75, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.7, green: 0.88, blue: 0.8, alpha: 1)]
        instruction.backgroundColor = colors[min(max(0, background), colors.count - 1)].cgColor
        let result = AVMutableVideoComposition(); result.renderSize = size; result.frameDuration = CMTime(value: 1, timescale: 30); result.instructions = [instruction]
        return result
    }
    static func exportGIF(asset: AVAsset, video: AVVideoComposition, to url: URL, progress: (Int) -> Void = { _ in }) async throws {
        let duration = try await asset.load(.duration).seconds, fps = 10.0
        let count = max(1, Int(ceil(duration * fps)))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset); generator.videoComposition = video
        generator.maximumSize = CGSize(width: 1280, height: 1280); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for index in 0..<count {
            let frame = try await generator.image(at: CMTime(seconds: Double(index) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(destination, frame.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            progress(Int(Double(index + 1) / Double(count) * 100))
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exporting { Toast.show("Wait for the export to finish"); return false }; return true
    }
    func windowWillClose(_ notification: Notification) { playerView.player?.pause(); playerView.player = nil; Self.windows.removeAll { $0 === self } }
}
