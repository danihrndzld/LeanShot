# LeanShot

A native macOS menu-bar screenshot tool modelled on CleanShot X. About 1,100 lines of Swift, AppKit only, no dependencies, builds without Xcode.

## Features

| | |
|---|---|
| **Capture** | Area, window, fullscreen, 5-second timer. Files land in `~/Pictures/LeanShot` and on the clipboard. |
| **Quick Access** | A thumbnail appears bottom-left after each capture: drag it into any app, copy, annotate, pin, OCR, delete. |
| **Annotate** | 11 tools (select, rectangle, filled rectangle, ellipse, line, arrow, text, pixelate, highlight, counter, pen), 8 colors, 3 stroke widths, zoom, undo. Exports at full Retina resolution. |
| **Pin** | Floats a capture above every window. Drag to move, scroll to resize, Esc to close. |
| **OCR** | Select an area and its text goes to the clipboard (Vision, on-device). |
| **Record** | Records the main display to `.mov`; press the shortcut again to stop. |

## Shortcuts

| Global | | Annotate editor | |
|---|---|---|---|
| `⌃⇧4` | Capture area | `V R F O L A T B H N P` | Pick tool |
| `⌃⇧5` | Capture window | `⌘Z` | Undo |
| `⌃⇧3` | Capture fullscreen | `⌘C` | Copy image |
| `⌃⇧2` | Capture text | `⌘S` / `Return` | Done: save, copy, close |
| `⌃⇧6` | Start / stop recording | `⌘=` `⌘-` `⌘0` | Zoom in, out, 100% |

`⌘⇧3/4/5` stay with macOS, so LeanShot uses `⌃⇧`.

## Build

Requires macOS 14+ and the Command Line Tools (`xcode-select --install`).

```sh
./build.sh && open build/LeanShot.app
```

On first launch, enable LeanShot in **System Settings → Privacy & Security → Screen Recording**.

Ad-hoc signing produces a new signature on every build, and macOS then drops the Screen Recording grant. Sign with a stable identity to keep it:

```sh
SIGN_ID="Apple Development: you@example.com" ./build.sh
```

## Checks

```sh
swift run LeanShot --selftest                    # Retina export + OCR
swift run LeanShot --preview in.png out.png      # renders the editor window to a PNG
```

## How it works

| File | Role |
|---|---|
| `main.swift` | Menu-bar item, Carbon global hotkeys, capture actions |
| `Capture.swift` | Runs `/usr/sbin/screencapture`, clipboard, Vision OCR, toasts |
| `QuickAccess.swift` | Post-capture overlay and pinned windows |
| `Annotate.swift` | Editor window, toolbar, canvas, marks, export |

Capture uses the system `screencapture` binary, so the crosshair and window picker are the native ones.

## Not yet

- Recording a chosen area or with audio: `screencapture` rejects `-v` with `-i`; needs ScreenCaptureKit (`SCRecordingOutput`).
- Crop, scrolling capture, cloud upload, launch at login, `leanshot://` URL scheme.
