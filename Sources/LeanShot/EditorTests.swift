import AppKit
import UniformTypeIdentifiers
import AVFoundation
import ImageIO
import CoreImage

/// `LeanShot --selftest`: fast in-process tests of the editor's logic. Each `test` runs one behavior, a failed
/// check records its message and line and the run goes on, and the process exits 1 when any check failed.
/// Expected values come from the README, ARCHITECTURE.md or the comment next to the check, never from the code under test.
enum EditorTests {
    fileprivate static var failures: [String] = []
    private static var passed = 0, failed = 0

    private static func begin() -> Int { failures.count }
    private static func end(_ name: String, _ before: Int) {
        if failures.count == before { passed += 1; print("PASS \(name)"); return }
        failed += 1; print("FAIL \(name)"); for failure in failures[before...] { print("  \(failure)") }
    }
    private static func test(_ name: String, _ body: () throws -> Void) {
        let before = begin()
        do { try body() } catch { failures.append("threw \(error)") }
        end(name, before)
    }
    private static func test(_ name: String, _ body: () async throws -> Void) async {
        let before = begin()
        do { try await body() } catch { failures.append("threw \(error)") }
        end(name, before)
    }

    /// Prints the summary, drops the throwaway defaults domain and exits 0 only when every test passed.
    static func finish() -> Never {
        UserDefaults().removePersistentDomain(forName: Settings.testSuite)
        print("\(passed) of \(passed + failed) regression tests passed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: Fixtures

    /// 100x60 pt at 2x: red left half, white right half.
    static func fixture() -> NSImage {
        ImageTools.render(size: NSSize(width: 100, height: 60), pixels: NSSize(width: 200, height: 120)) { r in
            NSColor.white.setFill(); r.fill()
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 50, height: 60).fill()
        }
    }
    /// The sRGB color of a pixel, counted from the top left of the image's PNG.
    private static func color(_ image: NSImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(data: ImageTools.png(image)!)!.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private static func drag(_ canvas: Canvas, _ a: CGPoint, _ b: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, a)); canvas.mouseDragged(with: mouse(.leftMouseDragged, b)); canvas.mouseUp(with: mouse(.leftMouseUp, b))
    }
    private static func canvas(tool: Tool, marks: [Mark] = []) -> Canvas {
        let canvas = Canvas(image: fixture()); canvas.tool = tool; canvas.marks = marks; return canvas
    }
    private static func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, tool: Tool = .rect, style: Int = 0) -> Mark {
        Mark(tool: tool, points: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)], color: .red, width: 4, style: style)
    }
    private static func timeline() -> MotionTimeline {
        MotionTimeline(samples: [MotionSample(time: 0, x: 0, y: 0.5, click: false), MotionSample(time: 1, x: 1, y: 0.5, click: true), MotionSample(time: 2, x: 0, y: 0.5, click: false)], sourceSize: CGSize(width: 160, height: 120))
    }
    private static func roundTrip(_ mark: Mark) throws -> Mark { try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(mark)) }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared

        // MARK: Image operations

        test("crop keeps the Retina pixel density") {
            let image = ImageTools.crop(fixture(), to: NSRect(x: 0, y: 0, width: 40, height: 30))

            checkEqual(image.size, NSSize(width: 40, height: 30)); checkEqual(ImageTools.pixelSize(image), NSSize(width: 80, height: 60))
        }
        test("crop keeps the content under the crop rect") {
            let image = ImageTools.crop(fixture(), to: NSRect(x: 0, y: 0, width: 40, height: 30))

            let pixel = color(image, 40, 30)
            checkGreater(pixel.redComponent, 0.9); checkLess(pixel.greenComponent, 0.3)
        }
        test("rotating left swaps width and height at the same density") {
            let left = ImageTools.rotate(fixture(), clockwise: false)

            checkEqual(left.size, NSSize(width: 60, height: 100)); checkEqual(ImageTools.pixelSize(left), NSSize(width: 120, height: 200))
        }
        test("rotating left then right restores the original") {
            let left = ImageTools.rotate(fixture(), clockwise: false)

            let back = ImageTools.rotate(left, clockwise: true)

            checkLess(color(back, 20, 50).greenComponent, 0.3, "left half must stay red"); checkGreater(color(back, 180, 50).greenComponent, 0.9, "right half must stay white")
        }
        test("horizontal flip mirrors the image") {
            let flip = ImageTools.flip(fixture(), horizontal: true)

            checkGreater(color(flip, 20, 50).greenComponent, 0.9, "left half must turn white"); checkLess(color(flip, 180, 50).greenComponent, 0.3, "right half must turn red")
        }
        test("export of a half-size view keeps full resolution and DPI") {
            let sut = Canvas(image: fixture(), size: NSSize(width: 50, height: 30))

            let out = sut.export()

            checkEqual(ImageTools.pixelSize(out), NSSize(width: 200, height: 120)); checkEqual(NSImage(data: ImageTools.png(out)!)!.size, NSSize(width: 100, height: 60))
        }
        test("an arrow ends exactly at its end point") {
            let arrow = Canvas.arrowPath(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)

            check(arrow.contains(CGPoint(x: 99, y: 0)), "tip stops short"); check(!arrow.contains(CGPoint(x: 101, y: 0)), "tip overshoots")
        }
        // README: Save As exports PNG, JPEG or HEIC; each decodes back at the capture's Retina pixel width.
        for type in [UTType.png, .jpeg, .heic] {
            test("Save As \(type.preferredFilenameExtension!) keeps the Retina pixel width") {
                let cg = fixture().cgImage(forProposedRect: nil, context: nil, hints: nil)!

                let data = ImageTools.encode(cg, pointWidth: 100, as: type)

                checkEqual(data.flatMap { NSBitmapImageRep(data: $0)?.pixelsWide }, 200)
            }
        }
        // README: Copy puts both PNG and TIFF on the clipboard; browsers read the PNG.
        test("copy puts PNG and TIFF on the clipboard") {
            let board = NSPasteboard(name: NSPasteboard.Name("LeanShot-test-\(UUID().uuidString)")); defer { board.releaseGlobally() }

            Clipboard.copy(fixture(), to: board)

            let types = board.pasteboardItems?.first?.types ?? []
            check(types.contains(.png), "no PNG in \(types)"); check(types.contains(.tiff), "no TIFF in \(types)")
        }
        test("the copied PNG decodes at the capture's point size") {
            let board = NSPasteboard(name: NSPasteboard.Name("LeanShot-test-\(UUID().uuidString)")); defer { board.releaseGlobally() }

            Clipboard.copy(fixture(), to: board)

            checkEqual(NSImage(data: board.data(forType: .png) ?? Data())?.size, NSSize(width: 100, height: 60))
        }

        // MARK: Undo and redo

        test("rotating the image drops the annotations") {
            let sut = Canvas(image: fixture()); sut.insertImage(fixture())

            sut.replaceImage(ImageTools.rotate(sut.export(), clockwise: true))

            checkEqual(sut.image.size.width, 60); checkEqual(sut.marks.count, 0)
        }
        test("undo after a rotation restores the image and its annotations") {
            let sut = Canvas(image: fixture()); sut.insertImage(fixture()); sut.replaceImage(ImageTools.rotate(sut.export(), clockwise: true))

            sut.undo()

            checkEqual(sut.image.size.width, 100); checkEqual(sut.marks.count, 1)
        }
        test("redo brings back an undone insertion") {
            let sut = Canvas(image: fixture()); sut.insertImage(fixture()); sut.undo()

            sut.redo()

            checkEqual(sut.marks.count, 1)
        }
        test("a new edit discards the redo history") {
            let sut = Canvas(image: fixture()); sut.insertImage(fixture()); sut.undo(); sut.insertImage(fixture())

            sut.redo()

            checkEqual(sut.marks.count, 1)
        }

        // MARK: Editable projects

        test("a project keeps the image, its DPI, the view size, every layer and the background") {
            let canvas = Canvas(image: fixture(), size: NSSize(width: 50, height: 30))
            canvas.marks = [Mark(tool: .text, points: [CGPoint(x: 4, y: 5)], color: .systemPink, width: 4, text: "Campaign", style: 6)]
            canvas.insertImage(fixture())
            var background = ShotBackground(); background.customImage = Data([1, 2]); background.blur = 40; background.position = 2
            let url = Capture.tempURL("leanshot"); defer { try? FileManager.default.removeItem(at: url) }
            try ShotProject(canvas: canvas, background: background).write(url)

            let project = try ShotProject.read(url)

            let image = try project.decodedImage()
            checkEqual(ImageTools.pixelSize(image), NSSize(width: 200, height: 120)); checkEqual(image.size, NSSize(width: 100, height: 60))
            checkEqual(project.canvasSize, NSSize(width: 50, height: 30)); checkEqual(project.background, background)
            checkEqual(project.marks.first?.text, "Campaign"); checkEqual(project.marks.first?.style, 6); checkNotNil(project.marks.last?.imageData)
        }
        test("a project from a newer version is rejected") {
            var sut = try ShotProject(canvas: Canvas(image: fixture()), background: ShotBackground()); sut.version = 99

            checkThrows(try sut.decodedImage())
        }
        test("a project with an impossible canvas size is rejected") {
            var sut = try ShotProject(canvas: Canvas(image: fixture()), background: ShotBackground()); sut.canvasSize.width = .greatestFiniteMagnitude

            checkThrows(try sut.decodedImage())
        }
        // Text has 11 styles (0 to 10); a rect may carry the arrow style older builds leaked onto every shape.
        test("a text layer with an unknown style is rejected") {
            checkThrows(try roundTrip(Mark(tool: .text, points: [.zero], color: .red, width: 4, text: "a", style: 11)))
        }
        // Project version 1 stored text size as a stroke width; the font was 12 + 3 x width points.
        test("a version 1 project opens its text at the same font size") {
            let canvas = Canvas(image: fixture()); canvas.marks = [Mark(tool: .text, points: [.zero], color: .red, width: 4, text: "a")]
            var old = try ShotProject(canvas: canvas); old.version = 1
            let url = Capture.tempURL("leanshot"); defer { try? FileManager.default.removeItem(at: url) }; try old.write(url)

            let project = try ShotProject.read(url)

            checkEqual(project.marks.first?.width, 24)
        }
        test("a rect with the leaked arrow style still opens") {
            checkEqual(try roundTrip(rect(0, 0, 5, 5, style: 3)).style, 3)
        }
        test("an arrow with a single point is rejected") {
            checkThrows(try roundTrip(Mark(tool: .arrow, points: [.zero], color: .red, width: 4)))
        }

        // MARK: Redaction

        // README: Black Bar replaces the pixels completely.
        test("a black bar exports opaque black pixels") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 30, 30, tool: .redact)])

            let pixel = color(sut.export(), 40, 80)

            checkLess(pixel.redComponent, 0.01); checkLess(pixel.greenComponent, 0.01); checkEqual(pixel.alphaComponent, 1)
        }
        // Pixel (110, 60) starts white next to the red edge, so pixelate and both blurs pull red into it.
        for (style, name) in [(0, "pixelate"), (1, "Gaussian blur"), (2, "Secure Blur")] {
            test("\(name) changes the pixels it covers") {
                let sut = canvas(tool: .arrow, marks: [Mark(tool: .pixelate, points: [CGPoint(x: 40, y: 10), CGPoint(x: 60, y: 50)], color: .red, width: 14, style: style)])

                let inside = color(sut.export(), 110, 60)

                checkLess(inside.greenComponent, 0.95)
            }
        }
        test("the Black Bar redaction style paints the pixels it covers black") {
            let sut = canvas(tool: .arrow, marks: [Mark(tool: .pixelate, points: [CGPoint(x: 40, y: 10), CGPoint(x: 60, y: 50)], color: .red, width: 14, style: 3)])

            let inside = color(sut.export(), 110, 60)

            checkLess(inside.redComponent, 0.01); checkLess(inside.greenComponent, 0.01)
        }
        for style in Tool.redactions.indices {
            test("redaction style \(Tool.redactions[style].0) leaves pixels outside its rect alone") {
                let sut = canvas(tool: .arrow, marks: [Mark(tool: .pixelate, points: [CGPoint(x: 40, y: 10), CGPoint(x: 60, y: 50)], color: .red, width: 14, style: style)])

                let outside = color(sut.export(), 60, 60)

                checkEqual(outside, color(fixture(), 60, 60))
            }
        }
        // Spotlight dims everything outside the union of its rects.
        test("overlapping spotlights keep their shared interior bright") {
            let sut = canvas(tool: .arrow, marks: [rect(50, 10, 80, 50, tool: .spotlight), rect(60, 10, 90, 50, tool: .spotlight)])

            let image = sut.export()

            checkGreater(color(image, 140, 60).greenComponent, 0.9, "interior was dimmed"); checkLess(color(image, 190, 60).greenComponent, 0.7, "outside was not dimmed")
        }

        // MARK: Backgrounds

        test("a square aspect with padding produces a square image at the same density") {
            var sut = ShotBackground(); sut.padding = 10; sut.aspect = 1; sut.color = [0, 0, 0, 0]; sut.shadow = 0

            let result = sut.apply(to: fixture())

            checkEqual(result.size, NSSize(width: 120, height: 120)); checkEqual(ImageTools.pixelSize(result), NSSize(width: 240, height: 240))
        }
        test("a transparent background leaves the padding transparent and the capture opaque") {
            var sut = ShotBackground(); sut.padding = 10; sut.aspect = 1; sut.color = [0, 0, 0, 0]; sut.shadow = 0

            let result = sut.apply(to: fixture())

            checkLess(color(result, 0, 0).alphaComponent, 0.01); checkGreater(color(result, 120, 120).alphaComponent, 0.99)
        }
        test("inset and the top-left position place the card and the capture") {
            var sut = ShotBackground(); sut.padding = 10; sut.aspect = 1; sut.inset = 5; sut.position = 0

            let layout = sut.layout(NSSize(width: 100, height: 60))

            checkEqual(layout.size, NSSize(width: 130, height: 130))
            checkEqual(layout.card, NSRect(x: 10, y: 50, width: 110, height: 70)); checkEqual(layout.shot, NSRect(x: 15, y: 55, width: 100, height: 60))
        }

        // MARK: Shape editing (README: every new shape stays selected; drag it or its blue handles)

        test("a new shape stays selected") {
            let sut = canvas(tool: .rect)

            drag(sut, CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50))

            checkEqual(sut.selected, 0)
        }
        test("dragging inside a rect's outline with the rect tool draws a new rect") {
            let sut = canvas(tool: .rect, marks: [rect(10, 10, 60, 50)])

            drag(sut, CGPoint(x: 30, y: 25), CGPoint(x: 40, y: 35))

            checkEqual(sut.marks.count, 2)
        }
        test("dragging a shape's stroke with another tool moves the shape") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 60, 50)])

            drag(sut, CGPoint(x: 10, y: 30), CGPoint(x: 15, y: 30))

            checkEqual(sut.marks.count, 1); checkEqual(sut.marks.first?.rect.minX, 15)
        }
        test("the Select tool grabs a rect by its interior") {
            let sut = canvas(tool: .select, marks: [rect(10, 10, 60, 50)])

            drag(sut, CGPoint(x: 35, y: 30), CGPoint(x: 40, y: 30)) // the center, 15 pt or more from every edge

            checkEqual(sut.marks.count, 1); checkEqual(sut.marks.first?.rect.minX, 15)
        }
        test("dragging an arrow's end handle moves only that end") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 80, 40, tool: .arrow)]); sut.selected = 0

            drag(sut, CGPoint(x: 80, y: 40), CGPoint(x: 90, y: 20))

            checkEqual(sut.marks.first?.points, [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 20)])
        }
        test("undo puts a dragged handle back") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 80, 40, tool: .arrow)]); sut.selected = 0
            drag(sut, CGPoint(x: 80, y: 40), CGPoint(x: 90, y: 20))

            sut.undo()

            checkEqual(sut.marks.first?.points, [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 40)])
        }
        // ⌘D places the copy 12 pt right and 12 pt down and selects it.
        test("duplicate adds an offset copy and selects it") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 80, 40, tool: .arrow)]); sut.selected = 0

            check(sut.duplicateSelection(), "nothing was duplicated")

            checkEqual(sut.marks.last?.points, [CGPoint(x: 22, y: -2), CGPoint(x: 92, y: 28)]); checkEqual(sut.selected, 1)
        }
        test("duplicate with nothing selected does nothing") {
            let sut = canvas(tool: .arrow, marks: [rect(10, 10, 80, 40, tool: .arrow)])

            check(!sut.duplicateSelection(), "duplicated without a selection")

            checkEqual(sut.marks.count, 1)
        }

        // README: an arrow's head sits where you start the drag.
        test("an arrow's head stays where the drag started") {
            let sut = canvas(tool: .arrow)

            drag(sut, CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 40))

            checkEqual(sut.marks.last?.points.last, CGPoint(x: 10, y: 10))
        }
        // README: the highlighter follows the text line under the click, as far as its text runs.
        test("a highlight locks to the text line under the click") {
            let sut = canvas(tool: .highlight)
            sut.highlightRects = [CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2)] // x 10...60, y 30...42 in the 100 x 60 view

            drag(sut, CGPoint(x: 20, y: 35), CGPoint(x: 95, y: 55))

            checkEqual(sut.marks.last?.rect, CGRect(x: 20, y: 29, width: 42, height: 14))
        }
        test("a highlight away from text stays a free box") {
            let sut = canvas(tool: .highlight)
            sut.highlightRects = [CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2)]

            drag(sut, CGPoint(x: 20, y: 5), CGPoint(x: 40, y: 15))

            checkEqual(sut.marks.last?.rect, CGRect(x: 20, y: 5, width: 20, height: 10))
        }
        // A multiply highlight on black stays black; on dark screens the highlight has to lighten.
        test("a highlight on a dark screen lightens it") {
            let black = ImageTools.render(size: NSSize(width: 100, height: 60), pixels: NSSize(width: 200, height: 120)) { r in NSColor.black.setFill(); r.fill() }
            let sut = Canvas(image: black); sut.marks = [rect(10, 10, 90, 50, tool: .highlight)]

            let pixel = color(sut.export(), 100, 60)

            checkGreater(pixel.redComponent, 0.2)
        }
        // README: the default text style is Box, the text on a pale wash of its color.
        test("new text is drawn on a box that its hit area covers") {
            let sut = canvas(tool: .text)
            let mark = Mark(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red, width: sut.textSize, text: "Hi", style: sut.textStyle)

            let frame = mark.textFrame

            check(frame.minX < 20 && frame.minY < 20 && mark.bounds.contains(frame), "box \(frame) not padded or not inside \(mark.bounds)")
        }
        test("choices saved before text sizes existed open text in the Box style") {
            Settings.editorChoices = ["textStyle": 0]; defer { Settings.editorChoices = [:] }
            let sut = Canvas(image: fixture())

            sut.restoreChoices()

            checkEqual(sut.textStyle, 8)
        }
        // README: a quick flick dismisses a card even when it moved only a little; a slow short drag springs back.
        test("a quick short flick throws the card off and a slow one springs back") {
            checkEqual(OverlayCard.throwDirection(dx: 30, velocity: 900), 1)
            checkEqual(OverlayCard.throwDirection(dx: 30, velocity: 100), nil)
        }

        // MARK: Keyboard (README: each tool has a single-key shortcut)

        test("no two editor shortcuts share a key") {
            checkEqual(Set(EditorShortcut.allCases.map(\.display)).count, EditorShortcut.allCases.count)
        }
        test("no two tools share a key") {
            checkEqual(Set(Tool.visible.map(\.key)).count, Tool.visible.count)
        }

        // MARK: Files

        test("two captures in the same moment get different file names") {
            checkNotEqual(Capture.newURL("png"), Capture.newURL("png"))
        }
        // README: Capture History lists every image, recording and project in the captures folder.
        test("history lists images, recordings and projects and skips other files") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
            for name in ["capture.png", "photo.JPG", "recording.mp4", "clip.mov", "loop.gif", "edit.leanshot", "notes.txt", "page.pdf"] { try Data().write(to: folder.appendingPathComponent(name)) }

            let names = Set(CaptureHistory.files(in: folder).map(\.lastPathComponent))

            checkEqual(names, ["capture.png", "photo.JPG", "recording.mp4", "clip.mov", "loop.gif", "edit.leanshot"])
        }
        test("closing a Quick Access card releases its window") {
            let url = Capture.tempURL("png"); try ImageTools.png(fixture())!.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            weak var released: OverlayCard?

            autoreleasepool {
                var card: OverlayCard? = OverlayCard(url: url, screen: NSScreen.main)
                released = card; QuickAccess.close(card!); card = nil
            }

            check(released == nil, "closed card retained its panel through contentView")
        }

        // MARK: Scrolling capture

        // A 240 pt noise pattern; two 120 pt frames 60 pt apart overlap by 60 pt and stitch to 180 pt.
        let document = ImageTools.render(size: NSSize(width: 240, height: 240)) { _ in
            for y in 0..<40 { for x in 0..<40 {
                let value = CGFloat((x * 43 + y * 71 + x * y * 13) % 251) / 250
                NSColor(srgbRed: value, green: value, blue: value, alpha: 1).setFill()
                NSRect(x: x * 6, y: y * 6, width: 6, height: 6).fill()
            } }
        }
        for (horizontal, a, b) in [(false, CGRect(x: 0, y: 120, width: 120, height: 120), CGRect(x: 0, y: 60, width: 120, height: 120)),
                                   (true, CGRect(x: 0, y: 0, width: 120, height: 120), CGRect(x: 60, y: 0, width: 120, height: 120))] {
            let first = ImageTools.crop(document, to: a), second = ImageTools.crop(document, to: b), axis = horizontal ? "horizontal" : "vertical"
            test("\(axis) scrolling finds a 60 pt overlap") {
                let overlap = Stitcher.overlap(first, second, horizontal: horizontal)

                checkNear(overlap ?? 0, 60, 2)
            }
            test("\(axis) scrolling sees a repeated frame as a full overlap") {
                checkEqual(Stitcher.overlap(first, first, horizontal: horizontal), 120)
            }
            test("\(axis) stitching two frames rebuilds the document length") {
                let result = Stitcher.append(second, to: first, overlap: 60, horizontal: horizontal)

                checkNear(horizontal ? result.size.width : result.size.height, 180, 2); checkEqual(horizontal ? result.size.height : result.size.width, 120)
            }
        }

        // MARK: Recording motion

        test("the cursor position is interpolated between samples") {
            checkEqual(timeline().position(at: 0.5), CGPoint(x: 0.5, y: 0.5))
        }
        test("after the last sample the cursor stays where it ended") {
            checkEqual(timeline().position(at: 5), CGPoint(x: 0, y: 0.5))
        }
        test("smart zoom is 1.5x shortly after a click") {
            checkEqual(timeline().zoom(at: 1.5, clicks: [1]), 1.5)
        }
        test("smart zoom returns to 1x long after a click") {
            checkEqual(timeline().zoom(at: 4, clicks: [1]), 1)
        }
        test("smoothing damps a 50 ms cursor jump and keeps its click") {
            let sut = MotionTimeline(samples: [MotionSample(time: 0, x: 0, y: 0, click: false), MotionSample(time: 0.05, x: 1, y: 1, click: true)])

            let smoothed = sut.smoothed().samples[1]

            checkLess(smoothed.x, 0.5); check(smoothed.click, "smoothing lost the click")
        }
        test("a motion sidecar file reads back next to its recording") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
            let recording = directory.appendingPathComponent("recording.mp4"), file = MotionTimeline.url(for: recording)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(timeline()).write(to: file)

            let read = MotionTimeline.read(for: recording)

            checkEqual(read?.samples.count, 3)
        }
        test("a motion sidecar from a newer version is ignored") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
            let recording = directory.appendingPathComponent("recording.mp4"), file = MotionTimeline.url(for: recording)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var newer = timeline(); newer.version = 99; try JSONEncoder().encode(newer).write(to: file)

            let read = MotionTimeline.read(for: recording)

            check(read == nil, "read a version 99 sidecar")
        }
        let size = CGSize(width: 160, height: 120), red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        let still = MotionTimeline(samples: [MotionSample(time: 0, x: 0.5, y: 0.5, click: false)], sourceSize: size)
        test("the editable cursor is drawn at the tracked position") {
            let sut = VideoEffects(motion: still, zoom: nil, start: 0, rate: 1, aspect: 0, blur: false, cursorStyle: 3, cursorScale: 1)

            let frame = CIContext().createCGImage(sut.render(red, at: 0), from: CGRect(origin: .zero, size: size))!

            checkGreater(NSBitmapImageRep(cgImage: frame).colorAt(x: 80, y: 60)!.usingColorSpace(.sRGB)!.blueComponent, 0.6)
        }
        test("no cursor is drawn when the recording already shows one") {
            var motion = still; motion.sourceHasCursor = true
            let sut = VideoEffects(motion: motion, zoom: nil, start: 0, rate: 1, aspect: 0, blur: false, cursorStyle: 3, cursorScale: 2)

            let frame = CIContext().createCGImage(sut.render(red, at: 0), from: CGRect(origin: .zero, size: size))!

            let pixel = NSBitmapImageRep(cgImage: frame).colorAt(x: 80, y: 60)!.usingColorSpace(.sRGB)!
            checkGreater(pixel.redComponent, 0.9); checkLess(pixel.blueComponent, 0.1)
        }

        // MARK: OCR (README: recognize text on device)

        test("OCR reads rendered text") {
            let image = ImageTools.render(size: NSSize(width: 400, height: 120), pixels: NSSize(width: 800, height: 240)) { r in
                NSColor.white.setFill(); r.fill()
                ("LeanShot 2026" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            }
            var text: String?

            OCR.recognize(image) { text = $0 }

            // Vision loads its model for about 55 s the first time a new binary runs it, then answers in 0.2 s.
            let end = Date().addingTimeInterval(120)
            while text == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(text?.contains("LeanShot") == true, "OCR read: \(text ?? "nothing")")
        }
    }

    // MARK: Video editor (real H.264 fixture through AVFoundation)

    /// A 1.2 s red 160x120 H.264 movie at 10 fps.
    private static func movie() async throws -> URL {
        let url = Capture.tempURL("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = buffer!; CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            CVPixelBufferUnlockBaseAddress(pixel, []); _ = adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    static func runVideo() async {
        guard let url = try? await movie() else { failures.append("could not write the H.264 fixture"); failed += 1; return }
        defer { try? FileManager.default.removeItem(at: url) }
        // A click at 0.4 s of source time, inside the 0.2 to 0.8 s trim.
        let clicks = MotionTimeline(samples: [MotionSample(time: 0, x: 0.25, y: 0.75, click: false), MotionSample(time: 0.4, x: 0.25, y: 0.75, click: true), MotionSample(time: 1, x: 0.75, y: 0.25, click: false)])

        await test("trimming 0.2 to 0.8 s at 2x speed lasts 0.3 s") {
            let composition = try await VideoEditor.composition(url: url, start: 0.2, end: 0.8, rate: 2, muted: true)

            let duration = try await composition.load(.duration).seconds

            checkNear(duration, 0.3, 0.01)
        }
        await test("a muted composition has no audio track") {
            let composition = try await VideoEditor.composition(url: url, start: 0.2, end: 0.8, rate: 2, muted: true)

            let audio = try await composition.loadTracks(withMediaType: .audio)

            checkEqual(audio.count, 0)
        }
        await test("smart zoom enlarges the frame around a click") {
            let composition = try await VideoEditor.composition(url: url, start: 0.2, end: 0.8, rate: 2, muted: true)

            let video = try await VideoEditor.videoComposition(composition, aspect: 2, background: 2, motion: clicks, start: 0.2, rate: 2)

            var from = CGAffineTransform.identity, to = CGAffineTransform.identity, range = CMTimeRange.zero
            let layer = (video.instructions[0] as! AVMutableVideoCompositionInstruction).layerInstructions[0]
            check(layer.getTransformRamp(for: CMTime(seconds: 0.1, preferredTimescale: 600), start: &from, end: &to, timeRange: &range), "no zoom ramp")
            checkGreater(to.a, 1)
        }
        let output = Capture.tempURL("mp4"), gif = Capture.tempURL("gif")
        defer { for file in [output, gif] { try? FileManager.default.removeItem(at: file) } }
        await test("the square aspect exports a square MP4 of the trimmed length") {
            let composition = try await VideoEditor.composition(url: url, start: 0.2, end: 0.8, rate: 2, muted: true)
            let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
            session.outputURL = output; session.outputFileType = .mp4
            session.videoComposition = try await VideoEditor.videoComposition(composition, aspect: 2, background: 2, motion: clicks, start: 0.2, rate: 2)

            await session.export()

            guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
            let saved = AVURLAsset(url: output), track = try await saved.loadTracks(withMediaType: .video).first!
            let dimensions = try await track.load(.naturalSize), duration = try await saved.load(.duration).seconds
            checkEqual(dimensions.width, dimensions.height); checkNear(duration, 0.3, 0.05)
        }
        // The GIF exporter samples 10 frames per second: 0.3 s gives 3 frames.
        await test("a 0.3 s clip exports a 3-frame GIF") {
            let saved = AVURLAsset(url: output)
            var motion = clicks; motion.sourceSize = CGSize(width: 160, height: 120)
            let effects = VideoEffects(motion: motion, zoom: clicks, start: 0.2, rate: 2, aspect: 2, blur: true, cursorStyle: 3, cursorScale: 1.5)

            try await VideoEditor.exportGIF(asset: saved, video: effects.composition(for: saved), to: gif)

            let decoded = CGImageSourceCreateWithURL(gif as CFURL, nil)
            checkEqual(decoded.map(CGImageSourceGetCount), 3); checkNotNil(decoded.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        }
    }
}

private func record(_ message: String, _ file: StaticString, _ line: UInt) { EditorTests.failures.append("\(message) at \(file):\(line)") }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String = "expected true", file: StaticString = #fileID, line: UInt = #line) {
    do { if try !value() { record(message, file, line) } } catch { record("threw \(error)", file, line) }
}
private func checkEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    do { let value = try a(); if value != b { record("\(value) != \(b)", file, line) } } catch { record("threw \(error)", file, line) }
}
private func checkNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) { if a == b { record("both are \(a)", file, line) } }
private func checkGreater<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) { if !(a > b) { record("\(message) \(a) is not above \(b)", file, line) } }
private func checkLess<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) { if !(a < b) { record("\(message) \(a) is not below \(b)", file, line) } }
private func checkNear(_ a: @autoclosure () throws -> Double, _ b: Double, _ tolerance: Double, file: StaticString = #fileID, line: UInt = #line) {
    do { let value = try a(); if abs(value - b) > tolerance { record("\(value) is not within \(tolerance) of \(b)", file, line) } } catch { record("threw \(error)", file, line) }
}
private func checkNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) { if value == nil { record("unexpected nil", file, line) } }
private func checkThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) {
    do { _ = try value(); record("expected an error", file, line) } catch {}
}
