//! Resolve retained document positions against the current frozen layout.
const std = @import("std");
const terminal = @import("main.zig");
pub const Position = extern struct { line: u64, byte: u64 };
pub const Range = extern struct { start: Position, end: Position };
pub const Cell = terminal.SnapshotReflow.Cell;
pub const CellRange = extern struct { start: Cell, end: Cell };

fn format(alloc: std.mem.Allocator, pin: terminal.PageList.Pin, writer: *std.Io.Writer.Allocating, points: *std.ArrayList(terminal.Coordinate)) !void {
    writer.clearRetainingCapacity();
    points.clearRetainingCapacity();
    var f: @import("formatter.zig").PageFormatter = .init(pin.node.page(), .{ .emit = .plain, .unwrap = false, .trim = false });
    f.start_y = pin.y;
    f.end_y = pin.y;
    f.point_map = .{ .alloc = alloc, .map = points };
    try f.format(&writer.writer);
}

pub fn fromCell(alloc: std.mem.Allocator, t: *const terminal.Terminal, cell: Cell) !Position {
    const pages = &t.screens.active.pages;
    if (cell.y >= pages.total_rows or cell.x >= t.cols) return error.InvalidPosition;
    var it = pages.rowIterator(.right_down, .{ .screen = .{ .x = 0, .y = 0 } }, null);
    var line: u64 = 0;
    var start: u64 = 0;
    var y: u64 = 0;
    while (it.next()) |pin| : (y += 1) {
        if (y == cell.y) break;
        if (!pin.node.page().getRow(pin.y).wrap) {
            line += 1;
            start = y + 1;
        }
    }
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    var points: std.ArrayList(terminal.Coordinate) = .empty;
    defer points.deinit(alloc);
    it = pages.rowIterator(.right_down, .{ .screen = .{ .x = 0, .y = @intCast(start) } }, null);
    var byte: u64 = 0;
    y = start;
    while (it.next()) |pin| : (y += 1) {
        try format(alloc, pin, &writer, &points);
        if (y == cell.y) {
            for (points.items, 0..) |point, i| {
                if (point.x >= cell.x) return .{ .line = line, .byte = byte + i };
            }
            return .{ .line = line, .byte = byte + writer.written().len };
        }
        byte += writer.written().len;
    }
    return error.InvalidPosition;
}

pub fn resolve(alloc: std.mem.Allocator, t: *const terminal.Terminal, range: Range) !CellRange {
    var it = t.screens.active.pages.rowIterator(.right_down, .{ .screen = .{ .x = 0, .y = 0 } }, null);
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    var points: std.ArrayList(terminal.Coordinate) = .empty;
    defer points.deinit(alloc);
    var line: u64 = 0;
    var byte: u64 = 0;
    var y: u64 = 0;
    var found = [_]?Cell{ null, null };
    const positions = [_]Position{ range.start, range.end };
    while (it.next()) |pin| : (y += 1) {
        const wraps = pin.node.page().getRow(pin.y).wrap;
        if (line == range.start.line or line == range.end.line) {
            try format(alloc, pin, &writer, &points);
            for (positions, &found) |position, *cell| {
                if (cell.* != null or position.line != line or position.byte < byte) continue;
                const offset = position.byte - byte;
                if (offset < points.items.len) {
                    cell.* = .{ .x = points.items[@intCast(offset)].x, .y = y };
                } else if (!wraps and offset == points.items.len) {
                    cell.* = .{ .x = if (points.items.len > 0) points.items[points.items.len - 1].x else 0, .y = y };
                }
            }
            byte += writer.written().len;
        }
        if (found[0] != null and found[1] != null) return .{ .start = found[0].?, .end = found[1].? };
        if (!wraps) {
            line += 1;
            byte = 0;
        }
    }
    return error.InvalidPosition;
}

test "snapshot logical range survives repeated Unicode reflow" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 12, .rows = 4 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("header\r\nabc\xe7\x95\x8ce\xcc\x81fghijklmnop\r\nlast");
    const position = try fromCell(testing.allocator, &t, .{ .x = 3, .y = 1 });
    try testing.expectEqual(@as(u64, 1), position.line);
    try testing.expectEqual(@as(u64, 3), position.byte);
    const last = try fromCell(testing.allocator, &t, .{ .x = 2, .y = 3 });
    for ([_]u16{ 4, 5, 20, 7, 12 }) |cols| {
        try terminal.SnapshotReflow.resize(testing.allocator, &t, cols, 4, &.{});
        const resolved = try resolve(testing.allocator, &t, .{ .start = position, .end = last });
        const pin = t.screens.active.pages.pin(.{ .screen = .{ .x = @intCast(resolved.start.x), .y = @intCast(resolved.start.y) } }).?;
        try testing.expectEqual(@as(u21, '界'), pin.node.page().getCells(pin.node.page().getRow(pin.y))[resolved.start.x].codepoint());
        try testing.expectEqualDeep(position, try fromCell(testing.allocator, &t, resolved.start));
        try testing.expectEqualDeep(last, try fromCell(testing.allocator, &t, resolved.end));
    }
    try testing.expectError(error.InvalidPosition, resolve(testing.allocator, &t, .{ .start = .{ .line = 999, .byte = 0 }, .end = position }));
}

test "snapshot logical range resolves through 70000 history rows" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 2, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..70000) |_| stream.nextSlice("item\r\n");
    const range: Range = .{ .start = .{ .line = 69999, .byte = 1 }, .end = .{ .line = 69999, .byte = 3 } };
    try terminal.SnapshotReflow.resize(testing.allocator, &t, 3, 2, &.{});
    const resolved = try resolve(testing.allocator, &t, range);
    try testing.expectEqualDeep(range.start, try fromCell(testing.allocator, &t, resolved.start));
    try testing.expectEqualDeep(range.end, try fromCell(testing.allocator, &t, resolved.end));
    try testing.expectEqual(@as(u32, 0), resolved.end.x);
    try testing.expectEqual(resolved.start.y + 1, resolved.end.y);
}
