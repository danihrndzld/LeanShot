import AppKit

final class EditorTests {
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
        print("8 regression tests passed: crop, rotate/flip, undo/redo, projects, redaction, backgrounds, filenames, history")
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
