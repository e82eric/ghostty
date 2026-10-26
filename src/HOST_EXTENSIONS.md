# Host extension modules

Custom embedding code lives in these modules so upstream updates can focus on
the smaller integration hooks in existing Ghostty files.

| Module | Responsibility | Integration point |
| --- | --- | --- |
| `apprt/embedded_snapshot.zig` | Snapshot, style export, navigation, search-reader, and decoration C APIs | `embedded.zig` imports the exports |
| `apprt/embedded_host.zig` | Host frame/font export, live cursor reads, shell identity, and USB key input | `embedded.zig` imports the exports |
| `surface/Snapshot.zig` | Snapshot ownership, generation, caches, entry/exit, and scrolling | One state field plus destruction and scroll hooks in `Surface.zig` |
| `terminal/SnapshotReflow.zig` | Reflow a frozen terminal and return an owned translation map | Snapshot C API |
| `terminal/SnapshotStyleRuns.zig` | Resolved, coalesced style runs captured once for Rust document previews | Snapshot style-run C API |
| `terminal/ReflowMap.zig` | Sorted cell segments and per-source-row offset index | `PageList.zig` records cell movement during reflow; Rust performs indexed lookups |
| `renderer/SnapshotDecorations.zig` | Owned decoration message payload | One renderer message variant |
| `renderer/SnapshotOverrides.zig` | Overlay that patches decoration colors and replacement text into the render state; caret shader uniforms | Renderer lifecycle, `prepare`/`apply` around the render state update, and caret uniforms |
| `renderer/Wgpu.zig` | Graphics API that forwards GPU operations to the host's wgpu device and exports frames as host textures | `renderer.zig` backend selection and the `wgpu` platform |
| `os/ConPty.zig` | Load the application-local ConPTY DLL with system fallback | Windows PTY lifecycle |
| `termio/host_process.zig` | Shell process identity, MSYS terminfo paths, and Windows quit signaling | Exec lifecycle hooks |
| `c_api_host.zig` | Host initialization, argument quoting, and error accessors | C initialization wrapper and export import |
| `config/c_api_host.zig` | Theme and font overrides, theme-directory enumeration | Config C API export import |
| `config/c_get_host.zig` | Extra configuration value conversions | Config getter hooks |
| `build/EmbeddedSamples.zig` | Native sample builds and ConPTY installation | Build entry point |
| `build/WindowsResources.zig` | Compile terminfo with Git/MSYS ncurses tools | Resource build hook |

`terminal/SnapshotLogicalPosition.zig` resolves logical line/UTF-8 offsets to
current snapshot cells on demand. Its APIs in `apprt/embedded_snapshot.zig`
also capture the logical origin of windowed line-split documents; retained
picker candidates need no resize map or additional positional payload.

Standalone host regression tests live in `terminal/host_regression_tests.zig`
and `input/host_key_tests.zig`; the owning upstream modules reference them.
Tests for extracted APIs remain beside their implementation.

Some upstream edits are necessary: platform union tags, renderer state and
message hooks, terminal choice for rendering/scrolling, resize notification
ordering, the borrowed IO wakeup handle, and host platform integration. Keep these
hooks when updating from `hashi/main`. The helper modules own custom logic;
they do not contain alternate copies of complete upstream functions.

Upstream error handlers retain their original logging and return values.
Detailed last-error reporting belongs to the custom APIs. Host wrappers clear
that state before checked operations; upstream APIs do not manage it.
