# LeanShot architecture and conventions

This document is for agents and contributors who change LeanShot. It explains how the app is put together, which patterns the code relies on, and which traps cost time in earlier sessions. Read it before a change that touches more than one file.

## What the app is

LeanShot is a macOS menu bar app for screenshots, annotation and screen recording. It is a single SwiftPM executable target written in Swift 5 with AppKit only, and it has no third-party dependencies. The minimum system is macOS 14, recording needs macOS 15, and Liquid Glass code sits behind `if #available(macOS 26, *)`.

The app runs with the `.accessory` activation policy, so it has no Dock icon. While an editor, History, Settings or video editor window is visible, `AppDelegate.updateActivationPolicy()` switches to `.regular`, so the app appears in the Dock and in `⌘Tab`.

## Files and responsibilities

| File | Responsibility |
|---|---|
| `main.swift` | `AppDelegate`, the status menu, the main menu, `Hotkeys` (Carbon global shortcuts), command line flags |
| `Annotate.swift` | `Tool`, `ToolTraits`, `EditorShortcut`, `Mark`, `Canvas` (drawing and editing), `Backdrop`, `DragHandle`, `AnnotateWindow` (toolbar, zoom, export, Done), `SelfTest` |
| `QuickAccess.swift` | `QuickAccess` card stack, `OverlayCard`, `DragImageView`, `PinWindow`, `ClosureButton` |
| `Capture.swift` | `Capture.run` (wraps `/usr/sbin/screencapture`), `Clipboard`, `OCR`, `Anim`, `Glass`, `Toast`, `Permissions`, `NSScreen.underPointer` |
| `ImageTools.swift` | Bitmap helpers that keep Retina density, PNG/JPEG/HEIC encoding, the shared `CIContext`, `Thumbnail` |
| `Project.swift` | `ShotProject` (`.leanshot` files) and `ShotBackground` (backgrounds, layout, shadow) |
| `BackgroundEditor.swift` | `BackgroundInspector`, the background sidebar |
| `Selection.swift` | `RegionSelector`, the frozen area picker, and `ScreenRegion` |
| `Scrolling.swift` | Scrolling capture and frame stitching |
| `Recording.swift`, `RecordingDecorations.swift`, `ClickOverlay.swift`, `Motion.swift`, `FocusAutomation.swift` | ScreenCaptureKit recording, overlays, cursor motion log, Focus shortcuts |
| `VideoEditor.swift`, `VideoEffects.swift` | Trim, speed, aspect, smart zoom, MP4 and GIF export |
| `History.swift` | Capture History window |
| `Settings.swift`, `ShortcutSettings.swift` | `Settings` (every UserDefaults key), the Settings window and its tabs |
| `EditorTests.swift`, `Bench.swift` | `--selftest` regression tests and `--bench` timings |

## How a capture flows

First, a global shortcut or menu item calls an `AppDelegate` action, e.g., `captureArea()`. Second, `shoot()` checks the Screen Recording permission and runs `screencapture` through `Capture.run`, which writes a PNG into `Capture.folder`. Third, the completion copies the file when `Settings.copyOnCapture` is on and calls `QuickAccess.show(url)`, which creates an `OverlayCard` on the display under the pointer. Fourth, a double-click on the card calls `AnnotateWindow.open(url)`.

In the editor, `AnnotateWindow` owns a `Canvas` inside a `Backdrop`. The window acts as the mediator between the canvas, the toolbar and the background sidebar, and it talks to the canvas through closures (`onToolChange`, `onImageChange`, `onKey`). Done renders `output()` (the canvas export plus the background), hides the window, writes the PNG on a background queue, and closes the window only after the write succeeds.

## Patterns the code relies on

### Tools are one exhaustive table

`Tool` is an `Int` enum, and its raw values are stored in `.leanshot` files, so new cases go at the end. `Tool.traits` returns a `ToolTraits` value from a `switch` with no `default`, so a new tool doesn't compile until it states its symbol, label, key, handle kind, shadow and number of styles. Code that differs per tool should read `tool.traits` or switch over every case explicitly. Do not add `default:` to a `switch` on `Tool`.

`Mark.style` stores the arrow style, the text style or the redaction style as an `Int`. `Tool.arrowStyles` and `Tool.textStyles` list them in menu order with their raw values, and new styles go at the end. A text mark keeps its font size in points in `width`; `.leanshot` version 1 stored a stroke width there, and `ShotProject.read` converts it. `Mark.init(from:)` validates the style range only for tools whose `traits.styles` is above zero, because older files stored the arrow style on every shape.

### Undo is a Memento

`Canvas.checkpoint()` pushes a full `State` (image, marks, size) onto `history` and clears `future`. Call it once before a change, never after. Drags and slider moves record one step, by using the `moveUnsaved` flag and the `adjusting` index. `checkpoint()` also sets `window.isDocumentEdited`, which drives the save or discard sheet in `windowShouldClose`.

### Shortcuts live in one table

`EditorShortcut` lists every `⌘` shortcut and every plain key that isn't a tool key. `performKeyEquivalent` and `Canvas.keyDown` both call `EditorShortcut.matching(event)`, and the Settings Shortcuts tab reads the same table. The self-test fails if two shortcuts or two tool keys collide. Global shortcuts use Carbon `RegisterEventHotKey` in `Hotkeys`. A binding can be `failed` (another app owns it) or `unset` (no shortcut), and the menu shows neither as active.

### Every UserDefaults key goes through `Settings`

Add new preferences as static properties on `Settings`. Keys built from values use the builders `Settings.hotkeyKey` and `Settings.lastRegionKey`. Large data, e.g., background presets that embed a wallpaper, goes to files in `~/Library/Application Support/LeanShot`, not to UserDefaults.

### Small helpers instead of frameworks

The code uses closures and enums with static functions instead of protocols, view models or Combine. `ClosureButton`, `ClosurePopup` and `ClosureSwitch` adapt target-action to closures. `Anim.run` wraps `NSAnimationContext` and skips animation when Reduce Motion is on. `Glass.style` and `Glass.pane` apply Liquid Glass on macOS 26 or later and do nothing on older systems. `Toast.show` shows a short message, announces it to VoiceOver, and stays out of captures. `Permissions.explain` turns a capture error into an alert with an Open System Settings button.

## Rendering and performance

Marks are stored in view points, and `Canvas.export()` renders them at the image's full pixel size, so exports keep Retina density. `render(in:)` draws only the image and the marks. Selection outlines and handles are drawn in `draw(_:)`, so they never appear in an export.

These choices come from measurements with `--bench` on a 3024 by 1964 pixel capture:

- When one mark changes, `invalidate(from:)` repaints only the old and new area of that mark, which takes 1.3 ms instead of 8.9 ms for the whole canvas. Spotlights, counters, text and curved arrows still repaint everything, because their drawing reaches outside `Mark.bounds`.
- Redaction effects are computed only for the mark's rectangle and cached by style, amount and rectangle. A slider step with four redactions takes about 13 ms. Pixelate keeps its grid anchored at the image origin, so a moved mark still lines up.
- The app uses one shared `ImageTools.ciContext`, and `ImageTools.warmUp()` compiles the Core Image kernels at launch on a background queue.
- Each lifted mark draws its own shadow. A shared transparency layer for all marks measured 51 ms per frame, so don't use one.
- `Thumbnail.image` decodes previews at display size with ImageIO and caches them. History loads thumbnails on a background queue.
- `Clipboard.copy` declares PNG and TIFF with a data provider, so the image is encoded only when another app pastes it.

## Build, run and verify

| Command | Purpose |
|---|---|
| `./build.sh` | Builds `build/LeanShot.app`, records the real SDK version and signs with `SIGN_ID` or ad hoc |
| `scripts/make_dmg.sh` | Builds and signs the app and a DMG in `build/` |
| `scripts/make_icon.sh` | Compiles `Resources/LeanShot.icon` into `Resources/Assets.car` and `LeanShot.icns` |
| `.build/release/LeanShot --selftest` | Runs the regression tests and exits with 0 when they pass |
| `.build/release/LeanShot --bench` | Prints timings for the slow paths |
| `scripts/e2e.sh [dir]` | Runs the end-to-end suite (`--e2e`) on a coverage build and writes `junit.xml` and `coverage.json` |
| `build/LeanShot.app/Contents/MacOS/LeanShot --preview in.png out.png [--background]` | Opens the editor on `in.png` and saves a picture of the window |
| `... --overlay-preview in.png out.png` | Saves a picture of two Quick Access cards, the right one hovered |
| `... --settings-preview <tab> out.png` | Saves a picture of a Settings tab |

Run the preview flags from the app bundle binary, because `.build/release/LeanShot` still carries SDK 14.0 and renders without Liquid Glass. Look at the saved picture after every UI change, because the self-test doesn't check layout.

## Traps from earlier sessions

- SwiftPM records SDK 14.0 in the binary, and AppKit then uses its pre-Liquid Glass look. `build.sh` fixes the binary with `vtool -set-build-version`.
- `NSMenuToolbarItem` treats its first menu item differently across macOS versions. Toolbar menus use `NSPopUpButton(pullsDown: true)` through `AnnotateWindow.pullDown`, where the first item is the button face and never appears in the menu.
- Inactive windows on macOS 26 and 27 draw sidebars and glass flat, so previews of inactive windows don't show the final look. `screencapture -l` also fails while the screen is locked, and the preview flags then fall back to `cacheDisplay`.
- `NSColor.red` converted to sRGB has a green component of 0.149, so tests compare against the fixture's own pixels instead of pure red.
- `CIPixellate` samples the center pixel of each block instead of averaging it.
- A failed check in `--selftest` records its message and `file:line`, the run continues, and the process exits 1 after printing `FAIL <test name>`. The self-test uses the same throwaway defaults domain as `--e2e` (`Settings.testSuite`), so the editor choices it changes never reach the user's settings.
- Each `test("…")` in `EditorTests.run()` has one Act line and asserts one exit point. Expected values come from the README or a comment next to the test, never from the code under test. Swift `assert` is compiled out of release builds, so tests use the `check*` helpers.
- Quick Access panels, toasts and other overlay windows set `sharingType = .none`, so they never appear in captures. The overlay preview switches the cards to `.readOnly` to photograph them.
- `Canvas.remembersChoices` is off by default, so tests don't write the user's editor preferences. `AnnotateWindow` turns it on through `restoreChoices()`.
- Tests that need a pasteboard use a private named pasteboard, never `NSPasteboard.general`.
- The end-to-end suite (`E2ETests.swift`) runs in a process that can't become the active app, so AppKit would spend each first click on activating the window. The driver hands mouse events to the view that `hitTest` finds, which is what `NSWindow.sendEvent` does for a key window. Key events go through `performKeyEquivalent` first and then the window, like `NSApplication.sendEvent`.
- The e2e process swizzles NSWindow ordering and alpha and NSApplication activation, so every window stays transparent and click-through and the app never takes focus. You can keep working while the suite runs, locally or on CI.
- `--e2e` switches `Settings.defaults` to the `com.danisnowman.leanshot.e2e` domain and `Clipboard.pasteboard` to a private pasteboard, and every case gets fresh temporary folders. Done on a capture in the captures folder still moves the original to the real Trash, and the tests delete it from there.
- Each e2e case title starts with its technique ID (`DT-R1`, `ST-T4`, `EP-07`, `AC-02`, `BVA-03`, `EG-01`), and the test report links each ID to its line.

## How changes are made here

Changes are small and follow the existing style. Prefer a short diff that reuses a helper in the codebase over a new abstraction, and mark a deliberate shortcut with a comment that names its limit. Every non-trivial logic change adds one named test to `EditorTests.run()`. Run `--selftest` and, for visual changes, a preview before you report a change as done.

Commits use the author `Daniel Hernández <danisnowman@gmail.com>` and never include an AI co-author line. Commit only when the user asks.
