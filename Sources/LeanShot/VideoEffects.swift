import AppKit
import AVFoundation
import CoreImage

struct VideoEffects {
    let motion: MotionTimeline
    let zoom: MotionTimeline?
    let start: Double
    let rate: Double
    let aspect: Int
    let blur: Bool
    private let clicks: [Double]
    private let cursor: CIImage?
    private let hotspot: CGPoint

    init(motion: MotionTimeline, zoom: MotionTimeline?, start: Double, rate: Double, aspect: Int, blur: Bool, cursorStyle: Int, cursorScale: CGFloat) {
        self.motion = motion; self.zoom = zoom; self.start = start; self.rate = rate; self.aspect = aspect; self.blur = blur
        clicks = zoom?.samples.filter(\.click).map(\.time) ?? []
        hotspot = cursorStyle == 3 ? CGPoint(x: 14 * cursorScale, y: 16 * cursorScale) : CGPoint(x: 2 * cursorScale, y: 30 * cursorScale)
        if cursorStyle > 0, !motion.sourceHasCursor {
            let image = ImageTools.render(size: CGSize(width: 28, height: 32), pixels: CGSize(width: 28 * cursorScale, height: 32 * cursorScale)) { _ in
                if cursorStyle == 3 {
                    NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: CGRect(x: 4, y: 6, width: 20, height: 20)).fill()
                } else {
                    let path = NSBezierPath(); path.move(to: CGPoint(x: 2, y: 30))
                    for p in [CGPoint(x: 2, y: 6), CGPoint(x: 8, y: 12), CGPoint(x: 13, y: 2), CGPoint(x: 18, y: 5), CGPoint(x: 13, y: 15), CGPoint(x: 22, y: 15)] { path.line(to: p) }
                    path.close(); (cursorStyle == 1 ? NSColor.white : NSColor.black).setFill(); path.fill()
                    (cursorStyle == 1 ? NSColor.black : NSColor.white).setStroke(); path.lineWidth = 1.4; path.stroke()
                }
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { cursor = CIImage(cgImage: cg) } else { cursor = nil }
        } else { cursor = nil }
    }
    func render(_ source: CIImage, at outputTime: Double) -> CIImage {
        let time = start + outputTime * rate
        var image = source
        if blur, let zoom {
            let before = zoom.zoom(at: time - 0.025, clicks: clicks), after = zoom.zoom(at: time + 0.025, clicks: clicks)
            let radius = min(12, abs(after - before) * 75)
            if radius > 0.05 { image = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: 0]).cropped(to: source.extent) }
        }
        guard var cursor, motion.isInside(at: time), motion.sourceSize.width > 0, motion.sourceSize.height > 0 else { return image }
        let extent = source.extent, padding: CGFloat = aspect == 0 ? 0 : min(40, min(extent.width, extent.height) * 0.08)
        let scale = min((extent.width - padding * 2) / motion.sourceSize.width, (extent.height - padding * 2) / motion.sourceSize.height)
        let width = motion.sourceSize.width * scale, height = motion.sourceSize.height * scale
        var point = motion.position(at: time)
        if let zoom {
            let amount = zoom.zoom(at: time, clicks: clicks), focus = zoom.position(at: time), margin = 0.5 / amount
            let x = min(1 - margin, max(margin, focus.x)), y = min(1 - margin, max(margin, focus.y))
            point = CGPoint(x: (point.x - x + margin) * amount, y: (point.y - y + margin) * amount)
        }
        let x = extent.minX + (extent.width - width) / 2 + point.x * width
        let y = extent.minY + (extent.height - height) / 2 + point.y * height
        if blur {
            let a = motion.position(at: time - 0.025), b = motion.position(at: time + 0.025)
            let dx = (b.x - a.x) * width, dy = (b.y - a.y) * height
            let radius = min(8, hypot(dx, dy) * 0.25)
            if radius > 0.5 { cursor = cursor.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(dy, dx)]) }
        }
        let position = CGAffineTransform(translationX: x - hotspot.x, y: y - hotspot.y)
        return cursor.transformed(by: position).composited(over: image).cropped(to: source.extent)
    }
    func composition(for asset: AVAsset) -> AVVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in request.finish(with: self.render(request.sourceImage, at: request.compositionTime.seconds), context: nil) }
    }
}
