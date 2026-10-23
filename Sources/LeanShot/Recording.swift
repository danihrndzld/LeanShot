import AppKit
import ScreenCaptureKit
import AVFoundation

@available(macOS 15.0, *)
final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static let shared = Recorder()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var timer: Timer?
    private var startTime = Date()
    private var didFinish: ((URL?) -> Void)?
    var onStatus: ((String?) -> Void)?
    private(set) var busy = false
    private var recording = false
    private let decorations = RecordingDecorations()
    private let motion = MotionRecorder()
    private var recordingBounds: CGRect?
    private var sourceHasCursor = false
    private let focus = FocusAutomation()
    private var termination: ((Bool) -> Void)?

    func chooseWindow(completion: @escaping (URL?) -> Void) {
        guard !busy, Capture.current == nil, !RegionSelector.isSelecting else { NSSound.beep(); return }
        busy = true
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 100 && $0.frame.height > 60 && $0.windowLayer == 0 }
                guard !windows.isEmpty else { throw CocoaError(.fileNoSuchFile) }
                let alert = NSAlert(); alert.messageText = "Record a Window"; alert.informativeText = "The selected window is recorded even when other windows cover it."
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
                // addItem deduplicates titles: create each item explicitly to preserve indices.
                for window in windows { picker.menu?.addItem(NSMenuItem(title: "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Untitled")", action: nil, keyEquivalent: "")) }
                picker.selectItem(at: 0); alert.accessoryView = picker; alert.addButton(withTitle: "Record"); alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { busy = false; return }
                let window = windows[picker.indexOfSelectedItem]
                recordingBounds = nil
                busy = false
                await start(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, size: window.frame.size, completion: completion)
            } catch { busy = false; NSAlert(error: error).runModal() }
        }
    }
    func startDisplay(region: ScreenRegion? = nil, completion: @escaping (URL?) -> Void) {
        guard !busy, Capture.current == nil else { NSSound.beep(); return }
        busy = true
        let screen = region?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        Task { @MainActor in
            do {
                let globalRegion = region.map { CGRect(x: $0.screen.frame.minX + $0.rect.minX, y: $0.screen.frame.minY + $0.rect.minY, width: $0.rect.width, height: $0.rect.height) }
                recordingBounds = globalRegion ?? screen?.frame
                try await decorations.prepare(screen: screen, region: globalRegion)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CocoaError(.featureUnsupported) }
                let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: content.windows.filter { decorations.windowIDs.contains($0.windowID) })
                let source = region.map { CGRect(x: $0.rect.minX, y: (screen?.frame.height ?? CGFloat(display.height)) - $0.rect.maxY, width: $0.rect.width, height: $0.rect.height) }
                busy = false
                await start(filter: filter, sourceRect: source, size: region?.rect.size ?? screen?.frame.size ?? display.frame.size, completion: completion)
            } catch { decorations.stop(); busy = false; NSAlert(error: error).runModal() }
        }
    }
    @MainActor private func start(filter: SCContentFilter, sourceRect: CGRect?, size: CGSize, completion: @escaping (URL?) -> Void) async {
        guard !busy else { NSSound.beep(); return }; busy = true; didFinish = completion
        do {
            onStatus?("Starting…")
            try await focus.begin()
            if Settings.recordingMicrophone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NSError(domain: "LeanShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access is disabled. Enable it in System Settings or disable microphone recording in LeanShot Settings."]) }
            }
            let config = SCStreamConfiguration()
            let scale = min(2, CGFloat(Settings.recordingResolution) / max(size.width, size.height))
            config.width = max(2, Int(size.width * scale) / 2 * 2); config.height = max(2, Int(size.height * scale) / 2 * 2)
            if let sourceRect { config.sourceRect = sourceRect }
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Settings.recordingFPS))
            config.showsCursor = Settings.captureCursor
            sourceHasCursor = config.showsCursor
            config.showMouseClicks = Settings.recordClicks && recordingBounds == nil
            config.capturesAudio = Settings.recordingAudio; config.excludesCurrentProcessAudio = true
            config.captureMicrophone = Settings.recordingMicrophone
            config.queueDepth = 5
            let destination = Capture.newURL("mp4"); url = destination
            let file = SCRecordingOutputConfiguration(); file.outputURL = destination; file.videoCodecType = .h264; file.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: file, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream; self.output = output
            try stream.addRecordingOutput(output)
            QuickAccess.hide(); onStatus?("Starting…")
            try await stream.startCapture()
        } catch { fail(error) }
    }
    func stop() {
        guard busy, recording, let stream else { NSSound.beep(); return }
        recording = false; timer?.invalidate(); onStatus?("Saving…")
        Task { @MainActor in do { try await stream.stopCapture() } catch { fail(error) } }
    }
    func stopForTermination(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard recording else { return false }
        termination = completion; stop(); return true
    }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.busy, self.output === recordingOutput else { return }
            self.recording = true; self.startTime = Date(); self.onStatus?("● 00:00")
            if let bounds = self.recordingBounds { self.motion.start(in: bounds) }
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }; let seconds = Int(Date().timeIntervalSince(self.startTime))
                self.onStatus?(String(format: "● %02d:%02d", seconds / 60, seconds % 60))
            }
        }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in guard let self, self.busy, self.output === recordingOutput else { return }; self.finish(self.url) }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { DispatchQueue.main.async { [weak self] in guard self?.output === recordingOutput else { return }; self?.fail(error) } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { [weak self] in guard self?.stream === stream else { return }; self?.fail(error) } }
    private func fail(_ error: Error) {
        guard busy else { return }
        let active = stream; finish(nil)
        Task { try? await active?.stopCapture() }
        NSAlert(error: error).runModal()
    }
    private func finish(_ result: URL?) {
        timer?.invalidate(); timer = nil; stream = nil; output = nil; url = nil; busy = false; recording = false
        decorations.stop()
        let quit = termination; termination = nil
        focus.end { quit?(result != nil) }
        motion.finish(to: result, sourceHasCursor: sourceHasCursor); recordingBounds = nil
        onStatus?(nil); QuickAccess.resume()
        let completion = didFinish; didFinish = nil; completion?(result)
    }
}
