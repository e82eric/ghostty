//! Termio backend driven by the embedding host. It owns no pty and no child
//! process: the host pushes output in through `Termio.processOutput` and
//! receives writes and resizes through callbacks.
//!
//! An optional terminal snapshot replaces the fresh terminal's contents, so a
//! surface can attach to a terminal that is already running elsewhere.
const Host = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const snapshot = @import("../terminal/snapshot/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_host);

/// ghostty_host_backend_s
pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,
    /// Bytes for the pty: encoded input and query replies.
    write: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
    resize: ?*const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void = null,
    /// What this surface would have run had it owned the process. Called
    /// once, on the thread creating the surface, before creation returns.
    /// The pointers are valid only during the call.
    spawn: ?*const fn (?*anyopaque, *const Spawn) callconv(.c) void = null,
    /// What the surface's terminal is configured with. Called while the
    /// surface is created and again, from its IO thread, whenever the
    /// configuration changes.
    settings: ?*const fn (?*anyopaque, *const Settings) callconv(.c) void = null,
};

/// ghostty_host_env_s
pub const EnvVar = extern struct {
    key: [*:0]const u8,
    value: [*:0]const u8,
};

/// ghostty_host_spawn_s
pub const Spawn = extern struct {
    /// A Windows command line; elsewhere the arguments joined the same way.
    command: [*:0]const u8,
    cwd: ?[*:0]const u8,
    env: [*]const EnvVar,
    env_len: usize,
};

/// ghostty_host_settings_s
///
/// The parts of the configuration that change how a terminal parses or what
/// it answers, for a host that keeps a second terminal in step with this one.
pub const Settings = extern struct {
    palette: [256][3]u8,
    foreground: [3]u8,
    background: [3]u8,
    cursor: [3]u8,
    has_cursor: bool,
    /// 0 bar, 1 block, 2 underline, 3 hollow block.
    cursor_style: u8,
    /// -1 when the configuration leaves it to the program.
    cursor_blink: i8,
    dark: bool,
    image_storage_limit: u64,
    /// The rest is known only when the surface is created.
    has_creation: bool,
    grapheme_cluster: bool,
    /// maxInt for no limit.
    scrollback_bytes: u64,
    scrollback_lines: u64,
    /// How the surface's terminal names itself. These repeat what
    /// stream_handler.zig answers and must be kept in step with it.
    /// The XTVERSION text, NUL-terminated.
    xtversion: [96]u8,
    /// The answer to ENQ, NUL-terminated and cut to fit.
    enquiry: [128]u8,
    /// Primary device attributes: conformance level, then features.
    da_conformance: u16,
    da_features: [4]u16,
    da_features_len: u16,
    /// Secondary device attributes.
    da_secondary: [3]u16,
};

/// Owns `initial` and `continuation`.
alloc: Allocator,

/// The allocator Termio creates and destroys its terminal with. The surface
/// sets this before handing the backend to Termio.
terminal_alloc: Allocator,
callbacks: Callbacks,

/// Owned snapshot bytes, released once the terminal is initialized.
initial: ?[]u8 = null,

/// Unfinished parser input carried by the snapshot, replayed once the
/// terminal stream exists.
continuation: ?[]u8 = null,

/// The backend the next surface created on this thread uses. A surface
/// config field would be cleaner; this avoids extending an upstream struct.
threadlocal var pending: ?Host = null;

/// Make the next surface created on this thread use a host backend. The
/// snapshot is copied.
pub fn setPending(callbacks: Callbacks, initial: ?[]const u8) Allocator.Error!void {
    if (pending) |*old| old.deinit();
    // The host may call this before the library's allocator exists.
    const alloc = std.heap.smp_allocator;
    pending = .{
        .alloc = alloc,
        .terminal_alloc = alloc,
        .callbacks = callbacks,
        .initial = if (initial) |bytes| try alloc.dupe(u8, bytes) else null,
    };
}

pub fn takePending() ?Host {
    const result = pending;
    pending = null;
    return result;
}

pub fn deinit(self: *Host) void {
    if (self.initial) |bytes| self.alloc.free(bytes);
    if (self.continuation) |bytes| self.alloc.free(bytes);
    self.* = undefined;
}

/// Tell the host what process this surface would have started. Takes
/// ownership of `cfg.env`, as `Exec.init` does.
pub fn describeSpawn(self: *Host, gpa: Allocator, cfg: termio.Exec.Config) void {
    const f = self.callbacks.spawn orelse {
        var env = cfg.env;
        env.deinit();
        return;
    };
    // The same preparation Exec makes: TERM, shell integration, the
    // configured environment, and the command as it would be run.
    var subprocess = termio.Exec.Subprocess.init(gpa, cfg) catch |err| {
        log.warn("unable to describe the process for the host err={}", .{err});
        return;
    };
    defer subprocess.deinit();
    const alloc = subprocess.arena.allocator();

    const args = alloc.alloc([]const u8, subprocess.args.len) catch return;
    for (subprocess.args, args) |arg, *out| out.* = arg;
    const command = @import("../Command.zig").windowsCreateCommandLine(alloc, args) catch return;

    var vars: std.ArrayList(EnvVar) = .empty;
    if (subprocess.env) |*env| {
        var it = env.iterator();
        while (it.next()) |entry| {
            const key = alloc.dupeSentinel(u8, entry.key_ptr.*, 0) catch return;
            const value = alloc.dupeSentinel(u8, entry.value_ptr.*, 0) catch return;
            vars.append(alloc, .{ .key = key, .value = value }) catch return;
        }
    }

    f(self.callbacks.userdata, &.{
        .command = command.ptr,
        .cwd = if (subprocess.cwd) |cwd| cwd.ptr else null,
        .env = vars.items.ptr,
        .env_len = vars.items.len,
    });
}

/// Tell the host how this surface's terminal is configured. `full` is given
/// when the surface is created; a configuration change has only `config`.
pub fn reportSettings(
    self: *const Host,
    config: *const termio.DerivedConfig,
    full: ?*const @import("../config.zig").Config,
) void {
    const f = self.callbacks.settings orelse return;
    var settings: Settings = .{
        .palette = undefined,
        .foreground = rgb(config.foreground.toTerminalRGB()),
        .background = rgb(config.background.toTerminalRGB()),
        .cursor = .{ 0, 0, 0 },
        .has_cursor = false,
        .cursor_style = switch (config.cursor_style) {
            .bar => 0,
            .block => 1,
            .underline => 2,
            .block_hollow => 3,
        },
        .cursor_blink = if (config.cursor_blink) |blink| @intFromBool(blink) else -1,
        .dark = config.conditional_state.theme == .dark,
        .image_storage_limit = config.image_storage_limit,
        .has_creation = false,
        .grapheme_cluster = false,
        .scrollback_bytes = std.math.maxInt(u64),
        .scrollback_lines = std.math.maxInt(u64),
        .xtversion = @splat(0),
        .enquiry = @splat(0),
        // StreamHandler.deviceAttributes: a VT220 with color, and clipboard
        // access when writes are allowed.
        .da_conformance = 62,
        .da_features = .{ 22, 52, 0, 0 },
        .da_features_len = if (config.clipboard_write != .deny) 2 else 1,
        .da_secondary = .{ 1, 10, 0 },
    };
    // StreamHandler.reportXtversion.
    _ = std.fmt.bufPrint(
        settings.xtversion[0 .. settings.xtversion.len - 1],
        "ghostty {s}",
        .{@import("../build_config.zig").version_string},
    ) catch {};
    const enquiry_len = @min(config.enquiry_response.len, settings.enquiry.len - 1);
    @memcpy(settings.enquiry[0..enquiry_len], config.enquiry_response[0..enquiry_len]);
    for (config.palette, &settings.palette) |color, *out| out.* = rgb(color);
    if (config.cursor_color) |color| if (color.toTerminalRGB()) |value| {
        settings.cursor = rgb(value);
        settings.has_cursor = true;
    };
    if (full) |c| {
        settings.has_creation = true;
        settings.grapheme_cluster = c.@"grapheme-width-method" == .unicode;
        if (c.@"scrollback-limit-bytes".optional()) |v| settings.scrollback_bytes = v;
        if (c.@"scrollback-limit-lines".optional()) |v| settings.scrollback_lines = v;
    }
    f(self.callbacks.userdata, &settings);
}

fn rgb(color: terminal.color.RGB) [3]u8 {
    return .{ color.r, color.g, color.b };
}

/// Replace the fresh terminal with the snapshot's visible screen. History
/// records in the snapshot are left unread.
pub fn initTerminal(self: *Host, t: *terminal.Terminal) void {
    // ConPTY keeps only the active screen; see Exec.initTerminal.
    if (comptime @import("builtin").os.tag == .windows) {
        t.flags.resize_pull_scrollback = false;
    }

    const bytes = self.initial orelse return;
    defer {
        self.alloc.free(bytes);
        self.initial = null;
    }
    self.continuation = restore(self.alloc, self.terminal_alloc, t, bytes);
}

/// Replace a live surface's terminal with the snapshot's visible screen, at
/// this point in its output. The host calls this when its own terminal is the
/// authority and the two may have drifted, such as after a resize.
pub fn resync(io: *termio.Termio, bytes: []const u8) void {
    const scratch = std.heap.smp_allocator;
    const continuation = continuation: {
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const result = restore(scratch, io.alloc, &io.terminal, bytes);

        // The snapshot carries the parser state; ours is stale.
        const stream = &io.terminal_stream;
        const osc_alloc = stream.parser.osc_parser.alloc;
        const osc_max = stream.parser.osc_parser.unknown_max_bytes;
        stream.parser.deinit();
        stream.parser = .init();
        stream.parser.osc_parser.alloc = osc_alloc;
        stream.parser.osc_parser.unknown_max_bytes = osc_max;
        stream.utf8decoder = .{};
        break :continuation result;
    };

    if (continuation) |pending_bytes| {
        defer scratch.free(pending_bytes);
        io.processOutput(pending_bytes);
    } else {
        io.terminal_stream.handler.queueRender() catch {};
    }
}

/// Swap the snapshot's terminal into `t`, keeping `t`'s size and colors.
/// Returns the snapshot's unfinished parser input, owned by `scratch`.
fn restore(
    scratch: Allocator,
    alloc: Allocator,
    t: *terminal.Terminal,
    bytes: []const u8,
) ?[]u8 {
    var continuation: ?[]u8 = null;
    var reader: std.Io.Reader = .fixed(bytes);
    var decoder: snapshot.Decoder = .init(&reader);
    var decoded = decoder.ready(alloc, global.io(), .{
        .max_continuation_bytes = 1 << 20,
    }) catch |err| {
        log.warn("unable to restore host snapshot err={}", .{err});
        return null;
    };
    defer decoded.deinit(alloc);

    switch (decoded.continuation) {
        .ground => {},
        .bytes => |v| continuation = scratch.dupe(u8, v) catch null,
    }

    // Keep what the surface derived from its own config and size. After the
    // swap the fresh terminal holds the snapshot's colors and frees them.
    const restored = &decoded.terminal.?;
    std.mem.swap(@TypeOf(restored.colors), &restored.colors, &t.colors);
    restored.width_px = t.width_px;
    restored.height_px = t.height_px;
    restored.flags.resize_pull_scrollback = t.flags.resize_pull_scrollback;
    const cols = t.cols;
    const rows = t.rows;

    t.deinit(alloc);
    t.* = decoded.toOwned();
    // The snapshot brings the limits of the terminal it was made from, and
    // the rest of the page its screen sits on. The surface keeps neither.
    t.setScrollbackMaxBytes(0);

    if (t.cols != cols or t.rows != rows) {
        t.resize(alloc, .{ .cols = cols, .rows = rows }) catch |err| {
            log.warn("unable to fit host snapshot to surface err={}", .{err});
        };
    }
    t.flags.dirty.clear = true;
    return continuation;
}

pub fn threadEnter(
    self: *Host,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    td.backend = .{ .host = .{} };
    if (self.continuation) |bytes| {
        io.processOutput(bytes);
        self.alloc.free(bytes);
        self.continuation = null;
    }
}

pub fn threadExit(self: *Host, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(self: *Host, td: *termio.Termio.ThreadData, focused: bool) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Host,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const f = self.callbacks.resize orelse return;
    f(
        self.callbacks.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

pub fn queueWrite(
    self: *Host,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    const f = self.callbacks.write orelse return;
    if (!linefeed) {
        if (data.len > 0) f(self.callbacks.userdata, data.ptr, data.len);
        return;
    }

    // Linefeed mode sends CR LF for CR.
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (data) |ch| {
        if (len + 2 > buf.len) {
            f(self.callbacks.userdata, &buf, len);
            len = 0;
        }
        buf[len] = ch;
        len += 1;
        if (ch == '\r') {
            buf[len] = '\n';
            len += 1;
        }
    }
    if (len > 0) f(self.callbacks.userdata, &buf, len);
}

pub fn childExitedAbnormally(
    self: *Host,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// The host started the process, so it already knows about it.
pub fn getProcessInfo(self: *Host, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
