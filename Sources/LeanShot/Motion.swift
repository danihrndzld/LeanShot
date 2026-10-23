import AppKit

struct MotionSample: Codable, Sendable {
    var time: Double
    var x: Double
    var y: Double // bottom-left normalized source coordinates
    var click: Bool
    var inside = true
}

struct MotionTimeline: Codable, Sendable {
    var version = 1
    var samples: [MotionSample]
    var sourceHasCursor = false
    var sourceSize = CGSize.zero

    static func url(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".leanshot-motion", isDirectory: true).appendingPathComponent(recording.lastPathComponent + ".json")
    }
    static func read(for recording: URL) -> MotionTimeline? {
        guard let data = try? Data(contentsOf: url(for: recording)), let timeline = try? JSONDecoder().decode(Self.self, from: data), timeline.version == 1,
              timeline.sourceSize.width.isFinite, timeline.sourceSize.height.isFinite, (1...100_000).contains(timeline.sourceSize.width), (1...100_000).contains(timeline.sourceSize.height),
              !timeline.samples.isEmpty, timeline.samples.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && (0...1).contains($0.x) && $0.y.isFinite && (0...1).contains($0.y) }),
              zip(timeline.samples, timeline.samples.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return nil }
        return timeline
    }
    func smoothed() -> MotionTimeline {
        var previous: MotionSample?
        return MotionTimeline(samples: samples.map { sample in
            var value = sample
            if let previous {
                let alpha = 1 - exp(-max(0.001, sample.time - previous.time) / 0.12)
                value.x = previous.x + (sample.x - previous.x) * alpha; value.y = previous.y + (sample.y - previous.y) * alpha
            }
            previous = value; return value
        }, sourceHasCursor: sourceHasCursor, sourceSize: sourceSize)
    }
    func isInside(at time: Double) -> Bool {
        var low = 0, high = samples.count
        while low < high { let mid = (low + high) / 2; if samples[mid].time <= time { low = mid + 1 } else { high = mid } }
        return samples.isEmpty ? false : samples[max(0, low - 1)].inside
    }
    func position(at time: Double) -> CGPoint {
        guard let first = samples.first else { return CGPoint(x: 0.5, y: 0.5) }
        var low = 0, high = samples.count
        while low < high { let mid = (low + high) / 2; if samples[mid].time <= time { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return CGPoint(x: first.x, y: first.y) }
        let a = samples[low - 1]
        guard low < samples.count else { return CGPoint(x: a.x, y: a.y) }
        let b = samples[low], fraction = min(1, max(0, (time - a.time) / max(0.001, b.time - a.time)))
        return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }
    func zoom(at time: Double, clicks: [Double]) -> CGFloat {
        var amount = 0.0
        for click in clicks where time >= click - 0.25 && time <= click + 1.8 {
            let elapsed = time - click
            let value = elapsed < 0.3 ? (elapsed + 0.25) / 0.55 : elapsed < 1.25 ? 1 : (1.8 - elapsed) / 0.55
            let t = min(1, max(0, value)); amount = max(amount, t * t * (3 - 2 * t))
        }
        return 1 + CGFloat(amount) * 0.5
    }
}

final class MotionRecorder {
    private var timer: Timer?
    private var monitor: Any?
    private var samples: [MotionSample] = []
    private var started: TimeInterval = 0
    private var bounds = CGRect.zero
    func start(in bounds: CGRect) {
        self.bounds = bounds; samples = []; started = ProcessInfo.processInfo.systemUptime
        sample(click: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.sample(click: false) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.sample(click: true) }
    }
    private func sample(click: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let p = NSEvent.mouseLocation
        samples.append(MotionSample(time: ProcessInfo.processInfo.systemUptime - started, x: min(1, max(0, (p.x - bounds.minX) / bounds.width)), y: min(1, max(0, (p.y - bounds.minY) / bounds.height)), click: click && bounds.contains(p), inside: bounds.contains(p)))
    }
    func finish(to recording: URL?, sourceHasCursor: Bool) {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        defer { samples = []; bounds = .zero }
        guard let recording, !samples.isEmpty else { return }
        do {
            let destination = MotionTimeline.url(for: recording)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(MotionTimeline(samples: samples, sourceHasCursor: sourceHasCursor, sourceSize: bounds.size)).write(to: destination, options: .atomic)
        } catch { Toast.show("Video saved; could not save zoom tracking data") }
    }
}
