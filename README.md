<p align="center">
  <img src="docs/icon.png" width="160" alt="Dynamic Dock Space icon">
</p>

<h1 align="center">Dynamic Dock Space</h1>

<p align="center">
  <b>Your windows follow the Dock across displays.</b><br>
  A tiny macOS menu-bar app that resizes windows when the Dock moves from one monitor to another.
</p>

<p align="center">
  <a href="README.pt-BR.md">🇧🇷 Leia em português</a> ·
  <a href="https://github.com/ThePaladini/dynamic-dock-space/releases/latest">⬇️ Download</a>
</p>

---

## The problem

With several displays (and *Displays have separate Spaces* on, the macOS default), the Dock jumps to whichever display you push the pointer against at the bottom edge. macOS updates each display's usable area, but **the windows already open don't react**:

- on the display the Dock **arrives** at, maximized windows end up **behind** the Dock;
- on the display it **left**, they keep a useless empty strip where the Dock used to be.

## What Dynamic Dock Space does

| When the Dock… | Windows on that display… |
|---|---|
| **arrives** | that overlap the Dock are shrunk — keeping their top edge — or lifted if they sit too low |
| **leaves** | that were sized up to the Dock grow to the bottom of the display (maximized windows, halves/thirds, keeping tiling margins) |
| **comes back** | get exactly their previous size back |

It works with the real Apple Dock — nothing is replaced, restyled or re-created — and never uses macOS full screen.

- 🎞 **Smooth, animated resizing.** When the Dock is about to arrive, windows shrink *before* macOS changes the usable area, so apps don't snap them abruptly.
- 🧠 **Respects you.** If you resize or move a window after it was adjusted, your choice wins. Nothing happens while a mouse button is held down.
- 🙈 **Leaves alone** minimized and full-screen windows, panels and dialogs, and any app you exclude.
- 🪶 **Lightweight.** Event-driven, no polling. Measured on an M4 Pro: 0 % CPU when you aren't using the computer, ~1 % of one core while the mouse moves (to anticipate the Dock), ~35 ms of CPU per Dock move, ~25–45 MB of memory.
- 🌐 English and Brazilian Portuguese (follows the system language).

## Menu

- **Automation enabled** · **Only with more than one display**
- Which display has the Dock (edge, auto-hidden, reserved size) and the list of displays
- **Adjust windows now**
- **Windows to adjust**
  - *Only windows that fill the usable area* — maximized / "fill" windows only
  - *Maximized and attached to the Dock* (default) — also tiled halves/thirds
  - *Also moved windows that reach the Dock area* — also windows you dragged down a bit
- **Expand windows on displays without the Dock** · **Animate resizing**
- **Ignored apps** — ignore the frontmost app or pick from running apps
- **Launch at login**

## Install

### Download

1. Get `DynamicDockSpace.zip` from the [latest release](https://github.com/ThePaladini/dynamic-dock-space/releases/latest) and move **DynamicDockSpace.app** to `/Applications` or `~/Applications`.
2. The app is open source but not notarized by Apple, so the first launch is blocked. Open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/DynamicDockSpace.app`.)
3. Grant **Accessibility** when asked (System Settings › Privacy & Security › Accessibility). The app notices it by itself.

> **After updating** to a new build, macOS may keep showing the app as allowed while ignoring it (the permission is tied to the exact binary). Remove it from the Accessibility list with **–** and add it again.

### Build from source

Requires macOS 13+ and the Command Line Tools (`xcode-select --install`). Xcode is not needed.

```sh
git clone https://github.com/ThePaladini/dynamic-dock-space.git
cd dynamic-dock-space
./build.sh --install     # universal (Apple Silicon + Intel) build, copied to ~/Applications
```

`./build.sh --zip` creates the distributable zip.

## Command line

```sh
APP=~/Applications/DynamicDockSpace.app/Contents/MacOS/DynamicDockSpace
$APP --status                     # what is detected (displays, Dock, AX list) and exit
$APP --verbose --dry-run          # log what it would do, without touching any window
$APP --verbose --only "Safari"    # act only on one app              (testing)
$APP --verbose --only-title Foo   # act only on windows titled *Foo* (testing)
```

Logs also go to the unified log:
`log stream --info --predicate 'subsystem == "io.github.thepaladini.DynamicDockSpace"'`

## How it works

Everything below was measured on macOS 26 before writing the engine (the prototypes are in [`Tools/probes`](Tools/probes)).

| Question | Measured answer |
|---|---|
| Does `NSScreen.visibleFrame` follow the Dock live? | **Yes** — ~200 ms after the move, together with `didChangeScreenParametersNotification`. |
| Where is a visible Dock? | The display whose `visibleFrame` has an inset on the Dock edge. The Dock's layer-20 window confirms it without any permission. |
| Where is a **hidden** Dock? | `visibleFrame` reserves nothing and the CG window disappears — but the Dock's **`AXList` still exists**, parked just past the edge of its display. |
| Dock thickness? | From the `visibleFrame` inset — the `AXList` size changes with magnification. |

**Engine.** Each event (display/Dock change, Space change, wake) triggers an idempotent, state-based *reconcile* over all standard windows via the Accessibility API. Every change keeps a *before/after* record, so moving the Dock back restores the exact previous frames, and a window that changed afterwards is considered yours and left alone.

**Racing the apps.** When `visibleFrame` changes, every AppKit app clamps its own tall windows — instantly and without keeping their top edge. So, while the pointer rests on the bottom edge of a display without the Dock, the app watches the Dock's `AXList` (60 Hz, at most 2 s). It jumps to the new display ~200 ms *before* `visibleFrame` changes, which is enough time to animate the shrink first. A verification pass 0.8 s later re-applies anything an app undid.

**Chromium/Electron quirks** (Chrome, VS Code, Slack…): resizes are applied asynchronously, sizes crossing the display edge are clamped, and a request equal to the last *requested* size is ignored. The engine verifies each change and, if needed, nudges with a 1 pt different size first.

**Animation.** Time-based ease-out (0.3 s), up to 120 fps. Each AX resize blocks until the app has re-laid out the window (7–15 ms for Chrome/Finder), so every *app* animates on its own thread — and never with concurrent requests to the same app, which would arrive late and override the final frame.

## Limitations

- Windows in Spaces that aren't visible are adjusted when you switch to that Space (the Accessibility API only lists visible Spaces).
- When the Dock changes without the pointer (toggling auto-hide, plugging in a display) there is no early warning, so apps may clamp first and the final adjustment lands ~0.8 s later.
- Several windows of the *same* app animate with fewer frames (one process re-lays out all of them).
- With *Displays have separate Spaces* turned off the Dock never changes display, so there is nothing to do.
- Side Docks (left/right) are handled by the code but were only tested with the bottom Dock.

## Project layout

```
Sources/DynamicDockSpace/
  main.swift          lifecycle, observers, --status
  DockDetector.swift  Dock detection (visibleFrame → AXList → CGWindow)
  Planner.swift       pure decisions (shrink / extend / restore, window scopes)
  Engine.swift        AX reconcile, records, prediction, animation, verification
  StatusMenu.swift    menu-bar UI
  Screens.swift  AX.swift  Settings.swift  Permissions.swift  LoginItem.swift  Log.swift
Resources/            Info.plist, en / pt-BR strings
Tools/
  make-icon.swift     renders docs/icon.png
  testwin.swift       disposable test windows (DELAY=ms simulates slow apps)
  mouse.swift         moves the pointer to a display edge (moves the Dock)
  probes/             detection prototypes used during the investigation
```

## License

[MIT](LICENSE) © 2026 ThePaladini
