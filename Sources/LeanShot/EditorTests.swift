import AppKit
import UniformTypeIdentifiers
import AVFoundation
import ImageIO
import CoreImage

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
        let timeline = MotionTimeline(samples: [MotionSample(time: 0, x: 0.25, y: 0.75, click: false), MotionSample(time: 0.4, x: 0.25, y: 0.75, click: true), MotionSample(time: 1, x: 0.75, y: 0.25, click: false)])
        let video = try await VideoEditor.videoComposition(composition, aspect: 2, background: 2, motion: timeline, start: 0.2, rate: 2)
        checkEqual(video.renderSize.width, video.renderSize.height)
        let instruction = video.instructions[0] as! AVMutableVideoCompositionInstruction
        let layer = instruction.layerInstructions[0]
        var from = CGAffineTransform.identity, to = CGAffineTransform.identity, range = CMTimeRange.zero
        check(layer.getTransformRamp(for: CMTime(seconds: 0.1, preferredTimescale: 600), start: &from, end: &to, timeRange: &range))
        checkGreater(to.a, 1, "Smart zoom did not enlarge the source around a click")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = output; session.outputFileType = .mp4; session.videoComposition = video
        await session.export(); guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        let saved = AVURLAsset(url: output)
        let savedDuration = try await saved.load(.duration).seconds
        check(abs(savedDuration - 0.3) < 0.05, "MP4 output duration differs")
        let track = try await saved.loadTracks(withMediaType: .video).first!
        let dimensions = try await track.load(.naturalSize)
        checkEqual(dimensions.width, dimensions.height)
        var cursorTimeline = timeline; cursorTimeline.sourceSize = CGSize(width: 160, height: 120)
        let effects = VideoEffects(motion: cursorTimeline, zoom: timeline, start: 0.2, rate: 2, aspect: 2, blur: true, cursorStyle: 3, cursorScale: 1.5)
        try await VideoEditor.exportGIF(asset: saved, video: effects.composition(for: saved), to: gif)
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
        print("Testing redaction"); tests.testOpaqueRedactionExportsBlackPixels(); tests.testRedactionStylesObscureOnlyTheirRect()
        print("Testing backgrounds"); tests.testBackgroundAspectAndTransparentPadding()
        tests.testCaptureFilenamesNeverCollide()
        // Browsers and design tools read public.png; TIFF stays for older Cocoa apps.
        let board = NSPasteboard(name: NSPasteboard.Name("LeanShot-test-\(UUID().uuidString)"))
        Clipboard.copy(tests.fixture(), to: board)
        check(board.types?.contains(.png) == true && board.types?.contains(.tiff) == true, "clipboard types: \(board.types ?? [])")
        check(NSImage(data: board.data(forType: .png) ?? Data())?.size == NSSize(width: 100, height: 60), "lazy PNG must decode at 1x size")
        board.releaseGlobally()
        // Save As formats decode back at the same Retina pixel size.
        let cg = tests.fixture().cgImage(forProposedRect: nil, context: nil, hints: nil)!
        for type in [UTType.png, .jpeg, .heic] {
            let data = ImageTools.encode(cg, pointWidth: 100, as: type)
            checkEqual(data.flatMap { NSBitmapImageRep(data: $0)?.pixelsWide }, 200, "\(type.identifier) round trip")
        }
        // One key, one action: shortcut and tool-key tables must not collide.
        checkEqual(Set(EditorShortcut.allCases.map(\.display)).count, EditorShortcut.allCases.count)
        checkEqual(Set(Tool.visible.map(\.key)).count, Tool.visible.count)
        try tests.testHistoryFiltersFilesAndPreservesOriginals()
        tests.testScrollingOverlapAndDuplicates()
        try tests.testMotionTimeline()
        tests.testCursorEffects()
        try tests.testOverlayReleasesWindow()
        tests.testOverlappingSpotlights()
        tests.testShapesEditableWithAnyTool()
        print("15 regression tests passed: crop, rotate/flip, undo/redo, projects, redaction, redaction styles, backgrounds, filenames, history, scrolling, motion tracking, cursor effects, overlay lifecycle, spotlights, shape editing")
    }
    func fixture() -> NSImage {
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
        var background = ShotBackground(); background.customImage = Data([1, 2]); background.blur = 40; background.position = 2
        try ShotProject(canvas: canvas, background: background).write(url)
        let project = try ShotProject.read(url)
        checkEqual(project.background, background, "Project lost its background")
        let image = try project.decodedImage()
        checkEqual(ImageTools.pixelSize(image), NSSize(width: 200, height: 120))
        checkEqual(image.size, NSSize(width: 100, height: 60))
        checkEqual(project.canvasSize, NSSize(width: 50, height: 30))
        checkEqual(project.marks[0].text, "Campaign"); checkEqual(project.marks[0].style, 6)
        checkNotNil(project.marks[1].imageData)
        var unknown = project; unknown.version = 99
        checkThrows(try unknown.decodedImage())
        var oversized = project; oversized.canvasSize.width = CGFloat.greatestFiniteMagnitude
        checkThrows(try oversized.decodedImage())
        // Text has 7 styles; a rect may carry the arrow style older builds leaked onto every shape.
        checkThrows(try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(Mark(tool: .text, points: [.zero], color: .red, width: 4, text: "a", style: 99))))
        checkEqual(try! JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(Mark(tool: .rect, points: [.zero, CGPoint(x: 5, y: 5)], color: .red, width: 4, style: 3))).style, 3)
        let invalidMark = Mark(tool: .arrow, points: [], color: .red, width: 4)
        checkThrows(try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(invalidMark)))
    }
    func testOpaqueRedactionExportsBlackPixels() {
        let canvas = Canvas(image: fixture())
        canvas.marks = [Mark(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .red, width: 4)]
        let pixel = color(canvas.export(), 40, 80)
        checkLess(pixel.redComponent, 0.01); checkLess(pixel.greenComponent, 0.01); checkEqual(pixel.alphaComponent, 1)
    }
    /// Every redaction style must change the pixels it covers (red bleeds into white here) and leave the rest alone.
    func testRedactionStylesObscureOnlyTheirRect() {
        for style in Tool.redactions.indices {
            let canvas = Canvas(image: fixture())
            canvas.marks = [Mark(tool: .pixelate, points: [CGPoint(x: 40, y: 10), CGPoint(x: 60, y: 50)], color: .red, width: 14, style: style)]
            let out = canvas.export(), original = fixture()
            let inside = color(out, 110, 60), outside = color(out, 60, 60) // inside starts white, next to the red edge
            if style == 3 { checkLess(inside.redComponent, 0.01) } else { checkLess(inside.greenComponent, color(original, 110, 60).greenComponent - 0.05) }
            checkEqual(outside, color(original, 60, 60))
        }
    }
    func testBackgroundAspectAndTransparentPadding() {
        var style = ShotBackground(); style.padding = 10; style.aspect = 1; style.color = [0, 0, 0, 0]; style.shadow = 0
        let result = style.apply(to: fixture())
        checkEqual(result.size, NSSize(width: 120, height: 120))
        checkEqual(ImageTools.pixelSize(result), NSSize(width: 240, height: 240))
        checkLess(color(result, 0, 0).alphaComponent, 0.01)
        checkGreater(color(result, 120, 120).alphaComponent, 0.99)
        style.inset = 5; style.position = 0 // top left on a square canvas
        let layout = style.layout(NSSize(width: 100, height: 60))
        checkEqual(layout.size, NSSize(width: 130, height: 130))
        checkEqual(layout.card, NSRect(x: 10, y: 50, width: 110, height: 70))
        checkEqual(layout.shot, NSRect(x: 15, y: 55, width: 100, height: 60))
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
    func testMotionTimeline() throws {
        let timeline = MotionTimeline(samples: [MotionSample(time: 0, x: 0, y: 0.5, click: false), MotionSample(time: 1, x: 1, y: 0.5, click: true), MotionSample(time: 2, x: 0, y: 0.5, click: false)], sourceSize: CGSize(width: 160, height: 120))
        checkEqual(timeline.position(at: 0.5), CGPoint(x: 0.5, y: 0.5))
        checkEqual(timeline.position(at: 5), CGPoint(x: 0, y: 0.5))
        checkEqual(timeline.zoom(at: 1.5, clicks: [1]), 1.5)
        checkEqual(timeline.zoom(at: 4, clicks: [1]), 1)
        let jitter = MotionTimeline(samples: [MotionSample(time: 0, x: 0, y: 0, click: false), MotionSample(time: 0.05, x: 1, y: 1, click: true)])
        checkLess(jitter.smoothed().samples[1].x, 0.5)
        check(jitter.smoothed().samples[1].click, "Smoothing lost click timing")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recording = directory.appendingPathComponent("recording.mp4"), file = MotionTimeline.url(for: recording)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(timeline).write(to: file)
        checkEqual(MotionTimeline.read(for: recording)?.samples.count, 3)
        var invalid = timeline; invalid.version = 99
        try JSONEncoder().encode(invalid).write(to: file); check(MotionTimeline.read(for: recording) == nil)
    }
    func testCursorEffects() {
        let size = CGSize(width: 160, height: 120), rect = CGRect(origin: .zero, size: size)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect)
        let motion = MotionTimeline(samples: [MotionSample(time: 0, x: 0.5, y: 0.5, click: false)], sourceSize: size)
        let effects = VideoEffects(motion: motion, zoom: nil, start: 0, rate: 1, aspect: 0, blur: false, cursorStyle: 3, cursorScale: 1)
        let context = CIContext()
        let rendered = context.createCGImage(effects.render(source, at: 0), from: rect)!
        let pixel = NSBitmapImageRep(cgImage: rendered).colorAt(x: 80, y: 60)!.usingColorSpace(.sRGB)!
        checkGreater(pixel.blueComponent, 0.6, "Editable cursor was not composited at the tracked position")
        var original = motion; original.sourceHasCursor = true
        let unchanged = VideoEffects(motion: original, zoom: nil, start: 0, rate: 1, aspect: 0, blur: false, cursorStyle: 3, cursorScale: 2)
        let result = context.createCGImage(unchanged.render(source, at: 0), from: rect)!
        let red = NSBitmapImageRep(cgImage: result).colorAt(x: 80, y: 60)!.usingColorSpace(.sRGB)!
        checkGreater(red.redComponent, 0.9); checkLess(red.blueComponent, 0.1)
    }
    func testOverlayReleasesWindow() throws {
        let url = Capture.tempURL("png"); try ImageTools.png(fixture())!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        weak var released: OverlayCard?
        autoreleasepool {
            var card: OverlayCard? = OverlayCard(url: url, screen: NSScreen.main)
            released = card; QuickAccess.close(card!); card = nil
        }
        check(released == nil, "Closed overlay retained its panel through contentView")
    }
    func testOverlappingSpotlights() {
        let canvas = Canvas(image: fixture())
        canvas.marks = [Mark(tool: .spotlight, points: [CGPoint(x: 50, y: 10), CGPoint(x: 80, y: 50)], color: .white, width: 4), Mark(tool: .spotlight, points: [CGPoint(x: 60, y: 10), CGPoint(x: 90, y: 50)], color: .white, width: 4)]
        let image = canvas.export()
        checkGreater(color(image, 140, 60).greenComponent, 0.9, "Overlapping spotlight interiors were dimmed")
        checkLess(color(image, 190, 60).greenComponent, 0.7)
    }
    func testShapesEditableWithAnyTool() {
        let canvas = Canvas(image: fixture())
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            canvas.mouseDown(with: mouse(.leftMouseDown, a.x, a.y)); canvas.mouseDragged(with: mouse(.leftMouseDragged, b.x, b.y)); canvas.mouseUp(with: mouse(.leftMouseUp, b.x, b.y))
        }
        canvas.tool = .rect
        drag(CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50))
        checkEqual(canvas.selected, 0, "A new shape must be selected for editing")
        drag(CGPoint(x: 30, y: 25), CGPoint(x: 40, y: 35)) // inside the outline: draws, does not grab
        checkEqual(canvas.marks.count, 2)
        canvas.tool = .arrow
        drag(CGPoint(x: 10, y: 30), CGPoint(x: 15, y: 30)) // on the first rect's stroke: moves it
        checkEqual(canvas.marks.count, 2); checkEqual(canvas.marks[0].rect.minX, 15)
        canvas.tool = .select
        drag(CGPoint(x: 55, y: 20), CGPoint(x: 60, y: 20)) // Select grabs a box by its interior, away from the stroke
        checkEqual(canvas.marks.count, 2); checkEqual(canvas.marks[0].rect.minX, 20)
        canvas.marks = [Mark(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 40)], color: .red, width: 4)]
        canvas.selected = 0
        drag(CGPoint(x: 80, y: 40), CGPoint(x: 90, y: 20)) // endpoint handle
        checkEqual(canvas.marks[0].points, [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 20)])
        canvas.undo(); checkEqual(canvas.marks[0].points[1], CGPoint(x: 80, y: 40))
        canvas.selected = 0
        check(canvas.duplicateSelection()); checkEqual(canvas.marks.count, 2)
        checkEqual(canvas.marks[1].points[0], CGPoint(x: 22, y: -2)); checkEqual(canvas.selected, 1)
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
private func checkGreater<T: Comparable>(_ a: T, _ b: T, _ message: String = "Expected greater value") { precondition(a > b, message) }
private func checkLess<T: Comparable>(_ a: T, _ b: T) { precondition(a < b) }
private func checkNotNil<T>(_ value: T?) { precondition(value != nil) }
private func checkThrows<T>(_ value: @autoclosure () throws -> T) { do { _ = try value(); preconditionFailure("Expected error") } catch {} }
