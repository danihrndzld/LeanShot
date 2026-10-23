# LeanShot

A native macOS menu-bar capture and annotation app inspired by [CleanShot X](https://cleanshot.com/features). Swift and AppKit, no third-party dependencies, builds with Command Line Tools.

## Build

Requires macOS 14+. Display, area and window recording with audio require macOS 15+.

```sh
./build.sh
open build/LeanShot.app
```

Enable LeanShot in **System Settings → Privacy & Security → Screen Recording**. Microphone recording also requires Microphone permission. Ad-hoc builds can invalidate the screen-recording grant; use a stable signing identity to preserve it:

```sh
SIGN_ID="Apple Development: you@example.com" ./build.sh
```

## Capture and Quick Access

- Native area, window and fullscreen screenshots; five-second timer; optional window shadow and cursor.
- Frozen region picker with crosshair, magnifier, Shift for square selections and Return to reuse the last selection on that display. The picker opens on the display under your pointer.
- All-in-One launcher for capture, OCR, scrolling and recording modes, with optional exact width/height for frozen-area capture.
- Vertical and horizontal scrolling capture: select the scrolling content, scroll a little, pause and click **Add Frame**. LeanShot detects overlap; **Finish** saves the stitched PNG. Exclude fixed headers from your selection. A frame without a match stays uncommitted so you can scroll back and retry.
- **Auto / Stop** scrolls and captures automatically (requires Accessibility permission). It stops at unchanged content or a missing overlap; the result is saved only when you click Finish.
- Quick Access keeps up to four draggable thumbnails stacked at a configurable corner. Hover for Copy, Save, Pin, Annotate and Share. Right-click for rotation, OCR/QR, Quick Look, Finder, hide, close and trash.
- Overlays hide during capture and return afterward. Use **Restore Quick Access** to reveal hidden cards or restore the most recently closed card. Auto-close waits while a card is hovered, dragged or showing a menu.
- Capture History searches filenames, filters images, videos and projects, and supports opening, copying, dragging, revealing and trashing files. Captures remain in your configured folder until you delete them.

## Annotate

The toolbar offers selection, outlined and filled rectangles, ellipse, line, arrow, text, pixelate, highlighter, counters, smoothed pen, blur, spotlight, crop and opaque redaction. Use the color picker and its native eyedropper/swatches for custom colors.

Selecting Highlighter starts on-device text detection. When text bounds are ready, highlight height snaps to the intersected text lines.

The **Image & Styles** menu adds:

- Four arrow styles, including curved and double-headed arrows; seven text styles.
- Free, square, 16:9, 4:3 and 9:16 crop ratios.
- Rotation, flipping, proportional pixel resize, undo and redo.
- Background palettes or a custom image, padding, corner radius, shadow, aspect ratio and left/center/right alignment. Save multiple named presets and recall the last setup.
- Editable `.leanshot` projects that preserve the source bitmap and annotation layers.

Drop images into the canvas or paste with `⌘V` to combine screenshots. Select layers to move them, drag their corner handles to resize, and press Delete to remove them. Image layers retain their aspect ratio. Exports preserve Retina pixel density.

**Done** saves and copies the PNG. For imported images it creates a new capture, preserving the original. **Save as…** exports to a chosen file; **Save Editable Project…** preserves layers. Project files retain source images; use PNG export to share a flattened redaction. Blur and pixelation are visual effects; use **Redact (Opaque)** to conceal information in the exported PNG.

The bottom bar offers zoom, **Drag Me**, native sharing, pin and copy. Pinned images float over other apps: drag to move, scroll to resize, use arrow keys for precise positioning (Shift for 10 points), and right-click for opacity or click-through lock. **Unlock Floating Screenshots** in the menu restores mouse interaction. Escape or double-click closes a pin.

## Recording and video editing

On macOS 15+, record the display under the pointer, a frozen selected area, or a chosen window using ScreenCaptureKit. Output is H.264 MP4, up to 4K, at 30 or 60 fps. Settings control cursor, computer audio and microphone. The menu bar displays elapsed time; `⌃⇧6` stops and finalizes the file. On macOS 14, the same shortcut uses the original fullscreen MOV recorder.

Optional display/area recording overlays include a camera bubble (size, corner, circle/rounded shape or fullscreen) and keystrokes (all keys or only shortcuts, position, size and light/dark style). Camera permission is required for the bubble; Accessibility permission is required for keystrokes. These overlay windows are included explicitly while LeanShot's other windows stay excluded. Window-only recording does not include the camera or key overlays. Native click highlighting can be enabled for any macOS 15+ recording. The desktop-icon option covers icons with your wallpaper during display/area recordings and removes the cover when recording ends.

Double-click a recording in Quick Access or History to open the native video editor:

- Play and scrub with native playback controls.
- Set start/end times, speed and audio mute.
- Export original, landscape, square or portrait composition with background color and padding.
- Export MP4 or a looping GIF (10 fps, up to 1280 px).
- Generate cursor-following zooms around clicks, with smooth tracking and motion blur. New display/area recordings save local cursor/click timing in a hidden `.leanshot-motion` folder next to the video; keep this data beside the original to retain these editing options.
- Replace, resize and smooth the cursor in recordings made with the pointer disabled. Choose a white arrow, black arrow or accent dot. Recordings with the pointer already embedded keep the original cursor. Effects apply during export.
- Exports use a temporary file and replace the destination only after successful encoding. The original recording stays intact.

## Shortcuts

macOS owns `⌘⇧3/4/5`, so LeanShot uses `⌃⇧`.

| Global | Action |
|---|---|
| `⌃⇧1` | All-in-One |
| `⌃⇧4` | Area |
| `⌃⇧5` | Window |
| `⌃⇧3` | Fullscreen |
| `⌃⇧2` | Text and QR recognition, on device |
| `⌃⇧6` | Start/stop display recording |

| Editor | Action |
|---|---|
| `V R F O L A T B H N P U S C X` | Select a tool in toolbar order |
| `⌘Z` / `⌘⇧Z` | Undo / redo |
| `⌘C` / `⌘V` | Copy output / insert clipboard image |
| `⌘S` / Return | Done |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / 100% |

After installing the app, `leanshot://area`, `window`, `fullscreen`, `text`, `record`, `all-in-one`, `history` and `restore` trigger the corresponding actions. Open `.leanshot` documents with LeanShot to resume editing.

## Settings

Choose capture folder, clipboard behavior, cursor, window shadows, overlay corner, thumbnail size, auto-close duration, recording fps/audio and launch at login. Login registration requires running the built app bundle.

Use **Keyboard Shortcuts…** to record new global combinations. Changes persist, update the menu, and reject combinations already assigned to another action or app.

Display/area click effects offer color, size, filled/outline style and animation controls; window-only recording uses the native click marker. Recording resolution can be limited to 1280, 1920 or 3840 pixels.

For automatic Do Not Disturb, create paired shortcuts in the macOS Shortcuts app using **Set Focus**. Choose them under **Configure Focus Shortcuts…**, then enable **Use Focus shortcuts while recording**. LeanShot runs the start shortcut before recording and the end shortcut afterward, including when recording ends during Quit. Focus automation requires this one-time setup because macOS provides no public Focus setter. Shortcuts execute locally and are disabled by default.

## Verification

```sh
swift build
swift run LeanShot --selftest
swift run LeanShot --preview in.png editor.png
swift run LeanShot --overlay-preview in.png overlay.png
plutil -lint Info.plist
```

`--selftest` checks Retina crop/rotation/flip, undo/redo, editable project round trips and invalid input, opaque redaction, transparent backgrounds, filename uniqueness, history filtering, scrolling overlap, motion timelines and cursor rendering. It also encodes a real H.264 fixture, verifies trim/speed/square MP4 with smart zoom, renders cursor/blur effects into a GIF, decodes that GIF, and runs the original Retina annotation/OCR checks. The runner works with Command Line Tools; XCTest is not required.

## Coverage limits

The frozen picker supports free, square, 16:9, 4:3 and 9:16 selection, plus exact dimensions. Camera/key/custom-click overlays and motion tracking target display/area recording; window recording captures only the selected window. Cursor replacement requires pointer-free source video, and Focus automation requires configured macOS shortcuts. Video effects are rendered at export rather than previewed live in the player.

Live screen capture, microphone/system audio, camera/keystrokes, multi-display placement and launch-at-login still need end-to-end checks with macOS permissions on the built app. Rendering and media-file regression tests do not exercise those permission-bound interactions.
