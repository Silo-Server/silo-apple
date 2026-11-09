# Mac player: full-screen header, HUD on mouse move/click, double-click full screen

Branch `t3/dbdd3c12`, uncommitted. Tested 2026-11-09 on the Mac mini (1920x1080),
SiloMac Debug, shared dev (`silo-dev.arkyncdn.net`), playing Aqua Teen Hunger Force S2E22.

## How it was tested

Test-only build on the Mac mini (scratch copy, not committed): ad-hoc signed, keychain
replaced by a file store, `-debugPlay` routed through the real player route, and a driver
(`FSTestDriver.swift`) that toggles full screen, sends clicks through `NSApp.sendEvent`,
waits for a real cursor move from `cliclick` over SSH, and records every app window
(AppKit state, window-server bounds, and window-server pixels of the full-screen
toolbar strip). Screen Recording isn't granted over SSH, so the PNG composites are
rendered from the app's own views; the video layer and the empty title strip don't
render faithfully there (the strip shows white but is fully transparent on screen).

## Results

| Run | Change | Result |
| --- | --- | --- |
| run1 | `.autoHideToolbar` presentation option | Header stays: option never applied (options read back 1029, no 2048). `NSToolbarFullScreenWindow` 52pt visible. |
| run2 | Hide `NSToolbar` via AppKit with the controls | Header flaps: hiding it shifts the view, hover reads a "move", controls come back. |
| run3 | Compare hover in screen coordinates | Second idle clean; first idle still stuck (hover end reset the last position). Double-click toggles both ways. |
| run4/5 | Keep last pointer position across hover end | All steps pass (below). |

run5, window-server view:

- Full screen idle: toolbar hidden; strip 1920x32 pixels all alpha 0.
- After a real cursor move (`cliclick`): toolbar + controls back (strip 52pt, opaque).
- Idle again: hidden. Single click: back. Idle: hidden.
- Double-click: leaves full screen; double-click again: enters full screen.

Key frames: `run1/3-fs-idle.png` (before), `run5/3c-fs-idle.png`,
`run5/4-fs-after-real-mouse-move.png`, `run5/5c-fs-after-single-click.png`.
