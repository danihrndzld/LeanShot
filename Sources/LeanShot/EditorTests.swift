import AppKit
import AVFoundation
import ImageIO

final class EditorTests {
    static func runVideo() async throws {
        let url = Capture.tempURL("mov"), output = Capture.tempURL("mp4"), gif = Capture.tempURL("gif")
        defer { for file in [url, output, gif] { try? FileManager.default.removeItem(at: file) } }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
        writer.add(input); check(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = buffer!; CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            CVPixelBufferUnlockBaseAddress(pixel, []); check(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished(); await writer.finishWriting(); checkEqual(writer.status, .completed)
        let composition = try await VideoEditor.composition(url: url, start: 0.2, end: 0.8, rate: 2, muted: true)
        let length = try await composition.load(.duration).seconds
        check(abs(length - 0.3) < 0.01, "Trim / speed produced wrong duration")
        checkEqual(try await composition.loadTracks(withMediaType: .audio).count, 0)
        let video = try await VideoEditor.videoComposition(composition, aspect: 2, background: 2)
        checkEqual(video.renderSize.width, video.renderSize.height)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = output; session.outputFileType = .mp4; session.videoComposition = video
        await session.export(); guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        let saved = AVURLAsset(url: output)
        let savedDuration = try await saved.load(.duration).seconds
        check(abs(savedDuration - 0.3) < 0.05, "MP4 output duration differs")
        let track = try await saved.loadTracks(withMediaType: .video).first!
        let dimensions = try await track.load(.naturalSize)
        checkEqual(dimensions.width, dimensions.height)
        try await VideoEditor.exportGIF(asset: composition, video: video, to: gif)
        let decoded = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        checkEqual(CGImageSourceGetCount(decoded), 3)
        checkNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        print("Video regression passed: real H.264 fixture → trim / speed / square MP4 + 3-frame GIF")
    }
    static func run() throws {
        _ = NSApplication.shared
        let tests = EditorTests()
        print("Testing Retina crop"); tests.testCropPreservesRetinaPixelsAndContent()
        print("Testing rotate / flip"); tests.testRotateRoundTripAndFlip()
        print("Testing undo / redo"); tests.testImageChangesAndInsertionsUndoAndRedo()
        print("Testing editable projects"); try tests.testProjectRoundTripPreservesEditableLayersAndDPI()
        print("Testing redaction"); tests.testOpaqueRedactionExportsBlackPixels()
        print("Testing backgrounds"); tests.testBackgroundAspectAndTransparentPadding()
        tests.testCaptureFilenamesNeverCollide()
        try tests.testHistoryFiltersFilesAndPreservesOriginals()
        tests.testScrollingOverlapAndDuplicates()
        print("9 regression tests passed: crop, rotate/flip, undo/redo, projects, redaction, backgrounds, filenames, history, scrolling")
    }
    private func fixture() -> NSImage {
        ImageTools.render(size: NSSize(width: 100, height: 60), pixels: NSSize(width: 200, height: 120)) { r in
            NSColor.white.setFill(); r.fill()
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 50, height: 60).fill()
        }
    }
    private func color(_ image: NSImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(data: ImageTools.png(image)!)!.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    func testCropPreservesRetinaPixelsAndContent() {
        let image = ImageTools.crop(fixture(), to: NSRect(x: 0, y: 0, width: 40, height: 30))
        checkEqual(image.size, NSSize(width: 40, height: 30))
        checkEqual(ImageTools.pixelSize(image), NSSize(width: 80, height: 60))
        checkGreater(color(image, 40, 30).redComponent, 0.9)
        let pixel = color(image, 40, 30)
        precondition(pixel.greenComponent < 0.3, "crop pixel: \(pixel), reps: \(image.representations)")
    }
    func testRotateRoundTripAndFlip() {
        let image = fixture()
        let left = ImageTools.rotate(image, clockwise: false)
        checkEqual(left.size, NSSize(width: 60, height: 100))
        checkEqual(ImageTools.pixelSize(left), NSSize(width: 120, height: 200))
        let back = ImageTools.rotate(left, clockwise: true)
        checkLess(color(back, 20, 50).greenComponent, 0.3)
        checkGreater(color(back, 180, 50).greenComponent, 0.9)
        let flip = ImageTools.flip(image, horizontal: true)
        checkGreater(color(flip, 20, 50).greenComponent, 0.9)
        checkLess(color(flip, 180, 50).greenComponent, 0.3)
    }
    func testImageChangesAndInsertionsUndoAndRedo() {
        let canvas = Canvas(image: fixture())
        canvas.insertImage(fixture())
        checkEqual(canvas.marks.count, 1)
        canvas.replaceImage(ImageTools.rotate(canvas.export(), clockwise: true))
        checkEqual(canvas.image.size.width, 60)
        check(canvas.marks.isEmpty)
        canvas.undo()
        checkEqual(canvas.image.size.width, 100)
        checkEqual(canvas.marks.count, 1)
        canvas.undo(); check(canvas.marks.isEmpty)
        canvas.redo(); checkEqual(canvas.marks.count, 1)
        canvas.insertImage(fixture()); canvas.redo()
        checkEqual(canvas.marks.count, 2, "New edit must discard redo history")
    }
    func testProjectRoundTripPreservesEditableLayersAndDPI() throws {
        let canvas = Canvas(image: fixture(), size: NSSize(width: 50, height: 30))
        canvas.marks = [Mark(tool: .text, points: [CGPoint(x: 4, y: 5)], color: .systemPink, width: 4, text: "Campaign", style: 6)]
        canvas.insertImage(fixture())
        let url = Capture.tempURL("leanshot"); defer { try? FileManager.default.removeItem(at: url) }
        try ShotProject(canvas: canvas).write(url)
        let project = try ShotProject.read(url)
        let image = try project.decodedImage()
        checkEqual(ImageTools.pixelSize(image), NSSize(width: 200, height: 120))
        checkEqual(image.size, NSSize(width: 100, height: 60))
        checkEqual(project.canvasSize, NSSize(width: 50, height: 30))
        checkEqual(project.marks[0].text, "Campaign"); checkEqual(project.marks[0].style, 6)
        checkNotNil(project.marks[1].imageData)
        var unknown = project; unknown.version = 99
        checkThrows(try unknown.decodedImage())
    }
    func testOpaqueRedactionExportsBlackPixels() {
        let canvas = Canvas(image: fixture())
        canvas.marks = [Mark(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .red, width: 4)]
        let pixel = color(canvas.export(), 40, 80)
        checkLess(pixel.redComponent, 0.01); checkLess(pixel.greenComponent, 0.01); checkEqual(pixel.alphaComponent, 1)
    }
    func testBackgroundAspectAndTransparentPadding() {
        var style = BackgroundStyle(); style.padding = 10; style.aspect = 1; style.palette = 18; style.shadow = false
        let result = style.apply(to: fixture())
        checkEqual(result.size, NSSize(width: 120, height: 120))
        checkEqual(ImageTools.pixelSize(result), NSSize(width: 240, height: 240))
        checkLess(color(result, 0, 0).alphaComponent, 0.01)
        checkGreater(color(result, 120, 120).alphaComponent, 0.99)
    }
    func testCaptureFilenamesNeverCollide() {
        checkNotEqual(Capture.newURL("png"), Capture.newURL("png"))
    }
    func testScrollingOverlapAndDuplicates() {
        let document = ImageTools.render(size: NSSize(width: 240, height: 240)) { _ in
            for y in 0..<40 { for x in 0..<40 {
                let value = CGFloat((x * 43 + y * 71 + x * y * 13) % 251) / 250
                NSColor(srgbRed: value, green: value, blue: value, alpha: 1).setFill()
                NSRect(x: x * 6, y: y * 6, width: 6, height: 6).fill()
            } }
        }
        for horizontal in [false, true] {
            let a = ImageTools.crop(document, to: horizontal ? CGRect(x: 0, y: 0, width: 120, height: 120) : CGRect(x: 0, y: 120, width: 120, height: 120))
            let b = ImageTools.crop(document, to: horizontal ? CGRect(x: 60, y: 0, width: 120, height: 120) : CGRect(x: 0, y: 60, width: 120, height: 120))
            guard let overlap = Stitcher.overlap(a, b, horizontal: horizontal) else { preconditionFailure("Scrolling match not found") }
            check(abs(overlap - 60) < 2, "Wrong overlap: \(overlap)")
            checkEqual(Stitcher.overlap(a, a, horizontal: horizontal), 120)
            let result = Stitcher.append(b, to: a, overlap: overlap, horizontal: horizontal)
            check(abs((horizontal ? result.size.width : result.size.height) - 180) < 2, "Stitched length differs from the source document")
            checkEqual(horizontal ? result.size.height : result.size.width, 120)
        }
    }
    func testHistoryFiltersFilesAndPreservesOriginals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["capture.png", "recording.mp4", "notes.txt", "edit.leanshot"] { try Data().write(to: folder.appendingPathComponent(name)) }
        checkEqual(Set(CaptureHistory.files(in: folder).map(\.lastPathComponent)), ["capture.png", "recording.mp4", "edit.leanshot"])
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
    }
}

private func check(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed", file: StaticString = #file, line: UInt = #line) { precondition(value(), message, file: file, line: line) }
private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "Values differ", file: StaticString = #file, line: UInt = #line) { precondition(a == b, "\(message): \(a) != \(b)", file: file, line: line) }
private func checkNotEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a != b) }
private func checkGreater<T: Comparable>(_ a: T, _ b: T) { precondition(a > b) }
private func checkLess<T: Comparable>(_ a: T, _ b: T) { precondition(a < b) }
private func checkNotNil<T>(_ value: T?) { precondition(value != nil) }
private func checkThrows<T>(_ value: @autoclosure () throws -> T) { do { _ = try value(); preconditionFailure("Expected error") } catch {} }
