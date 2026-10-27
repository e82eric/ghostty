//! Host modal presentation lifecycle. Renderer state is accessed under its lock.
const Snapshot = @This();
const std = @import("std");
const global = @import("../global.zig");
const terminalpkg = @import("../terminal/main.zig");
const Surface = @import("../Surface.zig");
const log = std.log.scoped(.surface);

pub const Viewport = struct { start: usize, end: usize };
terminal: ?*terminalpkg.Terminal = null,
generation: u64 = 0,
text_row_anchor: ?struct { pin: terminalpkg.PageList.Pin, row: u64 } = null,

/// Capture an independently owned terminal while holding the terminal lock.
fn capture(_: *Snapshot, surface: *Surface) !*terminalpkg.Terminal {
    const result = try surface.alloc.create(terminalpkg.Terminal);
    errdefer surface.alloc.destroy(result);
    result.* = try terminalpkg.PresentationSnapshot.capture(
        surface.alloc,
        global.io(),
        surface.renderer_state.terminal,
    );
    return result;
}
/// Enter frozen presentation mode. Repeated calls retain the current
/// snapshot so its coordinates remain stable.
pub fn begin(self: *Snapshot, surface: *Surface) !void {
    surface.renderer_state.mutex.lockUncancelable(global.io());
    defer surface.renderer_state.mutex.unlock(global.io());
    if (self.terminal != null) return;
    const frozen = try self.capture(surface);
    self.terminal = frozen;
    surface.renderer_state.presentation_terminal = frozen;
    self.text_row_anchor = null;
    self.generation +%= 1;
    if (self.generation == 0) {
        self.generation = 1;
    }
    surface.renderer_thread.wakeup.notify() catch |err| {
        log.warn("failed to render after beginning snapshot mode err={}", .{err});
    };
}

/// Leave frozen presentation mode. The renderer is detached before snapshot
/// pages are destroyed. Built-in search has an independent lifecycle.
pub fn end(self: *Snapshot, surface: *Surface) void {
    surface.renderer_state.mutex.lockUncancelable(global.io());
    const snapshot_terminal = self.terminal orelse {
        surface.renderer_state.mutex.unlock(global.io());
        return;
    };
    surface.renderer_state.presentation_terminal = null;
    surface.renderer_state.terminal.flags.dirty.clear = true;
    self.terminal = null;
    self.text_row_anchor = null;
    surface.renderer_state.mutex.unlock(global.io());

    // Clear decorations before asking for the first live frame. The renderer
    // drains its mailbox before updating a frame, so no snapshot range is
    // evaluated against the live terminal.
    const empty_arena = std.heap.ArenaAllocator.init(surface.alloc);
    _ = surface.renderer_thread.mailbox.push(global.io(), .{
        .snapshot_decorations = .{ .arena = empty_arena, .layers = &.{} },
    }, .{ .forever = {} });
    // Show the live cursor immediately. The key that ended the snapshot never
    // reached the terminal, so the blink may otherwise be in its hidden phase
    // and cursor shaders would wait for the next blink to see it.
    _ = surface.renderer_thread.mailbox.push(global.io(), .{
        .reset_cursor_blink = {},
    }, .{ .forever = {} });

    snapshot_terminal.deinit(surface.alloc);
    surface.alloc.destroy(snapshot_terminal);
    surface.renderer_thread.wakeup.notify() catch |err| {
        log.warn("failed to render after ending snapshot mode err={}", .{err});
    };
}

/// Return true when modal presentation consumes a scroll event.
pub fn scroll(self: *Snapshot, surface: *Surface, delta: isize) bool {
    if (self.terminal == null) return false;
    surface.renderer_state.mutex.lockUncancelable(global.io());
    defer surface.renderer_state.mutex.unlock(global.io());
    if (surface.renderer_state.presentation_terminal) |frozen| {
        if (delta != 0) {
            frozen.screens.active.scroll(.{ .delta_row = delta * -1 });
            frozen.flags.dirty.clear = true;
        }
    }
    return true;
}
