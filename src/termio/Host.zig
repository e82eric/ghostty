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
