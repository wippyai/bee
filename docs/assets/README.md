# Repository images

`banner.svg` is the banner used by the README; `banner.png` is its 2× raster export.
`logo.svg` contains the standalone repository mark; `logo.png` is its raster export.
Both use the character artwork from the application's
[welcome screen](../../src/core/terminal/chrome.lua) and the Honey palette from
the [UI brand book](../UI_BRAND_BOOK.md). Their font lists include generic
fallbacks so the SVGs remain portable.

`desktop.gif` was captured on 2026-09-07 from the standalone Linux Bee binary
built with the fullscreen handlers and subsequent workspace-header cleanup. It contains 12
terminal frames rendered from actual PTY output in a disposable workspace:
Start, Settings, Ocean theme, native Terminal, a shell command, maximize, F12,
and Process Manager. Frame holds are edited for readability. The terminal prompt
was set to `bee $ ` and cleared before recording. No model or generated activity
is shown. Metrics are the values emitted by that running instance.

The recording shows local desktop behavior only. It does not claim public Hive
enrollment, remote workspace composition or destination package installation.

Bee-owned artwork is MIT licensed.
