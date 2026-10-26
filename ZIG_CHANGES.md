# Zig changes: annotated upstream diffs and added modules

Baseline: `hashi/main` at `b32f20f3e8d25bb925ec545c54498e93518e7ced`. Reviewed on 2026-10-11.

This guide covers the current working tree, including uncommitted changes and
untracked Zig files. Part I shows every diff hunk in files that already exist
on the baseline. Each chunk explains why it exists and how it works. Part II
describes every file added relative to that baseline, including added files
already tracked on this branch. Diff line numbers describe this review only.

The pane uses one frozen Ghostty terminal, reflowed in place. A preview owns
an independent terminal and source-row anchors. Rust owns modal controllers
and translates retained positions through the indexed map returned by the resize
handshake. A separate immutable document remains a proposed alternative.

## Part I: changes inside existing upstream files

### build.zig

#### Chunk 1: Register the host library install

```diff
@@ -237,6 +237,7 @@ pub fn build(b: *std.Build) !void {
                 lib_shared.install("ghostty-internal.so");
                 lib_static.install("ghostty-internal.a");
             }
+            try @import("src/build/HostLibrary.zig").add(b, &config, lib_shared, libghostty_vt_static, resources);
         }
     }
```

**Why it is needed:** Needed to expose the libraries external hosts link against through the normal build graph.

**How it works:** Calls HostLibrary.add after the embedding and VT libraries and resources have been constructed. The detailed build implementation stays in a separate module.

### src/Surface.zig

#### Chunk 1: Own modal snapshot state

```diff
@@ -178,6 +178,9 @@ command_timer: ?std.Io.Timestamp = null,
 /// Search state
 search: ?Search = null,
 
+/// Host-owned modal presentation state.
+snapshot: @import("surface/Snapshot.zig") = .{},
+
 /// Used to rate limit BEL handling.
 last_bell_time: ?std.Io.Timestamp = null,
```

**Why it is needed:** Needed to associate a frozen terminal and its caches with the owning pane.

**How it works:** Adds a Snapshot value initialized with empty/default state; the separate module owns lifecycle operations.

#### Chunk 2: Borrow the renderer wakeup

```diff
@@ -678,7 +681,7 @@ pub fn init(
             .backend = .{ .exec = io_exec },
             .mailbox = io_mailbox,
             .renderer_state = &self.renderer_state,
-            .renderer_wakeup = render_thread.wakeup,
+            .renderer_wakeup = &self.renderer_thread.wakeup,
             .renderer_mailbox = render_thread.mailbox,
             .surface_mailbox = .{ .surface = self, .app = app_mailbox },
         });
```

**Why it is needed:** Needed because an IOCP Async waiter must not be copied after it is shared.

**How it works:** Passes the address of self.renderer_thread.wakeup, whose storage remains stable through IO lifetime, rather than a copy of the temporary render_thread value.

#### Chunk 3: Release the snapshot on destruction

```diff
@@ -792,6 +795,7 @@ pub fn init(
 pub fn deinit(self: *Surface) void {
     // Stop search thread
     if (self.search) |*s| s.deinit();
+    self.snapshot.end(self);
 
     // Stop rendering thread
     {
```

**Why it is needed:** Needed to detach and free modal resources before renderer teardown.

**How it works:** Calls snapshot.end after stopping built-in search and before stopping the renderer thread.

#### Chunk 4: Remove an empty line

```diff
@@ -1406,7 +1410,6 @@ fn passwordInput(self: *Surface, v: bool) !void {
         // waste time doing anything more.
         const old = self.io.terminal.flags.password_input;
         if (old == v) return;
-
         self.io.terminal.flags.password_input = v;
     }
```

**Why it is needed:** Not needed for behavior; this is incidental formatting.

**How it works:** Deletes only whitespace between the unchanged password-input guard and assignment.

#### Chunk 5: Restart cursor blink when typing

```diff
@@ -2866,6 +2869,15 @@ pub fn keyCallback(
     // some data to send to the pty, then we move the viewport down to the
     // bottom. We also clear the selection for any key other then modifiers.
     if (!event.key.modifier()) {
+        // Keep the cursor visible while typing and restart its blink interval.
+        if (event.action != .release) {
+            _ = self.renderer_thread.mailbox.push(
+                global.io(),
+                .{ .reset_cursor_blink = {} },
+                .{ .instant = {} },
+            );
+        }
+
         self.renderer_state.mutex.lockUncancelable(global.io());
         defer self.renderer_state.mutex.unlock(global.io());
```

**Why it is needed:** Needed to keep typing visible without resetting blink on every batch of process output.

**How it works:** Non-modifier events other than release send reset_cursor_blink through the renderer mailbox. Termio no longer resets blinking on background output.

#### Chunk 6: Route modal scroll events

```diff
@@ -3579,6 +3591,11 @@ pub fn scrollCallback(
 
     // log.info("SCROLL: delta_y={} delta_x={}", .{ y.delta, x.delta });
 
+    if (self.snapshot.scroll(self, y.delta)) {
+        try self.queueRender();
+        return;
+    }
+
     {
         self.renderer_state.mutex.lockUncancelable(global.io());
         defer self.renderer_state.mutex.unlock(global.io());
```

**Why it is needed:** Needed so scrolling moves the frozen display rather than the live terminal underneath it.

**How it works:** Snapshot.scroll returns true when modal presentation consumes the event; the caller queues a render and returns before the normal scroll path.

#### Chunk 7: Route explicit row jumps

```diff
@@ -5262,7 +5279,7 @@ pub fn performBindingAction(self: *Surface, action: input.Binding.Action) !bool
             {
                 self.renderer_state.mutex.lockUncancelable(global.io());
                 defer self.renderer_state.mutex.unlock(global.io());
-                const t: *terminal.Terminal = self.renderer_state.terminal;
+                const t = self.renderer_state.terminalForRender();
                 t.screens.active.scroll(.{ .row = n });
             }
```

**Why it is needed:** Needed for the scroll-to-row binding to affect the terminal currently being shown.

**How it works:** Under the existing renderer-state mutex, terminalForRender chooses the snapshot when present and the live terminal otherwise.

### src/apprt/embedded.zig

#### Chunk 1: Add host platform variants

```diff
@@ -382,6 +382,14 @@ pub const App = struct {
 pub const Platform = union(PlatformTag) {
     macos: MacOS,
     ios: IOS,
+    windows: extern struct { hwnd: *anyopaque },
+    opengl: OpenGL,
+
+    pub const OpenGL = extern struct {
+        window: ?*anyopaque,
+        display: ?*anyopaque,
+        context: *anyopaque,
+    };
 
     // If our build target for libghostty is not darwin then we do
     // not include macos support at all.
```

**Why it is needed:** Needed to construct a native Windows surface or embed rendering into a host OpenGL context.

**How it works:** Adds the HWND platform and a typed external-context payload containing window, display, and context handles.

#### Chunk 2: Add the Windows C platform payload

```diff
@@ -398,6 +406,7 @@ pub const Platform = union(PlatformTag) {
     // The C ABI compatible version of this union. The tag is expected
     // to be stored elsewhere.
     pub const C = extern union {
+        windows: extern struct { hwnd: ?*anyopaque },
         macos: extern struct {
             nsview: ?*anyopaque,
         },
```

**Why it is needed:** Needed to accept a Win32 window through the C ABI.

**How it works:** Adds a nullable HWND pointer to the extern union; validation happens in Platform.init.

#### Chunk 3: Add OpenGL payload and Windows validation

```diff
@@ -405,12 +414,22 @@ pub const Platform = union(PlatformTag) {
         ios: extern struct {
             uiview: ?*anyopaque,
         },
+
+        opengl: extern struct {
+            window: ?*anyopaque,
+            display: ?*anyopaque,
+            context: ?*anyopaque,
+        },
     };
 
     /// Initialize a Platform a tag and configuration from the C ABI.
     pub fn init(tag_int: c_int, c_platform: C) !Platform {
         const tag = std.enums.fromInt(PlatformTag, tag_int) orelse return error.InvalidEnumTag;
         return switch (tag) {
+            .windows => if (builtin.os.tag == .windows)
+                .{ .windows = .{ .hwnd = c_platform.windows.hwnd orelse return error.HWNDMustBeSet } }
+            else
+                error.UnsupportedPlatform,
             .macos => if (MacOS != void) macos: {
                 const config = c_platform.macos;
                 const nsview = objc.Object.fromId(config.nsview orelse
```

**Why it is needed:** Needed for the host to pass GL handles and for invalid Windows platform requests to fail predictably.

**How it works:** Extends the extern union, then dispatches the Windows tag only on Windows and requires a non-null HWND.

#### Chunk 4: Validate the external OpenGL context

```diff
@@ -424,6 +443,12 @@ pub const Platform = union(PlatformTag) {
                     break :ios error.UIViewMustBeSet);
                 break :ios .{ .ios = .{ .uiview = uiview } };
             } else error.UnsupportedPlatform,
+
+            .opengl => .{ .opengl = .{
+                .window = c_platform.opengl.window,
+                .display = c_platform.opengl.display,
+                .context = c_platform.opengl.context orelse return error.OpenGLContextMustBeSet,
+            } },
         };
     }
 };
```

**Why it is needed:** Needed to prevent constructing a shared rendering context without its required source context.

**How it works:** Builds the OpenGL platform value while rejecting a null context; window and display remain optional for platform-specific handling.

#### Chunk 5: Assign platform tag values

```diff
@@ -434,6 +459,8 @@ pub const PlatformTag = enum(c_int) {
 
     macos = 1,
     ios = 2,
+    windows = 3,
+    opengl = 4,
 };
 
 pub const EnvVar = extern struct {
```

**Why it is needed:** Needed for C callers to select the added union variants.

**How it works:** Appends windows=3 and opengl=4 while retaining the existing macOS and iOS values.

#### Chunk 6: Reference standalone host exports

```diff
@@ -1470,6 +1497,11 @@ pub const Inspector = struct {
 
 // C API
 pub const CAPI = struct {
+    comptime {
+        _ = @import("embedded_snapshot.zig");
+        _ = @import("embedded_host.zig");
+    }
+
     /// This is the same as Surface.KeyEvent but this is the raw C API version.
     const KeyEvent = extern struct {
         action: input.Action,
```

**Why it is needed:** Needed because Zig must analyze the modules for their export declarations to be emitted.

**How it works:** The CAPI comptime block imports embedded_snapshot and embedded_host; implementations remain outside upstream function bodies.

#### Chunk 7: Clamp coordinates in the correct space

```diff
@@ -1602,13 +1634,23 @@ pub const CAPI = struct {
                 ),
             };
 
-            // Clamp our point to the screen bounds.
-            const clamped_x = @min(self.x, screen.pages.cols -| 1);
-            const clamped_y = @min(self.y, screen.pages.rows -| 1);
-
             return switch (self.coord_tag) {
                 // Exact coordinates require a specific pin.
                 .exact => exact: {
+                    // Each point tag has a different vertical extent. In
+                    // particular, `.screen` includes all retained history,
+                    // which can be much taller than the active viewport.
+                    const bottom_right = screen.pages.getBottomRight(tag) orelse
+                        return null;
+                    const bottom_right_point = screen.pages.pointFromPin(
+                        tag,
+                        bottom_right,
+                    ) orelse return null;
+                    const clamped_x = @min(self.x, screen.pages.cols -| 1);
+                    const clamped_y = @min(
+                        self.y,
+                        bottom_right_point.coord().y,
+                    );
                     const pt_x = std.math.cast(
                         terminal.size.CellCountInt,
                         clamped_x,
```

**Why it is needed:** Needed because screen coordinates include scrollback and can exceed active-screen height.

**How it works:** Moves clamping into the exact-position branch, obtains the requested coordinate space's bottom-right point, and clamps y against that extent before constructing a pin.

#### Chunk 8: Include the scrollback-coordinate regression

```diff
@@ -1652,6 +1694,10 @@ pub const CAPI = struct {
         }
     };
 
+    test "embedded screen point spans full scrollback" {
+        try @import("embedded_host.zig").screenPointSpansScrollback(Point, Point.pin);
+    }
+
     // Reference the conditional exports based on target platform
     // so they're included in the C API.
     comptime {
```

**Why it is needed:** Needed to prevent history selections being clamped back into the active screen.

**How it works:** Passes the private Point type and pin function to a separate test helper; no new public upstream API is required.

### src/build/GhosttyLib.zig

#### Chunk 1: Expose an import-library output

```diff
@@ -14,6 +14,7 @@ step: *std.Build.Step,
 
 /// The final static library file
 output: std.Build.LazyPath,
+implib: ?std.Build.LazyPath = null,
 dsym: ?std.Build.LazyPath,
 pkg_config: ?std.Build.LazyPath,
 pkg_config_static: ?std.Build.LazyPath,
```

**Why it is needed:** Needed for a Windows host to link against the DLL.

**How it works:** Adds an optional LazyPath field; targets without import libraries leave it null.

#### Chunk 2: Capture the emitted import library

```diff
@@ -172,6 +173,7 @@ pub fn initShared(
     return .{
         .step = &lib.step,
         .output = lib.getEmittedBin(),
+        .implib = if (deps.config.target.result.os.tag == .windows) lib.getEmittedImplib() else null,
         .dsym = dsymutil,
         .pkg_config = pcs.shared,
         .pkg_config_static = pcs.static,
```

**Why it is needed:** Needed to connect Windows DLL output to the sample linker/install steps.

**How it works:** initShared records getEmittedImplib only for Windows, alongside the existing binary output.

### src/build/GhosttyResources.zig

#### Chunk 1: Compile Windows terminfo

```diff
@@ -53,8 +53,10 @@ pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty
             try steps.append(b.allocator, &source_install.step);
         }
 
-        // Windows doesn't have the binaries below.
-        if (os_tag == .windows) break :terminfo;
+        if (os_tag == .windows) {
+            try steps.append(b.allocator, try @import("WindowsResources.zig").compileTerminfo(b, source, terminfo_share_dir));
+            break :terminfo;
+        }
 
         // Convert to termcap source format if thats helpful to people and
         // install it. The resulting value here is the termcap source in case
```

**Why it is needed:** Needed so bundled ncurses tools can recognize Ghostty capabilities on Windows.

**How it works:** Replaces the Windows early skip with the separate compileTerminfo helper, appends its install step, and then exits the Windows branch.

### src/build/SharedDeps.zig

#### Chunk 1: Avoid unavailable Unix headers

```diff
@@ -217,7 +217,10 @@ pub fn add(
     // (note: errno is C stdlib but we just include it here because that's
     // where it's generally included otherwise)
     try translate_c.addImportToModule(b, "posix_c", step.root_module, .{
-        .source = .{ .includes = .{ .files = &.{
+        .source = .{ .includes = .{ .files = if (target.result.os.tag == .windows) &.{
+            .{ .path = "errno.h" },
+            .{ .path = "signal.h" },
+        } else &.{
             .{ .path = "errno.h" },
             .{ .path = "pwd.h" },
             .{ .path = "signal.h" },
```

**Why it is needed:** Needed for POSIX-C translation to compile with the Windows toolchain.

**How it works:** Windows translates errno.h and signal.h; other targets retain the existing list including pwd.h.

#### Chunk 2: Link Windows OpenGL support

```diff
@@ -471,6 +474,9 @@ pub fn add(
     // C files
     step.root_module.link_libc = true;
     step.root_module.addIncludePath(b.path("src/stb"));
+    if (target.result.os.tag == .windows and self.config.renderer == .opengl) {
+        @import("EmbeddedSamples.zig").linkWindowsOpenGL(b, step);
+    }
     // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
     // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
     // the static archive is consumed by an external linker.
```

**Why it is needed:** Needed for WGL/context support and native GL symbols in Windows OpenGL builds.

**How it works:** Calls the standalone build helper only when both Windows and OpenGL are selected.

### src/config/CApi.zig

#### Chunk 1: Reference host configuration exports

```diff
@@ -11,6 +11,10 @@ const Key = @import("key.zig").Key;
 
 const log = std.log.scoped(.config);
 
+comptime {
+    _ = @import("c_api_host.zig");
+}
+
 /// Create a new configuration filled with the initial default values.
 export fn ghostty_config_new() ?*Config {
     const result = global.alloc().create(Config) catch |err| {
```

**Why it is needed:** Needed to emit theme/font and theme-directory C exports implemented in the separate module.

**How it works:** A comptime import references c_api_host; the original config functions and error handlers remain unchanged.

### src/config/c_get.zig

#### Chunk 1: Delegate extra configuration keys

```diff
@@ -15,6 +15,7 @@ const Value = key.Value;
 /// some key, please open an issue.
 pub fn get(config: *const Config, k: Key, ptr_raw: *anyopaque) bool {
     @setEvalBranchQuota(10_000);
+    if (@import("c_get_host.zig").extra(config, k, ptr_raw)) |result| return result;
     switch (k) {
         inline else => |tag| {
             const value = fieldByKey(config, tag);
```

**Why it is needed:** Needed to expose the current theme name using the existing config-get API.

**How it works:** extra returns null when a key is not handled, allowing upstream dispatch to continue; otherwise its boolean result is returned.

#### Chunk 2: Convert literal terminal colors

```diff
@@ -27,6 +28,7 @@ pub fn get(config: *const Config, k: Key, ptr_raw: *anyopaque) bool {
 /// the type is not supported by the C API yet or the value is null.
 fn getValue(ptr_raw: *anyopaque, value: anytype) bool {
     switch (@TypeOf(value)) {
+        Config.TerminalColor => return @import("c_get_host.zig").terminalColor(ptr_raw, value),
         ?[:0]const u8 => {
             const ptr: *?[*:0]const u8 = @ptrCast(@alignCast(ptr_raw));
             ptr.* = if (value) |slice| @ptrCast(slice.ptr) else null;
```

**Why it is needed:** Needed to expose configured RGB colors while rejecting symbolic cell-relative colors.

**How it works:** Dispatches the TerminalColor value type to terminalColor before the normal conversions. This covers every key with that type.

#### Chunk 3: Include getter regression tests

```diff
@@ -238,3 +240,7 @@ test "c_get: split-preserve-zoom" {
     try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
     try testing.expectEqual(@as(c_uint, 1), bits);
 }
+
+test {
+    _ = @import("c_get_host.zig");
+}
```

**Why it is needed:** Needed to exercise theme-name and terminal-color conversions in the normal test graph.

**How it works:** A test-only import references the helper module and its tests.

### src/global.zig

#### Chunk 1: Name the ordinary C initialization payload

```diff
@@ -34,6 +34,12 @@ pub const xev = @import("xev").Dynamic;
 /// retrieve items stored in this state.
 var state: ?GlobalState = null;
 
+const CInitOpts = struct {
+    argc: usize,
+    argv: [*][*:0]u8,
+    environ: std.process.Environ,
+};
+
 pub const InitOpts = union(enum) {
     main: std.process.Init.Minimal,
```

**Why it is needed:** Needed to retain ordinary C initialization alongside the added UTF-8 host path.

**How it works:** Factors argc, argv, and environ into CInitOpts; this is a structural change, not another parsing algorithm.

#### Chunk 2: Accept a prepared host argument vector

```diff
@@ -44,9 +50,11 @@ pub const InitOpts = union(enum) {
     /// otherwise cause init to fail with InvalidAction.
     tool: std.process.Init.Minimal,
 
-    c: struct {
-        argc: usize,
-        argv: [*][*:0]u8,
+    c: CInitOpts,
+
+    /// C host that provides its own argument vector, including on Windows.
+    c_utf8: struct {
+        args: std.process.Args,
         environ: std.process.Environ,
     },
 };
```

**Why it is needed:** Needed when Rust supplies its own UTF-8 arguments on Windows.

**How it works:** InitOpts.c uses CInitOpts; c_utf8 carries std.process.Args and the environment after conversion by c_api_host.

#### Chunk 3: Select Unicode-safe argument sources

```diff
@@ -63,19 +71,17 @@ pub fn init(opts: InitOpts) !void {
         .environ = switch (opts) {
             .main, .tool => |m| m.environ,
             .c => |c| c.environ,
+            .c_utf8 => |c| c.environ,
         },
         .args = switch (opts) {
             .main, .tool => |m| m.args,
-            // TODO: Using the C API from Windows is unsupported at this time.
-            //
-            // When do we plan on supporting Windows, it's recommended to
-            // ensure that the C API can take a UNICODE_STRING (aka []16, a
-            // WTF-16 string) so that it can just be passed into
-            // std.process.Args.Vector directly.
+            // Preserve the host process's Unicode command line on Windows;
+            // CRT argv may have already lost characters in codepage conversion.
             .c => |c| .{ .vector = if (builtin.os.tag == .windows)
-                return error.UnsupportedOSForCApi
+                std.os.windows.peb().ProcessParameters.CommandLine.slice()
             else
                 c.argv[0..c.argc] },
+            .c_utf8 => |c| c.args,
         },
         .tmp_dir_path = null,
         .action = null,
```

**Why it is needed:** Needed to remove the Windows C API rejection without using lossy CRT argv.

**How it works:** Ordinary C initialization reads the process's UTF-16 command line on Windows. c_utf8 uses its prepared Args vector. Both select their corresponding environment.

#### Chunk 4: Detect actions for UTF-8 host arguments

```diff
@@ -127,7 +133,7 @@ pub fn init(opts: InitOpts) !void {
     // Tool binaries (ghostty-bench, ghostty-gen) have their own action
     // namespace and detect their own actions, so we skip detection here.
     self.action = switch (opts) {
-        .main, .c => try cli.action.detectArgs(
+        .main, .c, .c_utf8 => try cli.action.detectArgs(
             cli.ghostty.Action,
             self.alloc,
             self.args,
```

**Why it is needed:** Needed for host-supplied arguments to participate in normal CLI action handling.

**How it works:** Includes c_utf8 in the same action-detection branch as main and c; tool binaries still follow their existing path.

### src/input/key_encode.zig

#### Chunk 1: Include consumed-Shift regression

```diff
@@ -2842,3 +2842,7 @@ test "ctrlseq: right ctrl c" {
     });
     try testing.expectEqual(@as(u8, 0x03), seq.?);
 }
+
+test "kitty: consumed shift emits translated punctuation" {
+    try @import("host_key_tests.zig").consumedShift(kitty);
+}
```

**Why it is needed:** Needed to verify translated punctuation is not shifted twice when encoded for kitty keyboard protocol.

**How it works:** Calls the extracted helper with the private kitty encoder. This adds a test, not a runtime encoder change.

### src/lib/compat/fd.zig

#### Chunk 1: Close Windows HANDLE values

```diff
@@ -8,6 +8,10 @@ pub const PipeError = error{
 } || std.posix.UnexpectedError;
 
 pub fn close(fd: std.posix.fd_t) void {
+    if (@import("builtin").os.tag == .windows) {
+        std.os.windows.CloseHandle(fd);
+        return;
+    }
     switch (std.posix.errno(std.posix.system.close(fd))) {
         .BADF => unreachable, // Always a race condition
         else => {}, // Includes EINTR, see std.posix source in 0.15.2
```

**Why it is needed:** Needed because Windows fd_t is a handle, not a POSIX integer descriptor.

**How it works:** The Windows branch calls CloseHandle and returns; the existing errno-based close remains for other platforms.

### src/main_c.zig

#### Chunk 1: Reference initialization/error exports

```diff
@@ -35,6 +35,8 @@ comptime {
     // These structs need to be referenced so the `export` functions
     // are truly exported by the C API lib.
 
+    _ = @import("c_api_host.zig");
+
     // Our config API
     _ = @import("config.zig").CApi;
```

**Why it is needed:** Needed for the separate host initializer and error accessors to be present in the C library.

**How it works:** Adds a comptime reference to c_api_host.

#### Chunk 2: Use the Windows CRT memset

```diff
@@ -47,7 +49,8 @@ comptime {
 
     // Force-reference our memset override so its export is emitted.
     // See quirks_memset.zig for details on why this exists.
-    _ = @import("quirks_memset.zig");
+    // MSVC's CRT supplies a strong memset in DLL builds as well.
+    if (builtin.os.tag != .windows) _ = @import("quirks_memset.zig");
 }
 
 /// ghostty_info_s
```

**Why it is needed:** Needed to avoid exporting a conflicting strong memset alongside MSVC CRT.

**How it works:** References the custom memset module only on non-Windows targets.

#### Chunk 3: Delegate initialization

```diff
@@ -108,30 +111,7 @@ pub const String = extern struct {
 
 /// Initialize ghostty global state.
 pub export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
-    assert(builtin.link_libc);
-
-    global.init(.{
-        .c = .{
-            .argc = argc,
-            .argv = argv,
-            .environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
-                // Asserting libc means that we can fast-path all POSIX blocks
-                .{ .block = .{ .slice = std.c.environ[0..env_len: {
-                    var len: usize = 0;
-                    while (std.c.environ[len]) |_| : (len += 1) {}
-                    break :env_len len;
-                } :null] } }
-            else
-                // Anything that is not using PosixBlock is a global block for
-                // purposes of initialization.
-                .{ .block = .{ .use_global = true } },
-        },
-    }) catch |err| {
-        std.log.err("failed to initialize ghostty error={}", .{err});
-        return 1;
-    };
-
-    return 0;
+    return @import("c_api_host.zig").init(argc, argv, false);
 }
 
 /// Runs an action if it is specified. If there is no action this returns
```

**Why it is needed:** Needed to share initialization behavior with ghostty_init_utf8 while isolating custom logic.

**How it works:** Replaces the inline ordinary initializer with c_api_host.init(argc, argv, false); the false argument selects ordinary C argument semantics.

#### Chunk 4: Initialize MSVC DLL runtime tables

```diff
@@ -206,14 +186,20 @@ pub const DllMain = if (builtin.os.tag == .windows) struct {
     const __vcrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__vcrt_uninitialize" });
     const __acrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__acrt_initialize" });
     const __acrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__acrt_uninitialize" });
+    const __scrt_initialize_onexit_tables = @extern(*const fn (c_int) callconv(.c) bool, .{ .name = "__scrt_initialize_onexit_tables" });
 
     pub fn handler(_: HINSTANCE, fdwReason: DWORD, _: LPVOID) callconv(.winapi) BOOL {
         // Only MSVC needs to bootstrap the CRT; MinGW handles it via dllcrt2.obj.
         if (builtin.abi != .msvc) return TRUE;
         switch (fdwReason) {
             DLL_PROCESS_ATTACH => {
-                if (__vcrt_initialize() < 0) return FALSE;
-                if (__acrt_initialize() < 0) return FALSE;
+                if (__vcrt_initialize() == 0) return FALSE;
+                if (__acrt_initialize() == 0) return FALSE;
+                // MSVC startup normally initializes its module-local encoded
+                // atexit tables. Zig's DLL entry point skips that step. Without
+                // it, glslang's first thread-local destructor registration
+                // treats an encoded-null pointer as a heap allocation.
+                if (!__scrt_initialize_onexit_tables(0)) return FALSE; // dll
                 return TRUE;
             },
             DLL_PROCESS_DETACH => {
```

**Why it is needed:** Needed for correct CRT failure detection and glslang thread-local destructor registration.

**How it works:** Tests CRT initializer returns against zero and initializes module-local onexit tables on process attach. MinGW returns through its existing startup path; this stays at the DLL lifecycle boundary.

### src/main_ghostty.zig

#### Chunk 1: Include viewport helper tests

```diff
@@ -236,6 +236,7 @@ test {
     _ = @import("Command.zig");
     _ = @import("font/main.zig");
     _ = @import("apprt.zig");
+    _ = @import("apprt/snapshot_viewport.zig");
     _ = @import("renderer.zig");
     _ = @import("termio.zig");
     _ = @import("input.zig");
```

**Why it is needed:** Needed for the standalone reveal-with-padding regressions to run through the normal test entry point.

**How it works:** Adds a test-only module import; runtime entry behavior is unchanged.

### src/pty.zig

#### Chunk 1: Add original-process identity requests

```diff
@@ -37,6 +37,9 @@ pub const Mode = packed struct {
 };
 
 pub const ProcessInfo = enum {
+    /// PID of the original shell launched for this surface.
+    shell_pid,
+    shell_creation_time,
     /// The PID of the process that controls the PTY.
     foreground_pid,
     /// Gets the name of the slave PTY. Returned name points to an internal buffer
```

**Why it is needed:** Needed for the host to identify the shell initially launched for a surface.

**How it works:** Extends ProcessInfo with shell_pid and shell_creation_time, distinct from the current foreground PID.

#### Chunk 2: Declare identity result types

```diff
@@ -45,7 +48,7 @@ pub const ProcessInfo = enum {
 
     pub fn Type(comptime info: ProcessInfo) type {
         return switch (info) {
-            .foreground_pid => u64,
+            .foreground_pid, .shell_pid, .shell_creation_time => u64,
             .tty_name => [:0]const u8,
         };
     }
```

**Why it is needed:** Needed for typed callers of the added process-info variants.

**How it works:** Both new variants return u64 through ProcessInfo.Type.

#### Chunk 3: Leave original identity to Exec

```diff
@@ -270,6 +273,7 @@ const PosixPty = struct {
     /// is not available on a particular platform.
     pub fn getProcessInfo(self: *PosixPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
         return switch (info) {
+            .shell_pid, .shell_creation_time => null,
             .foreground_pid => {
                 switch (builtin.os.tag) {
                     .linux => {
```

**Why it is needed:** Needed because a PTY itself does not supply the original spawned-process identity.

**How it works:** The POSIX PTY branch returns null for the added variants; Exec intercepts them using its cached spawn information.

#### Chunk 4: Own the selected ConPTY API

```diff
@@ -331,11 +335,14 @@ const WindowsPty = struct {
     // Process-wide counter for pipe names
     var pipe_name_counter = std.atomic.Value(u32).init(1);
 
+    const ConPtyApi = @import("os/ConPty.zig");
+
     out_pipe: windows.HANDLE,
     in_pipe: windows.HANDLE,
     out_pipe_pty: windows.HANDLE,
     in_pipe_pty: windows.HANDLE,
     pseudo_console: windows.HPCON,
+    conpty: ConPtyApi,
     size: winsize,
 
     pub const OpenError = error{Unexpected};
```

**Why it is needed:** Needed to retain the DLL reference and matching operations throughout the pseudo-console lifetime.

**How it works:** WindowsPty imports ConPty and adds an owned API value next to the console handle.

#### Chunk 5: Load ConPTY with failure cleanup

```diff
@@ -343,6 +350,8 @@ const WindowsPty = struct {
     /// Open a new PTY with the given initial size.
     pub fn open(size: winsize) OpenError!Pty {
         var pty: Pty = undefined;
+        pty.conpty = ConPtyApi.load();
+        errdefer pty.conpty.deinit();
 
         var pipe_path_buf: [128]u8 = undefined;
         var pipe_path_buf_w: [128]u16 = undefined;
```

**Why it is needed:** Needed to choose the bundled runtime before console creation and avoid leaking its module on failure.

**How it works:** Loads the API at open entry and registers errdefer deinit.

#### Chunk 6: Create with the selected runtime

```diff
@@ -440,7 +449,7 @@ const WindowsPty = struct {
         try SetHandleInformation.f(pty.out_pipe);
         try SetHandleInformation.f(pty.out_pipe_pty);
 
-        const result = windows.exp.kernel32.CreatePseudoConsole(
+        const result = pty.conpty.create(
             .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
             pty.in_pipe_pty,
             pty.out_pipe_pty,
```

**Why it is needed:** Needed to actually use the application-local ConPTY when available.

**How it works:** Calls pty.conpty.create with the existing dimensions and pipe handles instead of the fixed system function.

#### Chunk 7: Close and unload the selected runtime

```diff
@@ -458,7 +467,8 @@ const WindowsPty = struct {
         _ = windows.exp.kernel32.CloseHandle(self.in_pipe);
         _ = windows.exp.kernel32.CloseHandle(self.out_pipe_pty);
         _ = windows.exp.kernel32.CloseHandle(self.out_pipe);
-        _ = windows.exp.kernel32.ClosePseudoConsole(self.pseudo_console);
+        self.conpty.close(self.pseudo_console);
+        self.conpty.deinit();
         self.* = undefined;
     }
```

**Why it is needed:** Needed to destroy the console through its creating API and release the module afterward.

**How it works:** Uses the stored close function, then deinitializes the API before invalidating the PTY state.

#### Chunk 8: Resize with the selected runtime

```diff
@@ -473,7 +483,7 @@ const WindowsPty = struct {
 
     /// Set the size of the pty.
     pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
-        const result = windows.exp.kernel32.ResizePseudoConsole(
+        const result = self.conpty.resize(
             self.pseudo_console,
             .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
         );
```

**Why it is needed:** Needed to use the same implementation for creation and subsequent resize calls.

**How it works:** Dispatches through self.conpty.resize with the existing handle and dimensions.

### src/renderer/OpenGL.zig

#### Chunk 1: Import isolated host helpers

```diff
@@ -2,7 +2,12 @@
 pub const OpenGL = @This();
 
 const std = @import("std");
+const builtin = @import("builtin");
+const is_windows = builtin.os.tag == .windows;
+const HostContext = @import("opengl/HostContext.zig");
 const Allocator = std.mem.Allocator;
+const OutputPool = @import("opengl/OutputPool.zig");
+pub const TextureFrame = OutputPool.TextureFrame;
 const gl = @import("opengl");
 const egl = gl.egl;
 const shadertoy = @import("shadertoy.zig");
```

**Why it is needed:** Needed to dispatch platform work and expose leased texture frame types.

**How it works:** Imports builtin, HostContext, and OutputPool, defines is_windows, and aliases TextureFrame.

#### Chunk 2: Select Windows or shared EGL context setup

```diff
@@ -43,13 +48,34 @@ alloc: std.mem.Allocator,
 /// Alpha blending mode
 blending: configpkg.Config.AlphaBlending,
 
-egl_display: *gl.egl.Display,
-egl_context: *gl.egl.Context,
+egl_display: *gl.egl.Display = undefined,
+egl_context: *gl.egl.Context = undefined,
+wgl_context: ?*anyopaque = null,
+wgl_vsync: bool = true,
+external: bool = false,
+output_pool: ?*OutputPool = null,
 
 pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
+    const external = HostContext.externalContext(opts.rt_surface);
+    const output_pool = if (external != null) try OutputPool.create(alloc) else null;
+    errdefer if (output_pool) |v| v.destroy();
+
+    if (comptime is_windows) {
+        return .{
+            .alloc = alloc,
+            .blending = opts.config.blending,
+            .wgl_context = try HostContext.create(opts.rt_surface, external),
+            .wgl_vsync = opts.config.vsync,
+            .external = external != null,
+            .output_pool = output_pool,
+        };
+    }
     try egl.load();
 
-    const display: *egl.Display = try .init(egl.c.EGL_DEFAULT_DISPLAY);
+    const display: *egl.Display = if (external) |v|
+        @ptrCast(v.display orelse return error.EGLDisplayMustBeSet)
+    else
+        try .init(egl.c.EGL_DEFAULT_DISPLAY);
 
     log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
     log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});
```

**Why it is needed:** Needed to render in native Windows windows and externally owned GL hosts.

**How it works:** Adds platform/output state, creates a pool for external contexts with failure cleanup, delegates Windows context creation, and uses an external EGL display when provided.

#### Chunk 3: Share the host EGL context

```diff
@@ -75,7 +101,8 @@ pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
     };
 
     // Create our context.
-    const context = egl.Context.create(display, config, null, &.{
+    const share: ?*egl.Surface = if (external) |v| @ptrCast(v.context) else null;
+    const context = egl.Context.create(display, config, share, &.{
         egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
         egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
         egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
```

**Why it is needed:** Needed for exported textures to be visible in the host's context.

**How it works:** Passes the external context into EGL context creation; internal rendering continues with no shared context.

#### Chunk 4: Retain and release host state

```diff
@@ -99,10 +126,18 @@ pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
         .blending = opts.config.blending,
         .egl_display = display,
         .egl_context = context,
+        .external = external != null,
+        .output_pool = output_pool,
     };
 }
 
 pub fn deinit(self: *OpenGL) void {
+    if (self.output_pool) |v| v.destroy();
+    if (comptime is_windows) {
+        HostContext.destroy(self.wgl_context.?);
+        self.* = undefined;
+        return;
+    }
     self.egl_display.releaseCurrent();
     self.egl_context.destroy(self.egl_display) catch {};
```

**Why it is needed:** Needed to preserve external/pool ownership and destroy the proper platform context.

**How it works:** Stores new state in the EGL result; deinit releases the pool and delegates Windows context destruction before the existing EGL teardown.

#### Chunk 5: Bind WGL on the renderer thread

```diff
@@ -217,6 +252,10 @@ fn prepareContext(getProcAddress: anytype) !void {
 /// function pointers so all subsequent GL work on this thread is valid.
 pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
     _ = surface;
+    if (comptime is_windows) {
+        try HostContext.enter(self.wgl_context.?, self.wgl_vsync, prepareContext);
+        return;
+    }
     try self.egl_display.makeCurrent(null, null, self.egl_context);
     // Load our function pointers for this thread's threadlocal.
     try prepareContext(&gl.egl.getProcAddress);
```

**Why it is needed:** Needed because rendering requires a current context and loaded GL function pointers on that thread.

**How it works:** The Windows branch calls HostContext.enter with vsync and prepareContext, then bypasses EGL binding.

#### Chunk 6: Release resources with the context current

```diff
@@ -226,6 +265,11 @@ pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
 /// thread; unbinds the context from this thread so it can be destroyed on
 /// the main thread.
 pub fn threadExit(self: *OpenGL) void {
+    if (self.output_pool) |v| v.deinitResources();
+    if (comptime is_windows) {
+        HostContext.leave();
+        return;
+    }
     self.egl_display.releaseCurrent();
     gl.glad.unload();
 }
```

**Why it is needed:** Needed to delete exported textures before leaving their GL context.

**How it works:** Deinitializes pool GL resources, then leaves WGL on Windows; the non-Windows path retains EGL release and GLAD unload.

#### Chunk 7: Separate presentation from frame export

```diff
@@ -291,24 +335,46 @@ pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
 /// of the frame and is responsible for freeing it.
 ///
 /// This runs on the render thread.
-pub fn present(self: *OpenGL, target: Target) !ExportedFrame {
-    if (target.exportDmabuf(self.egl_display, self.egl_context)) |dmabuf| {
-        return .{ .dmabuf = dmabuf };
-    } else |_| {
-        // If DMABUFs fail, then use CPU buffers
-        return .{ .memory = .{
-            .width = @intCast(target.width),
-            .height = @intCast(target.height),
-            .pixels = try target.readPixelsAlloc(self.alloc),
-            .alloc = self.alloc,
-        } };
+pub fn directPresentation(self: *const OpenGL) bool {
+    return is_windows and !self.external;
+}
+
+pub fn presentDirect(self: *OpenGL, target: Target) !void {
+    std.debug.assert(self.directPresentation());
+    if (comptime is_windows) {
+        try HostContext.present(self.wgl_context.?, target);
+        return;
     }
+    unreachable;
+}
+
+pub fn exportFrame(self: *OpenGL, target: Target) !ExportedFrame {
+    if (self.external) {
+        return .{ .texture = try self.output_pool.?.exportFrame(target) };
+    }
+
+    if (comptime !is_windows) {
+        if (target.exportDmabuf(self.egl_display, self.egl_context)) |dmabuf| {
+            return .{ .dmabuf = dmabuf };
+        } else |_| {
+            // If DMABUFs fail, then use CPU buffers
+            return .{ .memory = .{
+                .width = @intCast(target.width),
+                .height = @intCast(target.height),
+                .pixels = try target.readPixelsAlloc(self.alloc),
+                .alloc = self.alloc,
+            } };
+        }
+    }
+
+    return error.FrameExportUnsupported;
 }
 
 /// A finished frame exported for presentation by the apprt.
 pub const ExportedFrame = union(enum) {
-    dmabuf: Dmabuf,
-    memory: Memory,
+    texture: TextureFrame,
+    dmabuf: if (is_windows) void else Dmabuf,
+    memory: if (is_windows) void else Memory,
 
     /// RGBA8 pixel data with premultiplied alpha, tightly packed
     /// (`width * 4` bytes per row), in CPU memory.
```

**Why it is needed:** Needed because a native window swaps directly while an embedded host consumes texture leases.

**How it works:** Adds directPresentation/presentDirect and renames export to exportFrame. External hosts use OutputPool; non-Windows internal rendering retains DMABUF/CPU fallback. ExportedFrame gains texture and platform-conditional alternatives.

#### Chunk 8: Release the selected frame kind

```diff
@@ -325,8 +391,9 @@ pub const ExportedFrame = union(enum) {
 
     pub fn deinit(self: ExportedFrame) void {
         switch (self) {
-            .dmabuf => |v| v.deinit(),
-            .memory => |v| v.deinit(),
+            .texture => |v| v.deinit(),
+            .dmabuf => |v| if (comptime !is_windows) v.deinit(),
+            .memory => |v| if (comptime !is_windows) v.deinit(),
         }
     }
 };
```

**Why it is needed:** Needed to return texture leases without compiling unsupported Windows export cleanup.

**How it works:** Texture frames release their slot; DMABUF/memory cleanup remains enabled on non-Windows targets only.

### src/renderer/State.zig

#### Chunk 1: Store the frozen presentation target

```diff
@@ -19,6 +19,12 @@ mutex: *std.Io.Mutex,
 /// The terminal data.
 terminal: *terminalpkg.Terminal,
 
+/// Independently owned terminal used for frozen presentation. Used by modal
+/// interfaces such as scrollback search that require stable contents and
+/// coordinates while still allowing the child process to make progress.
+/// Access is protected by `mutex`, just like `terminal`.
+presentation_terminal: ?*terminalpkg.Terminal = null,
+
 /// The terminal inspector, if any. This will be null while the inspector
 /// is not active and will be set when it is active.
 inspector: ?*Inspector = null,
```

**Why it is needed:** Needed to display stable modal contents while IO continues updating the live terminal.

**How it works:** Adds a nullable presentation_terminal pointer protected by the existing state mutex.

#### Chunk 2: Centralize target selection

```diff
@@ -44,6 +50,11 @@ demand: std.atomic.Value(u32) = .init(0),
 /// `yieldToDemand` knows the waiter had its turn.
 handoff_gen: std.atomic.Value(u32) = .init(0),
 
+/// The terminal the renderer should currently present.
+pub inline fn terminalForRender(self: *const State) *terminalpkg.Terminal {
+    return self.presentation_terminal orelse self.terminal;
+}
+
 /// How long `yieldToDemand` sleeps waiting for a demanding waiter to
 /// take its turn before giving up. This bounds how long the IO parse
 /// thread can stall if a wake is lost or the waiter is descheduled; a
```

**Why it is needed:** Needed so rendering and viewport callers agree on which terminal is displayed.

**How it works:** terminalForRender returns presentation_terminal when present, otherwise the original live terminal.

### src/renderer/Thread.zig

#### Chunk 1: Receive decoration updates

```diff
@@ -428,6 +428,10 @@ fn drainMailbox(self: *Thread) !void {
                 self.renderer.search_matches_dirty = true;
             },
 
+            .snapshot_decorations => |v| {
+                self.renderer.snapshot_overrides.replace(v);
+            },
+
             .inspector => |v| {
                 self.flags.has_inspector = v;
             },
```

**Why it is needed:** Needed to replace presentation layers safely on the renderer thread.

**How it works:** drainMailbox transfers the message payload to snapshot_overrides.replace through a new union branch.

### src/renderer/generic.zig

#### Chunk 1: Import decoration implementation

```diff
@@ -19,6 +19,7 @@ const constraintWidth = cellpkg.constraintWidth;
 const isCovering = cellpkg.isCovering;
 const rowNeverExtendBg = @import("row.zig").neverExtendBg;
 const Overlay = @import("Overlay.zig");
+const SnapshotOverrides = @import("SnapshotOverrides.zig");
 const imagepkg = @import("image.zig");
 const ImageState = imagepkg.State;
 const shadertoy = @import("shadertoy.zig");
```

**Why it is needed:** Needed for the shared renderer to call the isolated host decoration logic.

**How it works:** Adds the SnapshotOverrides module reference.

#### Chunk 2: Store decoration state

```diff
@@ -160,6 +161,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
         /// that do not exist anymore). These must be validated prior to use.
         search_matches: ?renderer.Message.SearchMatches,
         search_selected_match: ?renderer.Message.SearchMatch,
+        snapshot_overrides: SnapshotOverrides,
         search_matches_dirty: bool,
 
         /// The current set of cells to render. This is rebuilt on every frame
```

**Why it is needed:** Needed for layers to persist across frames.

**How it works:** Adds SnapshotOverrides alongside existing search-highlight state.

#### Chunk 3: Initialize decoration state

```diff
@@ -725,6 +727,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 .last_bottom_y = 0,
                 .search_matches = null,
                 .search_selected_match = null,
+                .snapshot_overrides = .{},
                 .search_matches_dirty = false,
 
                 // Render state
```

**Why it is needed:** Needed to start with no layers or owned arena.

**How it works:** Sets snapshot_overrides to its default empty value during renderer initialization.

#### Chunk 4: Free decoration state

```diff
@@ -818,6 +821,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
             self.terminal_state.deinit(self.alloc);
             if (self.search_selected_match) |*m| m.arena.deinit();
             if (self.search_matches) |*m| m.arena.deinit();
+            self.snapshot_overrides.deinit();
 
             self.latest_frame.deinit(global.io());
```

**Why it is needed:** Needed to release the last owned payload on renderer teardown.

**How it works:** Calls deinit alongside the existing search arena cleanup.

#### Chunk 5: Select the rendering terminal

```diff
@@ -1362,8 +1366,14 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 state.lockDemand(global.io());
                 defer state.unlockDemand(global.io());
 
+                // A presentation terminal is an owned, stable snapshot used
+                // by modal UI such as scrollback search. The live terminal
+                // continues to be updated by termio while rendering and
+                // viewport movement operate on this snapshot.
+                const render_terminal = state.terminalForRender();
+
                 // If we're in a synchronized output state, we pause all rendering.
-                if (state.terminal.modes.get(.synchronized_output)) {
+                if (render_terminal.modes.get(.synchronized_output)) {
                     log.debug("synchronized output started, skipping render", .{});
                     return;
                 }
```

**Why it is needed:** Needed so modal frames read the frozen terminal rather than changing live contents.

**How it works:** Obtains terminalForRender under the existing demand lock and checks synchronized-output state on that selected terminal.

#### Chunk 6: Keep the frozen viewport under modal control

```diff
@@ -1374,7 +1384,10 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // Update this BEFORE we update our render state so we can
                 // draw the new scrolled data immediately.
                 if (self.config.scroll_to_bottom_on_output) scroll: {
-                    const br = state.terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;
+                    // A frozen presentation must keep its viewport under the
+                    // overlay controller's control.
+                    if (state.presentation_terminal != null) break :scroll;
+                    const br = render_terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;
 
                     // If the pin hasn't changed, then don't scroll.
                     if (self.last_bottom_node == @intFromPtr(br.node) and
```

**Why it is needed:** Needed to stop live-output scroll-to-bottom policy from moving a frozen modal display.

**How it works:** Skips the scroll-to-bottom block when presentation_terminal is set; otherwise reads the selected terminal's bottom-right pin.

#### Chunk 7: Scroll the selected terminal

```diff
@@ -1385,7 +1398,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                     self.last_bottom_y = br.y;
 
                     // Scroll
-                    state.terminal.scrollViewport(.bottom);
+                    render_terminal.scrollViewport(.bottom);
                 }
 
                 // Begin the update of our terminal state. Work that
```

**Why it is needed:** Needed for the remaining automatic-scroll path to use the same target as frame generation.

**How it works:** Calls scrollViewport on render_terminal rather than state.terminal.

#### Chunk 8: Update cells and dirty state from the selected target

```diff
@@ -1395,13 +1408,14 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // hold time as short as possible.
                 try self.terminal_state.beginUpdate(
                     self.alloc,
-                    state.terminal,
+                    render_terminal,
                 );
+                if (state.presentation_terminal != null) self.terminal_state.cursor.visible = false;
 
                 // If our terminal state is dirty at all we need to redo
                 // the viewport search.
                 if (self.terminal_state.dirty != .false) {
-                    state.terminal.flags.search_viewport_dirty = true;
+                    render_terminal.flags.search_viewport_dirty = true;
                 }
 
                 // Get our scrollbar out of the terminal. We synchronize
```

**Why it is needed:** Needed to render snapshot contents and avoid displaying the live cursor over modal selection.

**How it works:** beginUpdate reads render_terminal; modal presentation hides the render-state cursor; viewport search dirtiness is marked on that target.

#### Chunk 9: Read the selected scrollbar

```diff
@@ -1409,7 +1423,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // naturally limits the number of calls to this method (it
                 // can be expensive) and also makes it so we don't need another
                 // cross-thread mailbox message within the IO path.
-                const scrollbar = state.terminal.screens.active.pages.scrollbar();
+                const scrollbar = render_terminal.screens.active.pages.scrollbar();
 
                 // Get our preedit state
                 const preedit: ?renderer.State.Preedit = preedit: {
```

**Why it is needed:** Needed for the visible scrollbar to describe the snapshot viewport/history.

**How it works:** Reads scrollbar data from render_terminal's pages.

#### Chunk 10: Freeze terminal graphics animation

```diff
@@ -1425,7 +1439,10 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // advancing a frame marks the image state dirty.
                 self.kitty_animation_next_ms = next: {
                     // Likely case: we have no kitty images, so do nothing.
-                    const storage = &state.terminal.screens.active.kitty_images;
+                    // Snapshot presentation is intentionally frozen, including
+                    // terminal graphics animations.
+                    if (state.presentation_terminal != null) break :next null;
+                    const storage = &render_terminal.screens.active.kitty_images;
                     if (storage.images.count() == 0) break :next null;
 
                     const now: std.Io.Timestamp = .now(global.io(), .awake);
```

**Why it is needed:** Needed to keep snapshot presentation visually stable.

**How it works:** Stops scheduling animation advancement in presentation mode, otherwise operates on the selected terminal's image storage.

#### Chunk 11: Update graphics from the selected target

```diff
@@ -1451,14 +1468,14 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // If we have any virtual references, we must also rebuild our
                 // kitty state on every frame because any cell change can move
                 // an image.
-                if (self.images.kittyRequiresUpdate(state.terminal)) {
+                if (self.images.kittyRequiresUpdate(render_terminal)) {
                     // We need to grab the draw mutex since this updates
                     // our image state that drawFrame uses.
                     self.draw_mutex.lockUncancelable(global.io());
                     defer self.draw_mutex.unlock(global.io());
                     self.images.kittyUpdate(
                         self.alloc,
-                        state.terminal,
+                        render_terminal,
                         .{
                             .width = self.grid_metrics.cell_width,
                             .height = self.grid_metrics.cell_height,
```

**Why it is needed:** Needed for image placement to match the text/pages being rendered.

**How it works:** Both the requires-update check and kittyUpdate use render_terminal.

#### Chunk 12: Invalidate and rebuild custom highlights

```diff
@@ -1519,8 +1536,9 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 log.warn("error searching for regex links err={}", .{err});
             };
 
+            self.snapshot_overrides.invalidate(&self.terminal_state);
             // Clear our highlight state and update.
-            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
+            if (self.search_matches_dirty or self.snapshot_overrides.highlights_dirty or self.terminal_state.dirty != .false) {
                 self.search_matches_dirty = false;
 
                 // Clear the prior highlights
```

**Why it is needed:** Needed when decoration layers change even if built-in search state has not changed.

**How it works:** Invalidates overrides against terminal_state and includes highlights_dirty in the highlight rebuild condition.

#### Chunk 13: Insert custom highlight layers

```diff
@@ -1543,6 +1561,8 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // NOTE: The order below matters. Highlights added earlier
                 // will take priority.
 
+                self.snapshot_overrides.updateHighlights(self.alloc, &self.terminal_state);
+
                 if (self.search_selected_match) |m| {
                     self.terminal_state.updateHighlightsFlattened(
                         self.alloc,
```

**Why it is needed:** Needed for Rust-owned selections and search ranges to appear through the existing highlight machinery.

**How it works:** Adds snapshot highlights before built-in search highlights, using the renderer's earlier-layer priority.

#### Chunk 14: Represent custom styles and text

```diff
@@ -2997,19 +3017,22 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 }
 
                 const wide = cell.wide;
+                const text_override = self.snapshot_overrides.textAt(@intCast(x), @intCast(y));
                 const style: terminal.Style = if (cell.hasStyling())
                     managed_style.*
                 else
                     .{};
 
                 // True if this cell is selected
-                const selected: enum {
+                const selected: union(enum) {
                     false,
                     selection,
                     search,
                     search_selected,
+                    decoration: @import("SnapshotDecorations.zig").Style,
                 } = selected: {
                     // Order below matters for precedence.
+                    if (text_override) |text| break :selected .{ .decoration = text.style };
 
                     // Selection should take the highest precedence.
                     const x_compare = if (wide == .spacer_tail)
```

**Why it is needed:** Needed to associate optional colors and quick-select labels with individual drawn cells.

**How it works:** Looks up a text override, makes selected a tagged union with a decoration payload, and gives replacement text style precedence.

#### Chunk 15: Resolve custom highlight tags

```diff
@@ -3028,11 +3051,16 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                         if (x_compare >= hl.range[0] and
                             x_compare <= hl.range[1])
                         {
-                            const tag: HighlightTag = @enumFromInt(hl.tag);
-                            break :selected switch (tag) {
-                                .search_match => .search,
-                                .search_match_selected => .search_selected,
-                            };
+                            if (hl.tag >= 2) {
+                                if (self.snapshot_overrides.styleForTag(hl.tag)) |decoration|
+                                    break :selected .{ .decoration = decoration };
+                            } else {
+                                const tag: HighlightTag = @enumFromInt(hl.tag);
+                                break :selected switch (tag) {
+                                    .search_match => .search,
+                                    .search_match_selected => .search_selected,
+                                };
+                            }
                         }
                     }
```

**Why it is needed:** Needed to distinguish decoration styles from the two existing search tags.

**How it works:** Tags at or above 2 resolve through styleForTag; lower tags retain the original search enum dispatch.

#### Chunk 16: Apply decoration background

```diff
@@ -3077,6 +3105,11 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                         .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                     },
 
+                    .decoration => |decoration| decoration.background orelse if (style.flags.inverse != isCovering(cell.codepoint()))
+                        fg_style
+                    else
+                        bg_style,
+
                     // Not selected
                     .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                         // Two cases cause us to invert (use the fg color as the bg)
```

**Why it is needed:** Needed to support an optional highlight background without discarding ordinary cell styling.

**How it works:** Uses the supplied background when present; otherwise keeps the existing inverse/covering-cell fallback.

#### Chunk 17: Apply decoration foreground

```diff
@@ -3121,6 +3154,11 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                             .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                         },
 
+                        .decoration => |decoration| decoration.foreground orelse if (style.flags.inverse)
+                            final_bg
+                        else
+                            fg_style,
+
                         .false => if (style.flags.inverse)
                             final_bg
                         else
```

**Why it is needed:** Needed to support an optional highlight foreground while retaining normal styling.

**How it works:** Uses the supplied foreground when present, otherwise follows inverse/background and normal foreground selection.

#### Chunk 18: Preserve opacity for foreground-only decoration

```diff
@@ -3143,7 +3181,12 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                         const default: u8 = 255;
 
                         // Cells that are selected should be fully opaque.
-                        if (selected != .false) break :bg_alpha default;
+                        const decorated_bg = switch (selected) {
+                            .false => false,
+                            .decoration => |decoration| decoration.background != null,
+                            else => true,
+                        };
+                        if (decorated_bg) break :bg_alpha default;
 
                         // Cells that are reversed should be fully opaque.
                         if (style.flags.inverse) break :bg_alpha default;
```

**Why it is needed:** Needed so a layer without a background does not make a transparent cell opaque.

**How it works:** Only a decoration with an explicit background forces full background opacity; ordinary selections retain their existing behavior.

#### Chunk 19: Show labels over invisible source cells

```diff
@@ -3177,7 +3220,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // emulators, e.g. Alacritty, still render text decorations
                 // and only make the text itself invisible. The decision
                 // has been made here to match xterm's behavior for this.
-                if (style.flags.invisible) {
+                if (style.flags.invisible and text_override == null) {
                     continue;
                 }
```

**Why it is needed:** Needed for replacement text to be visible even when the underlying terminal cell has invisible styling.

**How it works:** Skips invisible source cells only when there is no text override.

#### Chunk 20: Suppress source underline under a label

```diff
@@ -3200,7 +3243,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                 // We draw underlines first so that they layer underneath text.
                 // This improves readability when a colored underline is used
                 // which intersects parts of the text (descenders).
-                if (underline != .none) self.addUnderline(
+                if (underline != .none and text_override == null) self.addUnderline(
                     @intCast(x),
                     @intCast(y),
                     underline,
```

**Why it is needed:** Needed to keep source decoration from leaking into replacement glyphs.

**How it works:** Emits an underline only when text_override is null.

#### Chunk 21: Suppress source overline under a label

```diff
@@ -3213,7 +3256,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                     );
                 };
 
-                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
+                if (style.flags.overline and text_override == null) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                     log.warn(
                         "error adding overline to cell, will be invalid x={} y={}, err={}",
                         .{ x, y, err },
```

**Why it is needed:** Needed for replacement labels to have their own appearance.

**How it works:** Emits an overline only when no replacement text is present.

#### Chunk 22: Suppress the original glyph

```diff
@@ -3276,7 +3319,7 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                         run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                         shaper_cells_i += 1;
                     }) {
-                        self.addGlyph(
+                        if (text_override == null) self.addGlyph(
                             @intCast(x),
                             @intCast(y),
                             state.cols,
```

**Why it is needed:** Needed to avoid drawing both terminal text and a label in the same cell.

**How it works:** Still walks the shaped glyph run but only adds its glyphs when text_override is null.

#### Chunk 23: Draw replacement text and suppress source strikethrough

```diff
@@ -3294,8 +3337,10 @@ pub fn Renderer(comptime GraphicsAPI: type) type {
                     }
                 }
 
+                if (text_override) |text| try SnapshotOverrides.drawText(self, text, fg);
+
                 // Finally, draw a strikethrough if necessary.
-                if (style.flags.strikethrough) self.addStrikethrough(
+                if (style.flags.strikethrough and text_override == null) self.addStrikethrough(
                     @intCast(x),
                     @intCast(y),
                     fg,
```

**Why it is needed:** Needed to finish label rendering using Ghostty's font machinery.

**How it works:** Calls SnapshotOverrides.drawText for the override and adds the source strikethrough only without an override.

### src/renderer/message.zig

#### Chunk 1: Add an owned decoration update message

```diff
@@ -61,6 +61,9 @@ pub const Message = union(enum) {
     /// no match currently.
     search_selected_match: ?SearchMatch,
 
+    /// Atomically replace all presentation-only decoration layers.
+    snapshot_decorations: @import("SnapshotDecorations.zig"),
+
     /// Activate or deactivate the inspector.
     inspector: bool,
```

**Why it is needed:** Needed to transfer presentation styles/ranges/text through the existing renderer mailbox.

**How it works:** Adds snapshot_decorations with the payload type in a separate module; the receiver replaces the entire layer set.

### src/renderer/opengl/Frame.zig

#### Chunk 1: Complete direct native presentation

```diff
@@ -56,6 +56,7 @@ pub inline fn renderPass(
 /// pushing the newly presented and exported frame to the frame queue.
 pub fn complete(self: *const Self, sync: bool) void {
     _ = sync;
+    if (@import("HostContext.zig").completeFrame(self.renderer, self.target.*)) return;
 
     // If there are any GL errors, consider the frame unhealthy.
     const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;
```

**Why it is needed:** Needed to bypass exported-frame queue handling for a native Windows window.

**How it works:** HostContext.completeFrame consumes the direct path and returns true; other targets continue through existing frame health checks.

#### Chunk 2: Export frames through the renamed API

```diff
@@ -63,7 +64,7 @@ pub fn complete(self: *const Self, sync: bool) void {
     // If the frame is healthy, export it and push to the present queue.
     // The apprt pulls from this queue in its snapshot handler.
     if (health == .healthy) frame: {
-        const frame = self.renderer.api.present(self.target.*) catch |err| {
+        const frame = self.renderer.api.exportFrame(self.target.*) catch |err| {
             log.warn("failed to present render target: err={}", .{err});
             break :frame;
         };
```

**Why it is needed:** Needed to match the new split between direct presentation and host frame export.

**How it works:** Calls exportFrame; its result is still submitted through the existing completed-frame queue.

### src/terminal/PageList.zig

#### Chunk 1: Import the isolated map recorder

```diff
@@ -2,6 +2,7 @@
 //! and provides higher level operations on top of those pages to
 //! make it slightly easier to work with.
 const PageList = @This();
+const ReflowMap = @import("ReflowMap.zig");
 
 const std = @import("std");
 const builtin = @import("builtin");
```

**Why it is needed:** Needed to record translations without putting the map representation in upstream code.

**How it works:** Imports ReflowMap, which owns sorted segments and row offsets.

#### Chunk 2: Accept an optional resize recorder

```diff
@@ -1222,6 +1223,8 @@ pub fn clone(
 
 /// Resize options
 pub const Resize = struct {
+    /// Optional frozen-snapshot translation recorder; live resizes leave null.
+    reflow_map: ?*ReflowMap = null,
     /// The new cols/cells of the screen.
     cols: ?size.CellCountInt = null,
     rows: ?size.CellCountInt = null,
```

**Why it is needed:** Needed to enable map generation only for frozen snapshots.

**How it works:** Adds a nullable recorder to Resize; ordinary live resize callers retain null and allocate no map.

#### Chunk 3: Index each original source row during reflow

```diff
@@ -1478,13 +1481,25 @@ fn resizeCols(
     // Reflow all our rows.
     {
         var reflow_cursor: ReflowCursor = .init(first_rewritten_node);
+        var source_row: usize = 0;
         while (it.next()) |row| {
+            // Growing height before shrinking width can append source rows.
+            // They did not exist in the layout being translated.
+            const row_map = if (opts.reflow_map) |map|
+                if (source_row < map.row_offsets.len - 1) map else null
+            else
+                null;
+            if (row_map) |map| map.beginRow(source_row);
             try reflow_cursor.reflowRow(
                 self,
                 row,
                 if (preserved_cursor) |c| c.tracked_pin else null,
+                row_map,
             );
 
+            if (row_map) |map| map.endRow();
+            source_row += 1;
+
             // Once we're done reflowing a page, we're done with it, so
             // make it available for reuse (or destroy it). Making it
             // immediately available frees memory and makes it more
```

**Why it is needed:** Needed to group segments by old row and exclude rows appended during height growth.

**How it works:** Tracks source_row, brackets each original row with beginRow/endRow, and passes its recorder to reflowRow. New source rows beyond the old map size are reflowed normally without recording.

#### Chunk 4: Pass the recorder into cell movement

```diff
@@ -1656,6 +1671,7 @@ const ReflowCursor = struct {
         list: *PageList,
         row: Pin,
         cursor_pin: ?*Pin,
+        reflow_map: ?*ReflowMap,
     ) Allocator.Error!void {
         const src_page: *Page = row.node.page();
         const src_row = row.rowAndCell().row;
```

**Why it is needed:** Needed to observe Ghostty's actual wrapping instead of reimplementing wrapping in Rust.

**How it works:** Adds an optional parameter to reflowRow; existing tracked-pin behavior is unchanged.

#### Chunk 5: Record deferred blank rows

```diff
@@ -1720,6 +1736,7 @@ const ReflowCursor = struct {
         // Defer processing of blank rows so that blank rows
         // at the end of the page list are never written.
         if (cols_len == 0) {
+            if (reflow_map) |map| try map.record(0, self.total_rows - 1 + self.new_rows, 0, cells.len, 0);
             // If this blank row was a wrap continuation somehow
             // then we won't need to write it since it should be
             // a part of the previously written row.
```

**Why it is needed:** Needed to translate old blank cells even when upstream defers or drops their physical rows.

**How it works:** Records a constant-column segment at the pending destination row; finalization clamps dropped trailing rows into the retained screen.

#### Chunk 6: Record bulk-copied runs

```diff
@@ -1772,7 +1789,10 @@ const ReflowCursor = struct {
                 );
                 const window = cells[x..][0..max_run];
                 const run = bulkRunLength(window);
+                const destination_row = self.total_rows - 1;
+                const destination_column = self.x;
                 if (run > 0 and self.copyRun(window[0..run], src_page)) {
+                    if (reflow_map) |map| try map.record(x, destination_row, destination_column, run, 1);
                     x += run;
                     continue;
                 }
```

**Why it is needed:** Needed to preserve the fast copy path while producing a compact map.

**How it works:** Captures the absolute destination row/column before copyRun and records the successful run as step-one contiguous cells.

#### Chunk 7: Record slow-path cells and skipped spacers

```diff
@@ -1792,17 +1812,23 @@ const ReflowCursor = struct {
                 }
             }
 
+            const destination_row = self.total_rows - 1;
+            const destination_column = self.x;
             if (self.writeCell(
                 list,
                 &cells[x],
                 src_page,
             )) |result| switch (result) {
                 // Wrote the cell, move to the next.
-                .success => x += 1,
+                .success => {
+                    if (reflow_map) |map| try map.record(x, destination_row, destination_column, 1, 1);
+                    x += 1;
+                },
 
                 // Wrote the cell but request to skip the next so skip it.
                 // This is used for things like spacers.
                 .skip_next => {
+                    if (reflow_map) |map| try map.record(x, destination_row, destination_column, @min(2, cells.len - x), 0);
                     // Remap any tracked pins at the skipped position (x+1)
                     // since we won't process that cell in the loop.
                     if (row_has_pins) for (list.tracked_pins.keys()) |p| {
```

**Why it is needed:** Needed for graphemes, wide-cell padding, and other cells outside bulk copying.

**How it works:** Records only successful writes, maps skipped source pairs as constant-column segments, and emits nothing for repeat until the wide character is actually placed. Absolute row coordinates survive destination page moves.

#### Chunk 8: Record upstream fallback cell consumption

```diff
@@ -1833,6 +1859,7 @@ const ReflowCursor = struct {
                     // any further, so we just ignore bad cells and take
                     // corrupted (but valid) cell contents.
                     log.warn("reflowRow OutOfSpace on first row, discarding cell managed memory", .{});
+                    if (reflow_map) |map| try map.record(x, destination_row, destination_column, 1, 1);
                     x += 1;
                     self.cursorForward();
                 } else {
```

**Why it is needed:** Needed so the map still covers source cells consumed by the existing first-row OutOfSpace fallback.

**How it works:** Records the destination when upstream discards managed cell data and advances. It does not change that fallback policy.

#### Chunk 9: Map trimmed right-side padding

```diff
@@ -1845,6 +1872,12 @@ const ReflowCursor = struct {
             }
         }
 
+        if (reflow_map) |map| {
+            const last = map.segments.items[map.segments.items.len - 1];
+            const last_column = last.new_column + (last.count - 1) * last.step;
+            try map.record(x, last.new_row, last_column, cells.len - x, 0);
+        }
+
         // If the source row isn't wrapped then we should scroll afterwards.
         if (!src_row.wrap) {
             self.new_rows += 1;
```

**Why it is needed:** Needed for selections and anchors whose old columns lay beyond meaningful text.

**How it works:** Maps the remaining old columns onto the last emitted destination cell with step zero, rather than adding tracked pins that force extra padding to be retained.

### src/terminal/Screen.zig

#### Chunk 1: Expose the optional recorder on screen resize

```diff
@@ -1998,6 +1998,7 @@ pub inline fn blankCell(self: *const Screen) Cell {
 }
 
 pub const Resize = struct {
+    reflow_map: ?*@import("ReflowMap.zig") = null,
     /// The new size to resize to
     cols: size.CellCountInt,
     rows: size.CellCountInt,
```

**Why it is needed:** Needed for SnapshotReflow to request a map through Screen's existing resize entry point.

**How it works:** Adds a nullable ReflowMap pointer with a null default, leaving live callers unchanged.

#### Chunk 2: Forward the recorder to page reflow

```diff
@@ -2115,6 +2116,7 @@ pub inline fn resize(
             .pin = self.cursor.page_pin,
         },
         .pull_scrollback = opts.pull_scrollback,
+        .reflow_map = opts.reflow_map,
     });
 
     // No more failures are possible after this. Enforced by compiler
```

**Why it is needed:** Needed because actual row/cell movement occurs inside PageList.

**How it works:** Passes the optional pointer through with the existing cursor and scrollback options; Screen continues owning cursor/style/image resize coordination.

### src/terminal/Terminal.zig

#### Chunk 1: Include extracted resize regressions

```diff
@@ -16539,3 +16539,7 @@ test "Terminal: eraseDisplay complete ignores stale prompt on recycled row" {
 
     try testing.expectEqual(t.screens.active.pages.rows, t.screens.active.pages.total_rows);
 }
+
+test {
+    _ = @import("host_regression_tests.zig");
+}
```

**Why it is needed:** Needed to keep the prompt/history resize test in the terminal test graph.

**How it works:** A test-only import references host_regression_tests; runtime Terminal implementation is unchanged.

### src/terminal/highlight.zig

#### Chunk 1: Remove the wrong chunk alias

```diff
@@ -13,7 +13,6 @@ const std = @import("std");
 const Allocator = std.mem.Allocator;
 const size = @import("size.zig");
 const PageList = @import("PageList.zig");
-const PageChunk = PageList.PageIterator.Chunk;
 const Pin = PageList.Pin;
 const Screen = @import("Screen.zig");
```

**Why it is needed:** Needed because Flattened stores its own Chunk type, not the PageIterator chunk structure.

**How it works:** Deletes the PageChunk alias after changing the constructor below.

#### Chunk 2: Use the flattened chunk type

```diff
@@ -143,7 +142,7 @@ pub const Flattened = struct {
         start: Pin,
         end: Pin,
     ) Allocator.Error!Flattened {
-        var result: std.MultiArrayList(PageChunk) = .empty;
+        var result: std.MultiArrayList(Chunk) = .empty;
         errdefer result.deinit(alloc);
         var it = start.pageIterator(.right_down, end);
         while (it.next()) |chunk| try result.append(alloc, .{
```

**Why it is needed:** Needed for the constructor's result list to match Flattened.chunks.

**How it works:** Allocates MultiArrayList(Chunk), whose entries describe highlight page spans.

#### Chunk 3: Initialize the correct bottom-column field

```diff
@@ -155,7 +154,7 @@ pub const Flattened = struct {
         return .{
             .chunks = result,
             .top_x = start.x,
-            .end_x = end.x,
+            .bot_x = end.x,
         };
     }
```

**Why it is needed:** Needed because Flattened declares bot_x rather than end_x.

**How it works:** Stores end.x in bot_x, preserving the final selected column when flattening a range.

### src/terminal/main.zig

#### Chunk 1: Expose snapshot modules through the terminal package

```diff
@@ -55,6 +55,10 @@ pub const Selection = @import("Selection.zig");
 pub const SelectionGesture = @import("SelectionGesture.zig");
 pub const SizeReportStyle = csi.SizeReportStyle;
 pub const StringMap = @import("StringMap.zig");
+pub const SnapshotTextCursor = @import("SnapshotTextCursor.zig");
+pub const PresentationSnapshot = @import("PresentationSnapshot.zig");
+pub const SnapshotReflow = @import("SnapshotReflow.zig");
+pub const SnapshotStyleRuns = @import("SnapshotStyleRuns.zig");
+pub const SnapshotLogicalPosition = @import("SnapshotLogicalPosition.zig");
 pub const Style = style.Style;
 pub const Terminal = @import("Terminal.zig");
 pub const TerminalStream = stream_terminal.Stream;
```

**Why it is needed:** Needed for embedding callers to use capture, text iteration, resize translation, and style-run export.

**How it works:** Adds package-level aliases to the four standalone implementations rather than moving logic into this upstream file.

### src/termio/Exec.zig

#### Chunk 1: Keep ConPTY active-screen alignment on growth

```diff
@@ -65,6 +65,13 @@ pub fn deinit(self: *Exec) void {
 /// after termio begins because it may put the internal terminal state
 /// into a bad state.
 pub fn initTerminal(self: *Exec, term: *terminal.Terminal) void {
+    // ConPTY maintains only the active screen, without our scrollback.
+    // Keep its viewport contents and cursor coordinates aligned when growing
+    // the grid: add blank rows below instead of pulling history into view.
+    if (comptime builtin.os.tag == .windows) {
+        term.flags.resize_pull_scrollback = false;
+    }
+
     // If we have an initial pwd requested by the subprocess, then we
     // set that on the terminal now. This allows rapidly initializing
     // new surfaces to use the proper pwd.
```

**Why it is needed:** Needed because ConPTY does not share Ghostty scrollback and pulling history into view shifts the active screen/cursor.

**How it works:** Sets resize_pull_scrollback=false during Windows terminal initialization.

#### Chunk 2: Close setup handles correctly on failure

```diff
@@ -123,8 +130,8 @@ pub fn threadEnter(
     // Create our pipe that we'll use to kill our read thread.
     // pipe[0] is the read end, pipe[1] is the write end.
     const pipe = try internal_os.pipe();
-    errdefer _ = posix.system.close(pipe[0]);
-    errdefer _ = posix.system.close(pipe[1]);
+    errdefer compat_fd.close(pipe[0]);
+    errdefer compat_fd.close(pipe[1]);
 
     // Setup our stream so that we can write.
     var stream = xev.Stream.initFd(pty_fds.write);
```

**Why it is needed:** Needed for Windows HANDLE cleanup rather than POSIX close semantics.

**How it works:** Uses compat_fd.close for both quit-pipe ends in errdefer.

#### Chunk 3: Signal Windows reader shutdown

```diff
@@ -203,7 +210,9 @@ pub fn threadExit(self: *Exec, td: *termio.Termio.ThreadData) void {
     // Quit our read thread after exiting the subprocess so that
     // we don't get stuck waiting for data to stop flowing if it is
     // a particularly noisy process.
-    switch (posix.errno(posix.system.write(exec.read_thread_pipe, "x", 1))) {
+    if (comptime builtin.os.tag == .windows) {
+        @import("host_process.zig").signalQuit(exec.read_thread_pipe);
+    } else switch (posix.errno(posix.system.write(exec.read_thread_pipe, "x", 1))) {
         .SUCCESS => {},
 
         // EPIPE means that our read thread is closed already, which is
```

**Why it is needed:** Needed to unblock the read thread when the subprocess exits.

**How it works:** Delegates Windows writes to host_process.signalQuit; other targets retain the POSIX write/errno handling.

#### Chunk 4: Close the retained shutdown handle

```diff
@@ -547,7 +556,7 @@ pub const ThreadData = struct {
     termios_mode: ptypkg.Mode = .{},
 
     pub fn deinit(self: *ThreadData, alloc: Allocator) void {
-        _ = posix.system.close(self.read_thread_pipe);
+        compat_fd.close(self.read_thread_pipe);
 
         // Clear our write pool. We know we aren't ever going to do
         // any more IO since we stop our data stream below so we can just
```

**Why it is needed:** Needed for the same cross-platform HANDLE lifecycle during ThreadData cleanup.

**How it works:** Replaces direct POSIX close with compat_fd.close.

#### Chunk 5: Store original process identity

```diff
@@ -591,6 +600,8 @@ const Subprocess = struct {
     screen_size: renderer.ScreenSize,
     pty: ?Pty = null,
     process: ?Process = null,
+    original_pid: std.atomic.Value(u64) = .init(0),
+    original_created: std.atomic.Value(u64) = .init(0),
 
     rt_pre_exec_info: Command.RtPreExecInfo,
     rt_post_fork_info: Command.RtPostForkInfo,
```

**Why it is needed:** Needed for host process integration independent of changing foreground ownership.

**How it works:** Adds atomic PID and creation-time fields initialized to zero, the unavailable sentinel.

#### Chunk 6: Provide an MSYS TERMINFO path

```diff
@@ -650,7 +661,12 @@ const Subprocess = struct {
             const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
                 std.fs.path.dirname(base) orelse unreachable,
             });
-            try env.put("TERMINFO", dir);
+            // Git/MSYS ncurses expects an MSYS path in TERMINFO rather than
+            // a native C:/... path, even though tic accepts the latter.
+            try env.put("TERMINFO", if (comptime builtin.os.tag == .windows)
+                try @import("host_process.zig").msysTerminfoPath(alloc, dir)
+            else
+                dir);
         } else {
             if (comptime builtin.target.os.tag.isDarwin()) {
                 log.warn("ghostty terminfo not found, using xterm-256color", .{});
```

**Why it is needed:** Needed because Git/MSYS ncurses expects /drive/... rather than a native drive path.

**How it works:** Converts the bundled directory only on Windows; other platforms retain the original directory string.

#### Chunk 7: Capture identity at process launch

```diff
@@ -1076,6 +1092,11 @@ const Subprocess = struct {
         log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });
 
         self.process = .{ .fork_exec = cmd };
+        if (cmd.pid) |pid| {
+            const identity = @import("host_process.zig").identity(pid);
+            self.original_created.store(identity.created, .release);
+            self.original_pid.store(identity.pid, .release);
+        }
         return switch (builtin.os.tag) {
             .windows => .{
                 .read = pty.out_pipe,
```

**Why it is needed:** Needed to retain the process actually started for this terminal and distinguish PID reuse.

**How it works:** Reads identity from the spawned process handle/PID and stores creation time then PID with release ordering.

#### Chunk 8: Return cached shell identity

```diff
@@ -1256,6 +1277,14 @@ const Subprocess = struct {
     /// Returns `null` if there was an error getting the information or the
     /// information is not available on a particular platform.
     pub fn getProcessInfo(self: *Subprocess, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
+        if (info == .shell_pid) {
+            const pid = self.original_pid.load(.acquire);
+            return if (pid == 0) null else pid;
+        }
+        if (info == .shell_creation_time) {
+            const created = self.original_created.load(.acquire);
+            return if (created == 0) null else created;
+        }
         const pty = &(self.pty orelse return null);
         return pty.getProcessInfo(info);
     }
```

**Why it is needed:** Needed because the PTY itself cannot answer original-process requests.

**How it works:** getProcessInfo checks the added variants first and loads cached values with acquire ordering, returning null for zero.

#### Chunk 9: Exclude POSIX idle descriptors on Windows

```diff
@@ -1392,8 +1421,10 @@ pub const ReadThread = struct {
         /// write end is used by the parse stage, the read end is
         /// polled by the gather stage. -1 when unavailable, in which
         /// case bridge polls are bounded by their timeout only.
-        idle_read_fd: posix.fd_t = -1,
-        idle_write_fd: posix.fd_t = -1,
+        idle_read_fd: if (builtin.os.tag == .windows) void else posix.fd_t =
+            if (builtin.os.tag == .windows) {} else -1,
+        idle_write_fd: if (builtin.os.tag == .windows) void else posix.fd_t =
+            if (builtin.os.tag == .windows) {} else -1,
 
         /// Set by the gather stage when the stream is over (quit
         /// signal, EOF, or pty error). The parse stage drains any
```

**Why it is needed:** Needed because fd_t is a HANDLE on Windows and -1 is not the appropriate field initialization.

**How it works:** Uses compile-time void fields on Windows; POSIX retains descriptors with -1 sentinels.

#### Chunk 10: Close the POSIX reader's quit descriptor through compat

```diff
@@ -1406,7 +1437,7 @@ pub const ReadThread = struct {
 
     fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
         // Always close our end of the pipe when we exit.
-        defer _ = posix.system.close(quit);
+        defer compat_fd.close(quit);
 
         // Right now, on Darwin, `std.Thread.setName` can only name the current
         // thread, and we have no way to get the current thread from within it,
```

**Why it is needed:** Needed to make teardown consistently use the platform-aware helper.

**How it works:** The deferred close delegates to compat_fd.close; on POSIX its behavior remains the normal close path.

#### Chunk 11: Close the Windows reader's quit handle

```diff
@@ -1772,7 +1803,7 @@ pub const ReadThread = struct {
 
     fn threadMainWindows(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
         // Always close our end of the pipe when we exit.
-        defer _ = posix.system.close(quit);
+        defer compat_fd.close(quit);
 
         // Setup our crash metadata
         crash.sentry.thread_state = .{
```

**Why it is needed:** Needed to release the Windows quit handle correctly.

**How it works:** Replaces the deferred POSIX system call with compat_fd.close.

#### Chunk 12: Include helper tests

```diff
@@ -2303,3 +2334,7 @@ test "execCommand windows: direct command is passed through unchanged" {
     try testing.expectEqualStrings("C:\\tools\\foo.exe", result[0]);
     try testing.expectEqualStrings("arg with spaces", result[1]);
 }
+
+test {
+    _ = @import("host_process.zig");
+}
```

**Why it is needed:** Needed to run the MSYS path conversion regression without leaving its body inline in Exec.

**How it works:** Adds a test-only import of host_process.

### src/termio/Options.zig

#### Chunk 1: Borrow the shared wakeup object

```diff
@@ -32,7 +32,10 @@ renderer_state: *renderer.State,
 
 /// A handle to wake up the renderer. This hints to the renderer that
 /// a repaint should happen.
-renderer_wakeup: xev.Async,
+/// Borrowed from the surface's stable renderer thread storage. On IOCP,
+/// Async contains the waiter itself and must not be copied after sharing.
+/// The owner must keep it alive until the IO threads have stopped.
+renderer_wakeup: *xev.Async,
 
 /// The mailbox for renderer messages.
 renderer_mailbox: *renderer.Thread.Mailbox,
```

**Why it is needed:** Needed because IOCP Async embeds the waiter and cannot safely be copied once shared.

**How it works:** Changes the option to *xev.Async and documents that its owner must keep it alive until IO stops.

### src/termio/Termio.zig

#### Chunk 1: Carry the borrowed wakeup pointer

```diff
@@ -47,7 +47,7 @@ renderer_state: *renderer.State,
 
 /// A handle to wake up the renderer. This hints to the renderer that
 /// a repaint should happen.
-renderer_wakeup: xev.Async,
+renderer_wakeup: *xev.Async,
 
 /// The mailbox for notifying the renderer of things.
 renderer_mailbox: *renderer.Thread.Mailbox,
```

**Why it is needed:** Needed to preserve the same renderer waiter from options through Termio.

**How it works:** Changes the stored field from a value to a pointer; notify calls continue using that shared object.

#### Chunk 2: Remove output-based cursor reset state

```diff
@@ -65,10 +65,6 @@ mailbox: termio.Mailbox,
 /// from the child process and calls callbacks in the stream handler.
 terminal_stream: StreamHandler.Stream,
 
-/// Last time the cursor was reset. This is used to prevent message
-/// flooding with cursor resets.
-last_cursor_reset: ?std.Io.Timestamp = null,
-
 /// State we have for thread enter. This may be null if we don't need
 /// to keep track of any state or if its already been freed.
 thread_enter_state: ?*ThreadEnterState = null,
```

**Why it is needed:** Needed because typing now drives blink reset in Surface.keyCallback.

**How it works:** Deletes the timestamp used to throttle the old output-driven reset path.

#### Chunk 3: Notify ConPTY after reflow

```diff
@@ -501,8 +497,12 @@ pub fn resize(
     self.size = size;
     const grid_size = size.grid();
 
-    // Update the size of our pty.
-    try self.backend.resize(grid_size, size.terminal());
+    // Windows ConPTY may query the cursor as a consequence of resizing.
+    // Its reader runs independently, so finish reflow before notifying it.
+    // Keep the existing PTY notification order on other platforms.
+    if (comptime @import("builtin").os.tag != .windows) {
+        try self.backend.resize(grid_size, size.terminal());
+    }
 
     // Enter the critical area that we want to keep small
     {
```

**Why it is needed:** Needed because ConPTY can provoke cursor queries during resize and must see Ghostty's new dimensions.

**How it works:** Keeps backend-first ordering on non-Windows; defers the Windows backend call until the terminal reflow completes.

#### Chunk 4: Release the lock before ConPTY notification and report afterward

```diff
@@ -522,7 +522,20 @@ pub fn resize(
             },
         );
 
-        // If we have size reporting enabled we need to send a report.
+        @import("resize_diagnostics.zig").reflow(log, &self.terminal, grid_size);
+    }
+
+    // Do not hold the terminal lock across the backend call: output parsing
+    // must remain able to make progress while ConPTY handles its signal pipe.
+    if (comptime @import("builtin").os.tag == .windows) {
+        try self.backend.resize(grid_size, size.terminal());
+        @import("resize_diagnostics.zig").notified(log, grid_size);
+    }
+
+    // Report only after both the terminal and backend have been resized.
+    {
+        self.renderer_state.mutex.lockUncancelable(global.io());
+        defer self.renderer_state.mutex.unlock(global.io());
         if (self.terminal.modes.get(.in_band_size_reports)) {
             try self.sizeReportLocked(td, .mode_2048);
         }
```

**Why it is needed:** Needed to let output parsing progress during the backend call and to report a consistent completed resize.

**How it works:** Logs reflow, leaves the terminal lock, resizes Windows backend, then reacquires the lock for in-band size reporting. Diagnostic calls are optional; ordering/lock boundaries are behavioral.

#### Chunk 5: Scroll the displayed viewport

```diff
@@ -634,7 +647,7 @@ pub fn scrollViewport(
 ) void {
     self.renderer_state.mutex.lockUncancelable(global.io());
     defer self.renderer_state.mutex.unlock(global.io());
-    self.terminal.scrollViewport(scroll);
+    self.renderer_state.terminalForRender().scrollViewport(scroll);
 }
 
 /// Jump the viewport to the prompt.
```

**Why it is needed:** Needed so modal scroll requests do not move live history underneath the snapshot.

**How it works:** Under the existing mutex, scrollViewport delegates to terminalForRender.

#### Chunk 6: Jump to prompts in the displayed terminal

```diff
@@ -642,7 +655,7 @@ pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
     {
         self.renderer_state.mutex.lockUncancelable(global.io());
         defer self.renderer_state.mutex.unlock(global.io());
-        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
+        self.renderer_state.terminalForRender().screens.active.scroll(.{ .delta_prompt = delta });
     }
 
     try self.renderer_wakeup.notify();
```

**Why it is needed:** Needed for prompt navigation to match the visible frozen contents.

**How it works:** Uses terminalForRender's screen for the delta_prompt scroll, then wakes the renderer as before.

#### Chunk 7: Stop resetting cursor blink on output

```diff
@@ -685,24 +698,6 @@ fn processOutputLocked(self: *Termio, buf: []const u8) void {
     // Schedule a render. We can call this first because we have the lock.
     self.terminal_stream.handler.queueRender() catch unreachable;
 
-    // Whenever a character is typed, we ensure the cursor is in the
-    // non-blink state so it is rendered if visible. If we're under
-    // HEAVY read load, we don't want to send a ton of these so we
-    // use a timer under the covers
-    const now = std.Io.Timestamp.now(global.io(), .awake);
-    cursor_reset: {
-        if (self.last_cursor_reset) |last| {
-            if (last.durationTo(now).toMilliseconds() <= 500) {
-                break :cursor_reset;
-            }
-        }
-
-        self.last_cursor_reset = now;
-        _ = self.renderer_mailbox.push(global.io(), .{
-            .reset_cursor_blink = {},
-        }, .{ .instant = {} });
-    }
-
     // If we have an inspector, we enter SLOW MODE because we need to
     // process a byte at a time alternating between the inspector handler
     // and the termio handler. This is very slow compared to our optimizations
```

**Why it is needed:** Needed to avoid continuous output holding the cursor in the visible/non-blink phase.

**How it works:** Removes the timed mailbox reset block; output still queues rendering. Surface handles non-modifier typing resets instead.

### src/termio/stream_handler.zig

#### Chunk 1: Carry the same shared wakeup

```diff
@@ -39,7 +39,7 @@ pub const StreamHandler = struct {
 
     /// A handle to wake up the renderer. This hints to the renderer that
     /// a repaint should happen.
-    renderer_wakeup: xev.Async,
+    renderer_wakeup: *xev.Async,
 
     /// The response to use for ENQ requests. The memory is owned by
     /// whoever owns StreamHandler.
```

**Why it is needed:** Needed to keep the parser's render notification tied to the stable IOCP waiter.

**How it works:** Stores *xev.Async instead of a copied value.

#### Chunk 2: Record cursor-report diagnostics

```diff
@@ -841,6 +841,8 @@ pub const StreamHandler = struct {
                 });
                 msg.write_small.len = @intCast(resp.len);
 
+                @import("resize_diagnostics.zig").cursor(log, self.terminal, pos);
+
                 self.messageWriter(msg);
             },
```

**Why it is needed:** Useful when diagnosing resize ordering and cursor alignment, but not required for correctness.

**How it works:** Calls the separate coordinate logger before sending the existing cursor response; the helper is disabled in tests and unless stderr logging is enabled.

## Part II: files added relative to hashi/main

Public declarations include Zig API/types as well as C exports. Each entry explains
the callers, purpose, and ownership/lifetime of the provided operations.

### src/apprt/embedded_host.zig

**Public API / types:** `ghostty_surface_take_gl_frame`, `ghostty_gl_frame_release`, `ghostty_surface_read_font`, `ghostty_font_data_free`, `ghostty_surface_live_cursor_position`, `ghostty_surface_live_cursor_line`, `ghostty_surface_live_cursor_line_free`, `ghostty_surface_shell_pid`, `ghostty_surface_shell_creation_time`, `ghostty_surface_key_usb`, `screenPointSpansScrollback`.

- **take_gl_frame/gl_frame_release:** obtain a texture frame lease and release it
  after composition. Needed to expose GPU output with explicit ownership.
- **read_font/font_data_free:** provide configured font bytes/metadata for host UI
  rendering and cleanup. Needed for preview/UI typography to use terminal fonts.
- **live_cursor_position/live_cursor_line/free:** read live cursor coordinates and
  its logical-line text/mapping. Needed for host features that inspect live input
  independently of modal snapshot presentation.
- **shell_pid/shell_creation_time:** expose original process identity for host-side
  process integration, including protection against confusing a reused PID.
- **key_usb:** convert native USB key/modifier/text information into App.KeyEvent,
  including consumed Shift, then call the existing app key handler. Needed to use
  translated punctuation correctly without relying on a platform keymap conversion.
- **screenPointSpansScrollback:** test helper for the upstream Point.pin fix.

Keeping these exports here avoids a growing implementation block in embedded.zig.

### src/apprt/embedded_snapshot.zig

**Public API / types:** `ghostty_surface_snapshot_style_runs`, `ghostty_snapshot_style_runs_free`, `ghostty_surface_snapshot_resize`, `ghostty_snapshot_reflow_map_free`, `ghostty_surface_snapshot_view`, `ghostty_surface_snapshot_resolve_cell`, `ghostty_surface_snapshot_selection_text`, `ghostty_surface_snapshot_selection_text_free`, `ghostty_surface_snapshot_apply_decorations`, `ghostty_surface_snapshot_decorations_need_refresh`, `ghostty_surface_snapshot_text_cursor_new`, `ghostty_surface_snapshot_text_cursor_free`, `ghostty_surface_snapshot_text_cursor_reset`, `ghostty_surface_snapshot_text_cursor_next`, `ghostty_surface_snapshot_text_row`, `ghostty_surface_snapshot_text_row_free`, `ghostty_surface_snapshot_begin`, `ghostty_surface_snapshot_end`.

This standalone file contains the custom snapshot types and exports previously
added inline to embedded.zig. Its responsibilities are:

- **begin/end:** enter and leave modal capture and expose the generation.
- **resize:** validate generation, serialize access, clear old layout decorations
  and row caches, reflow the frozen terminal, and return an owned indexed translation map.
- **view:** return cursor, viewport, total rows, and column count for Rust navigation.
- **resolve_cell:** normalize requested cells, including wide-cell boundaries.
- **selection_text/free:** use Ghostty selection formatting and define ownership
  of returned character, line, or rectangular selection text.
- **apply_decorations:** validate and flatten visible ranges, optionally reveal a
  target with padding, and publish styled ranges and replacement text to rendering.
- **decorations_need_refresh:** detect viewport changes that require Rust to
  regenerate viewport-relative decoration data.
- **text_cursor_new/reset/next/free:** expose the sequential history reader with
  generation checks and explicit ownership.
- **text_row/free:** provide individual row text, mapping, and wrap information;
  cache a nearby row anchor to make successive row reads cheaper.
- **style_runs/free:** export resolved column-style runs once during source loading
  and release their allocation. The helper lives in SnapshotStyleRuns.zig.
  Rust stores text/style runs and handles wrapping, preview painting, and copy.
- **logical_position:** capture a windowed document's logical line and UTF-8
  origin once. The frozen content retains that origin across width changes.
- **resolve_logical_range:** map logical endpoints to current cells on accept
  or split actions. The helper scans row boundaries once and formats target
  logical lines only, without retaining per-candidate maps.


Needed to bridge Rust's modal controllers to Ghostty's cells and renderer without
placing all those exports inside upstream embedded.zig. Locking, generation
validation, allocation cleanup, and custom error reporting belong at this boundary.
Rust translates retained cells locally and frees the map on drop. The added
map-free export owns both arrays independently of terminal lifetime. Associated
helper tests remain beside the implementation.

### src/apprt/snapshot_viewport.zig

**Public API / types:** `revealTop`.

`revealTop()` calculates a viewport top that keeps a target row visible with
requested padding, clamped to the available history and short-window height.
Needed by snapshot decoration application when copy/search navigation reveals a
match. Pure tests cover edges, short windows, and zero padding.

### src/build/HostLibrary.zig

**Public API / types:** `add`.

Defines host-lib, which installs the embedding library (plus its Windows import
library), the static VT library, and resources for external hosts such as nterm,
which builds its Rust host with cargo against this install. On Windows it
invokes dist/windows/conpty.ps1 for the pinned architecture-specific ConPTY
runtime and adds the conpty target. The non-Windows path installs a public
libghostty.so.

### src/build/WindowsResources.zig

**Public API / types:** `compileTerminfo`.

`compileTerminfo()` finds tic through an explicit terminfo-compiler option or
Git/MSYS installation paths, compiles extended capabilities, and installs the
database under share/terminfo. Needed for ncurses programs to recognize Ghostty's
TERM on Windows instead of having only a terminfo source file.

### src/c_api_error.zig

**Public API / types:** `clear`, `set`, `get`.

Provides thread-local clear/set/get with an error name and a reset regression test.
Needed by our custom initialization and host APIs to return a useful cause in
addition to bool/null results. It is not a collector for every upstream error.

### src/c_api_host.zig

**Public API / types:** `ghostty_last_init_error`, `ghostty_last_error`, `ghostty_clear_error`, `windowsCommandLineFromUtf8Args`, `ghostty_init_utf8`, `init`.

Exports last_init_error, last_error, clear_error, and init_utf8. `init()` performs
environment/global initialization and reports failures. Windows argument conversion
quotes host-provided UTF-8 arguments using CRT backslash rules and creates the
UTF-16 command line consumed by Zig's Windows argument iterator.

Needed to accept Rust's own argument vector without losing Unicode characters or
argument boundaries. The ordinary ghostty_init export delegates here too. Argument
storage is retained for global parsing lifetime.

### src/config/c_api_host.zig

**Public API / types:** `ghostty_config_set_theme`, `ghostty_config_set_font`, `ghostty_config_theme_directories`.

`ghostty_config_set_theme` removes replayed terminal color overrides and appends the
selected theme. `ghostty_config_set_font` validates and appends family/size settings.
Replay insertion stays before the `-e` command tail so shell arguments remain intact.
`ghostty_config_theme_directories` enumerates the same prioritized search locations
as Ghostty's theme loader. Tests cover theme switching and font replay.

Needed to update host theme/font settings through Ghostty's existing config parser
and to populate pickers without duplicating theme discovery rules in Rust.

### src/config/c_get_host.zig

**Public API / types:** `extra`, `terminalColor`.

`extra()` returns the selected light/dark theme name as a pointer/length pair.
`terminalColor()` exposes literal RGB values; symbolic cell foreground/background
values return false because they are not fixed RGB colors. Tests cover those cases.

Needed for host theme identification and configured UI/highlight colors. The generic
TerminalColor conversion also applies to cursor/search colors, not only selections.

### src/input/host_key_tests.zig

**Public API / types:** `consumedShift`.

`consumedShift()` exercises kitty key encoding for already translated punctuation.
Needed to guard against applying Shift a second time to host-supplied text. It accepts
the upstream private encoder as a comptime function rather than exposing that function.

### src/os/ConPty.zig

**Public API / types:** `load`, `deinit`.

Loads the application-local ConPTY API when available and retains the system API
as fallback. Resolves create/resize/close operations and owns the DLL reference.
Needed to use the pinned ConPTY runtime installed with the host rather than relying
only on the operating system's version. It frees the module on teardown/failure.

### src/renderer/SnapshotDecorations.zig

**Public API / types:** `Style`, `Layer`, `Text`.

Defines optional foreground/background styles, layered flattened ranges, replacement
text cells, and the owning arena. Needed to send one owned decoration update across
threads without changing terminal text or borrowing Rust's temporary buffers.

### src/renderer/SnapshotOverrides.zig

**Public API / types:** `deinit`, `replace`, `invalidate`, `updateHighlights`, `styleForTag`, `textAt`, `drawText`.

Owns/replaces decoration arenas, invalidates highlights when terminal state changes,
adds flattened highlights, resolves custom highlight tags, looks up replacement
text, and draws that text through the renderer's existing glyph facilities.

Needed for copy selections, search highlights, yank flashes, and quick-select
labels without modifying captured terminal cells. Separating this implementation
reduces inline changes, although renderer calls into it must remain.

### src/renderer/opengl/HostContext.zig

**Public API / types:** `ExternalContext`, `externalContext`, `create`, `destroy`, `enter`, `leave`, `present`, `completeFrame`.

Discovers external surface context fields, creates/destroys WGL contexts, binds and
unbinds contexts on the render thread, applies vsync, and presents native targets.
`completeFrame()` handles direct Windows presentation, completion synchronization,
and health reporting. Needed to isolate platform implementation while preserving
Ghostty's renderer lifecycle. It also relies on the accompanying wgl.c support.

### src/renderer/opengl/OutputPool.zig

**Public API / types:** `TextureFrame`, `deinit`, `create`, `destroy`, `deinitResources`, `exportFrame`.

Owns three framebuffer/texture slots with atomic free/writing/leased states.
`exportFrame()` copies a completed target into an available slot and returns its
texture, dimensions, and generation. Releasing TextureFrame makes that slot reusable.

Needed to prevent the renderer overwriting a texture while the host is composing
it. Resources are released on the render thread while its GL context is available.
This adds GPU frame storage, separate from terminal snapshot memory.

### src/surface/Snapshot.zig

**Public API / types:** `Viewport`, `begin`, `end`, `scroll`.

`capture`, `begin`, `end`, and `scroll` implement the lifecycle extracted from
Surface.zig. Capture and terminal selection are protected by the renderer-state
mutex. Repeated begin calls retain the existing snapshot. A nonzero generation
identifies the capture and rejects requests from previous modal sessions.

The module owns the frozen terminal, decoration viewport cache, and sequential
row-read anchor. End detaches the renderer, dirties the live terminal, clears
presentation decorations, frees the snapshot, and requests a frame. These steps
are needed to restore live presentation and avoid using old snapshot coordinates.

### src/terminal/PresentationSnapshot.zig

**Public API / types:** `capture`.

`capture()` encodes and decodes the terminal with Ghostty's existing snapshot
codec. It restores viewport and derived semantic-prompt state that the codec does
not carry, hides the terminal cursor, and marks the result dirty.

Needed to freeze history, text, styles, and terminal state without sharing mutable
pages with the live process. Reusing the codec avoids maintaining a separate deep
copy implementation. Tests cover independent contents, history/viewport retention,
and allocation-failure cleanup. The serialized buffer is temporary, not retained
as a second pane document.

### src/terminal/ReflowMap.zig

**Public API / types:** `Cell`, `Segment`, `init`, `deinit`, `beginRow`, `record`, `endRow`, `finish`, `translate`.

`init` owns the old-row offset array and segment builder. PageList calls beginRow,
record, and endRow while moving cells; record merges compatible adjacent runs.
finish fills height-trimmed rows and clamps deferred trailing blanks. Segments
are sorted by source row/column and are 32 bytes each; step 1 represents a
contiguous run, step 0 collapsed blanks/padding. translate indexes row_offsets
and binary-searches that row's segments. deinit releases both owned buffers.

SnapshotReflow returns this object for pane resizes. Rust receives its
immutable arrays through the C API and performs the same local lookup. The map
has no pointers into terminal pages and survives later resizes until released.
See [the map design](src/terminal/REFLOW_MAP.md) for ownership and memory costs.

### src/terminal/SnapshotStyleRuns.zig

**Public API / types:** `Run`, `capture`.

Captures coalesced resolved style runs for one source row, using physical column
intervals. RGB colors are resolved through the terminal palette; UINT32_MAX
represents preview defaults. Flags retain bold, italic, strike, inverse,
invisible, faint, and underline. Background-only cells are included. Rust
combines these runs with the existing text-row export in its compact document.
Needed to preserve terminal styling without retaining another terminal for
picker previews. Native tests cover RGB colors, flags, backgrounds, coalescing,
and ABI size.

The former SnapshotPreviewLayout module and native preview handle/read/copy APIs
are removed. NFM now owns document layout and copy access.

### src/terminal/SnapshotLogicalPosition.zig

**Public API / types:** `Position`, `Range`, `CellRange`, `fromCell`, `resolve`.

Positions identify a hard-break-delimited logical line and a UTF-8 byte offset
in the same plain formatter output used by the source export. `fromCell`
captures the origin of a standalone line-split window. `resolve` scans current
physical row boundaries, counts logical lines, and resolves both endpoints in
one pass. It formats only relevant logical lines and reuses temporary row
buffers; returned cells do not retain native page pointers. Invalid positions
return an error. The C boundary holds the renderer lock and checks generation.

Needed because picker documents and source coordinates now survive pane
resize. Rust derives logical positions from its existing document only for
positional actions; candidates gain no additional payload or retained resize
map. Tests cover repeated Unicode reflow, wide wrap padding, and invalid lines.

### src/terminal/SnapshotReflow.zig

**Public API / types:** `Cell`, `Map`, `resizeMapped`, `resize`.

resizeMapped creates a recorder for the old layout, reflows the frozen pane terminal
through Screen, and returns the owned finalized map. Height-only resizing emits
identity segments before clamping trimmed rows. Only the viewport top needs a
temporary tracked pin. History limits are removed for the frozen terminal so
source text is not pruned during resizing.

The helper also updates tab stops, resets the scrolling region, and resizes any
inactive screen to keep terminal-wide dimensions consistent. Stale dimensions would make later snapshot validation reject it. A regression
captures a fresh terminal after shrinking, growing, and height-only resizing
with an existing alternate screen.

The internal resize convenience function validates caller cells and translates
them through the returned map; tests use it. Rust's pane calls resizeMapped
through the snapshot C API and reuses its map directly. Snapshot readers must
be stopped before resize. Tests compare every emitted UTF-8 byte against the
new formatter mapping, cover every source cell, Unicode/page boundaries, trimmed
blanks, unchanged width, map lifetime, repeated resize, and large histories.

### src/terminal/SnapshotTextCursor.zig

**Public API / types:** `Chunk`, `init`, `deinit`, `reset`, `next`.

`init`, `reset`, `next`, and `deinit` expose page-sized plain-text chunks and a
byte-to-cell map using the existing PageFormatter. Wrapped rows are unwrapped;
formatter trailing state is carried across page boundaries. Scratch buffers are
reused, and `row_base` places page coordinates within the full history.

Needed for logical-line searches without starting at the top of scrollback for
every requested chunk, and to map UTF-8 match offsets back to terminal cells.
The cursor borrows the snapshot and cannot survive a reflow or destruction.

### src/terminal/host_regression_tests.zig

**Public API / types:** No public runtime API; this file contains regression tests..

Exercises shrink/grow behavior with scrollback pulling disabled, including prompt
and active-screen alignment. Needed to protect the ConPTY-compatible resize behavior.
The body is separate so Terminal.zig does not carry the custom test implementation.

### src/termio/host_process.zig

**Public API / types:** `identity`, `msysTerminfoPath`, `signalQuit`.

Provides native-to-MSYS TERMINFO path conversion, original process ID/creation time
lookup, and Windows quit-pipe signaling through WriteFile. Needed for Git/MSYS
ncurses path interpretation, reliable host process identity, and Windows reader
shutdown. The path conversion regression test lives here too.

### src/termio/resize_diagnostics.zig

**Public API / types:** `reflow`, `notified`, `cursor`.

Logs reflow completion, ConPTY notification, and cursor-report coordinates when
stderr logging is enabled outside tests. Used to investigate resize ordering and
cursor alignment. It does not translate positions or alter terminal behavior;
these helper calls could be removed if the diagnostics are no longer useful.

## Changes intentionally removed

The earlier custom error-setting calls inside embedded.zig and config/CApi.zig
were removed. Their error-clearing calls were removed as well. Upstream operations
retain existing logs and return values; custom initialization and snapshot/host
APIs retain detailed error reporting. Host-side callers clear state at checked
boundaries, and do not treat a previous custom API error as a new upstream failure.
Those caller changes are in the C shim and are outside this Zig-file inventory.

src/os/windows.zig now matches hashi/main: dynamic loader and WriteFile declarations
were moved into the separate helpers that use them. It may still appear modified
relative to the local branch HEAD, which is a different comparison baseline.

The older second pane snapshot, retained pane stable-row translation APIs, and
layout revision mechanism were removed. The current pane uses a returned-map resize
handshake. Preview source-row coordinate anchors remain because their independent layout
requirements differ from the pane. They are translated through the map instead
of registered as tracked pins. ReflowPins.zig and its index hooks are removed.

## Maintenance and validation

For upstream updates, review structural integration points first: platform tags,
renderer terminal selection and decoration drawing, OpenGL lifecycle/frame types,
PageList reflow, IOCP wakeup ownership, Windows resize ordering, and DLL startup.
Standalone helpers reduce the overlapping diff but do not eliminate those dependencies.

Diagnostics and test imports do not implement product behavior. The incidental
blank-line deletion is not required. Required behavior could move elsewhere only
if the corresponding caller/ownership contract is preserved.

Native build and the snapshot test filter passed after map integration. The
resize filter passed 453 tests, the 70,000-row preview filter passed 75 tests
(including unnamed module tests), and all 207 Rust host tests passed. The three
copy resize tests were rerun after removing their obsolete deduplication helper.
The earlier export-name comparison predates the map-free export; the current
resize ABI has changed and native host/library clients must be rebuilt together.

To refresh the inventory, compare both tracked changes and new files:

```powershell
git diff hashi/main --name-only -- '*.zig'
git ls-files --others --exclude-standard -- '*.zig'
```

The concise module map remains in [src/HOST_EXTENSIONS.md](src/HOST_EXTENSIONS.md).

## Coverage check

This revision contains **119 annotated diff chunks across 29 existing files**,
followed by **25 added-file descriptions**. All 54 Zig files
that differ from the baseline are represented.
