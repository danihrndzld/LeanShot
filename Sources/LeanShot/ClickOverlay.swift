import AppKit

final class ClickOverlay: NSView {
    private var point: CGPoint?
    private var began = 0.0
    private var timer: Timer?
    func show(at point: CGPoint) {
        self.point = point; began = ProcessInfo.processInfo.systemUptime; needsDisplay = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.began > 0.5 { self.stop() } else if Settings.clickAnimated { self.needsDisplay = true }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; point = nil; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let point else { return }
        let elapsed = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.5)
        let colors: [NSColor] = [.systemPink, .systemBlue, .systemGreen, .systemYellow, .white]
        let color = colors[min(max(0, Settings.clickColor), colors.count - 1)].withAlphaComponent(Settings.clickAnimated ? 1 - elapsed : 0.8)
        let size = Settings.clickSize * (Settings.clickAnimated ? 0.65 + elapsed * 0.7 : 1)
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        color.set(); circle.lineWidth = 3
        if Settings.clickFilled { circle.fill() } else { circle.stroke() }
    }
}
