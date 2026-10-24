# CLAUDE.md for LeanShot

LeanShot is a native macOS menu bar app for screenshots, annotation and recording. It is written in Swift 5 with AppKit only and built with SwiftPM, it has no dependencies, and it targets macOS 14 with Liquid Glass on macOS 26 or later.

Read `docs/ARCHITECTURE.md` before a change that touches more than one file. It maps every source file, explains the patterns the code relies on (the `Tool.traits` table, the Memento undo, the `EditorShortcut` table, the `Settings` keys), lists the performance decisions with their measurements, and lists the traps from earlier sessions.

## Commands

```sh
./build.sh                                   # build/LeanShot.app, real SDK stamped, signed
.build/release/LeanShot --selftest           # regression tests, exit 0 on success
.build/release/LeanShot --bench              # timings for the slow paths
build/LeanShot.app/Contents/MacOS/LeanShot --preview in.png out.png [--background]
scripts/make_dmg.sh                          # signed app and DMG in build/
```

Use the app bundle binary for previews, because only that binary renders Liquid Glass. Read the saved picture after every UI change.

## Rules for changes

- Keep diffs small and in the style of the surrounding code, and reuse the helpers in `Capture.swift` and `ImageTools.swift` (`Anim`, `Glass`, `Toast`, `Permissions`, `Thumbnail`, `NSScreen.underPointer`).
- Never add `default:` to a `switch` on `Tool`, and add new `Tool` cases at the end because raw values are saved in `.leanshot` files.
- Add new preferences to `Settings`, and keep large data in Application Support files.
- Call `Canvas.checkpoint()` once before a change that should be undoable.
- Add one check to `EditorTests.run()` for each non-trivial logic change, and run `--selftest` before you report the work as done.
- Measure with `--bench` before and after a performance change, and report both numbers.
- The user writes in Spanish, so reply in Spanish.

## Git

Commit only when the user asks. Use the author `Daniel Hernández <danisnowman@gmail.com>`, and never add a Co-Authored-By line for Claude or a "Generated with Claude Code" line.
