//! Coordinate-only diagnostics for terminal/ConPTY resize coordination.
const builtin = @import("builtin");
const global = @import("../global.zig");
const Terminal = @import("../terminal/Terminal.zig");

fn enabled() bool {
    return !builtin.is_test and global.logging().stderr;
}

pub fn reflow(comptime log: anytype, terminal: *const Terminal, grid: anytype) void {
    if (!enabled()) return;
    log.info("resize diagnostic reflow_complete rows={} cols={} cursor_row={} cursor_col={}", .{
        grid.rows,                            grid.columns,
        terminal.screens.active.cursor.y + 1, terminal.screens.active.cursor.x + 1,
    });
}

pub fn notified(comptime log: anytype, grid: anytype) void {
    if (enabled()) log.info("resize diagnostic conpty_notified rows={} cols={}", .{ grid.rows, grid.columns });
}

pub fn cursor(comptime log: anytype, terminal: *const Terminal, pos: anytype) void {
    if (enabled()) log.info("resize diagnostic cursor_report rows={} cols={} cursor_row={} cursor_col={}", .{
        terminal.rows, terminal.cols, pos.y + 1, pos.x + 1,
    });
}
