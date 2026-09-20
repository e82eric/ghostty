# Native Win32 sample

This sample embeds the full Ghostty runtime and uses its existing OpenGL
renderer with a WGL window context. It is built entirely from this checkout.
It has no dependency on WinTTY or WinUI.

From the repository root, with Zig 0.16.0 and the Windows SDK installed:

```powershell
zig build win32-sample -Doptimize=ReleaseFast
.\zig-out\bin\ghostty_win32.exe
```

The build places both the executable and its matching `ghostty.dll` in
`zig-out/bin`. No manual import-library generation or copying is needed.
This full-runtime example uses the root build rather than the standalone
libghostty-vt example template.

A graphics driver supporting desktop OpenGL 4.3 is required. The sample opens
the configured shell through ConPTY and reads the normal Ghostty configuration.
Command-line configuration also works, for example
`.\zig-out\bin\ghostty_win32.exe --command=pwsh.exe`. On Windows the C API reads
the host process's Unicode command line. Diagnostics go to stderr by default;
set `GHOSTTY_LOG=no-stderr` to disable them.
Keyboard input, left-button selection, wheel scrolling, resize, focus, and
per-monitor DPI events are forwarded to Ghostty. Clipboard integration, IME
composition, tabs, and the inspector are outside this minimal sample.

Presentation runs on Ghostty's renderer thread: the offscreen color target is
blitted to the window backbuffer on the GPU, then swapped. The initial port
retains `glFinish` for conservative resource reuse. This is a functional
sample, not a claim of optimal latency or throughput.
