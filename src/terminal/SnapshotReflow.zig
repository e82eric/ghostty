//! Reflow a frozen terminal in place, carrying caller positions with it.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const Pin = @import("PageList.zig").Pin;

pub const Cell = extern struct { x: u32, y: u64 };

/// Reflow the frozen terminal to the given grid and translate each position
/// in place. Positions ride upstream tracked pins through the reflow, so the
/// pin set grows only by the caller's handful of positions for its duration.
pub fn resize(alloc: std.mem.Allocator, t: *Terminal, cols: u16, rows: u16, positions: []Cell) !void {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    const screen = t.screens.active;
    const pages = &screen.pages;
    for (positions) |cell| {
        if (cell.x >= t.cols or cell.y >= pages.total_rows) return error.InvalidPosition;
    }
    if (t.cols == cols and t.rows == rows) return;
    const pins = try alloc.alloc(*Pin, positions.len);
    defer alloc.free(pins);
    var tracked: usize = 0;
    defer for (pins[0..tracked]) |p| pages.untrackPin(p);
    for (positions) |cell| {
        const p = pages.pin(.{ .screen = .{ .x = @intCast(cell.x), .y = @intCast(cell.y) } }) orelse
            return error.InvalidPosition;
        pins[tracked] = try pages.trackPin(p);
        tracked += 1;
    }
    const top_pin = try pages.trackPin(pages.getTopLeft(.viewport));
    defer pages.untrackPin(top_pin);
    pages.setMaxBytes(null);
    pages.setMaxLines(null);
    screen.no_scrollback = false;
    try screen.resize(.{ .cols = cols, .rows = rows, .reflow = true, .pull_scrollback = true });
    // A frozen snapshot can be captured again for a fresh picker preview.
    // Keep all terminal-wide dimensions consistent with the reflowed screen,
    // just as Terminal.resize does for the live terminal.
    var screens = t.screens.all.iterator();
    while (screens.next()) |entry| {
        const other = entry.value.*;
        if (other == screen) continue;
        try other.resize(.{ .cols = cols, .rows = rows, .reflow = false });
    }
    var tabstops = try @import("Tabstops.zig").init(alloc, cols, 8);
    defer tabstops.deinit(alloc);
    std.mem.swap(@import("Tabstops.zig"), &t.tabstops, &tabstops);
    t.cols = cols;
    t.rows = rows;
    t.scrolling_region = .{ .top = 0, .bottom = rows - 1, .left = 0, .right = cols - 1 };
    for (positions, pins) |*cell, p| {
        const point = pages.pointFromPin(.screen, p.*) orelse return error.InvalidPosition;
        cell.* = .{ .x = point.screen.x, .y = point.screen.y };
    }
    const top = pages.pointFromPin(.screen, top_pin.*).?.screen.y;
    screen.scroll(.{ .row = @min(top, pages.total_rows -| rows) });
    t.flags.dirty.clear = true;
}
test "snapshot reflow allows fresh preview capture after resize" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("preview content\r\nnext line\x1b[?1049h alternate\x1b[?1049l");
    for ([_][2]u16{ .{ 40, 12 }, .{ 120, 30 }, .{ 120, 10 } }) |grid| {
        var none = [_]Cell{};
        try resize(testing.allocator, &t, grid[0], grid[1], &none);
        var preview = try @import("PresentationSnapshot.zig").capture(testing.allocator, testing.io, &t);
        defer preview.deinit(testing.allocator);
        try testing.expectEqual(grid[0], preview.cols);
        try testing.expectEqual(grid[1], preview.rows);
        try testing.expectEqual(grid[0], preview.screens.get(.alternate).?.pages.cols);
        try testing.expectEqual(grid[1], preview.screens.get(.alternate).?.pages.rows);
    }
}

test "snapshot reflow translates endpoints in place without retained row anchors" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 4, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("abcdefghijkl\r\nnext");
    var cells = [_]Cell{ .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 } };
    const pin_count = t.screens.active.pages.tracked_pins.count();
    try resize(testing.allocator, &t, 12, 4, &cells);
    try testing.expectEqual(Cell{ .x = 7, .y = 0 }, cells[0]);
    try testing.expectEqual(Cell{ .x = 10, .y = 0 }, cells[1]);
    try resize(testing.allocator, &t, 3, 4, &cells);
    try testing.expectEqual(Cell{ .x = 1, .y = 2 }, cells[0]);
    try testing.expectEqual(Cell{ .x = 1, .y = 3 }, cells[1]);
    try testing.expectEqual(pin_count, t.screens.active.pages.tracked_pins.count());
}

test "snapshot reflow preserves Unicode block row segments and isolated live output" {
    const testing = std.testing;
    var live = try Terminal.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 4, .max_scrollback_bytes = null });
    defer live.deinit(testing.allocator);
    var stream = live.vtStream();
    defer stream.deinit();
    stream.nextSlice("abç•Œe\u{301}fghijklmnop\r\nnext");
    var t = try @import("PresentationSnapshot.zig").capture(testing.allocator, testing.io, &live);
    defer t.deinit(testing.allocator);
    var cells = [_]Cell{ .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 2, .y = 1 }, .{ .x = 5, .y = 1 } };
    var expected: [2][:0]const u8 = undefined;
    for (&expected, 0..) |*text, i| text.* = try selectionText(testing.allocator, &t, cells[i * 2], cells[i * 2 + 1]);
    defer for (expected) |text| testing.allocator.free(text);
    stream.nextSlice("output after snapshot capture");
    for ([_]u16{ 4, 16, 6, 8 }) |cols| {
        try resize(testing.allocator, &t, cols, 4, &cells);
        for (expected, 0..) |text, i| {
            const actual = try selectionText(testing.allocator, &t, cells[i * 2], cells[i * 2 + 1]);
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings(text, actual);
        }
    }
    try testing.expectEqual(@as(u16, 8), live.cols);
}

test "snapshot reflow validates all caller positions before changing the layout" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 4 });
    defer t.deinit(testing.allocator);
    const count = t.screens.active.pages.tracked_pins.count();
    var cells = [_]Cell{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 } };
    try testing.expectError(error.InvalidPosition, resize(testing.allocator, &t, 4, 4, &cells));
    try testing.expectEqual(count, t.screens.active.pages.tracked_pins.count());
    try testing.expectEqual(@as(u16, 8), t.cols);
    try testing.expectEqual(Cell{ .x = 0, .y = 0 }, cells[0]);
}

test "snapshot reflow large history needs only retained endpoint anchors" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..30000) |_| stream.nextSlice("G:\\projects\\some-long-directory\\another-directory\\more-directories\\a-long-file-name-that-wraps-at-the-original-window-width.txt\r\n");
    try testing.expect(t.screens.active.pages.total_rows >= 60000);
    t.screens.active.scroll(.{ .row = 20000 });
    var cells = [_]Cell{ .{ .x = 30, .y = 20000 }, .{ .x = 20, .y = 20001 } };
    const expected = try selectionText(testing.allocator, &t, cells[0], cells[1]);
    defer testing.allocator.free(expected);
    const pin_count = t.screens.active.pages.tracked_pins.count();
    for ([_][2]u16{ .{ 240, 80 }, .{ 80, 24 }, .{ 320, 100 } }) |grid| {
        try resize(testing.allocator, &t, grid[0], grid[1], &cells);
        const actual = try selectionText(testing.allocator, &t, cells[0], cells[1]);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
        // No row-anchor table survives in the pane after the handshake.
        try testing.expectEqual(pin_count, t.screens.active.pages.tracked_pins.count());
    }
}

fn selectionText(alloc: std.mem.Allocator, t: *Terminal, a: Cell, b: Cell) ![:0]const u8 {
    const pages = &t.screens.active.pages;
    return t.screens.active.selectionString(alloc, .{
        .sel = .init(pages.pin(.{ .screen = .{ .x = @intCast(a.x), .y = @intCast(a.y) } }).?, pages.pin(.{ .screen = .{ .x = @intCast(b.x), .y = @intCast(b.y) } }).?, false),
        .trim = false,
    });
}

const MappedText = struct {
    text: std.ArrayList(u8) = .empty,
    cells: std.ArrayList(Cell) = .empty,

    fn deinit(self: *MappedText) void {
        self.text.deinit(std.testing.allocator);
        self.cells.deinit(std.testing.allocator);
    }
};

fn readMappedText(t: *Terminal) !MappedText {
    var result: MappedText = .{};
    errdefer result.deinit();
    var cursor = try @import("SnapshotTextCursor.zig").init(t.screens.active, std.testing.allocator);
    defer cursor.deinit();
    while (try cursor.next()) |chunk| {
        try result.text.appendSlice(std.testing.allocator, chunk.text);
        for (chunk.points) |point| try result.cells.append(std.testing.allocator, .{
            .x = point.x,
            .y = chunk.row_base + point.y - chunk.start_y,
        });
    }
    return result;
}

test "snapshot reflow translates text bytes and blank cells across Unicode and page boundaries" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 13, .rows = 7, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..700) |_| stream.nextSlice("\x1b[31mab界e\u{301}XYZ界0123456789\x1b[0m\r\n\r\n");
    var positions: std.ArrayList(Cell) = .empty;
    defer positions.deinit(testing.allocator);
    for ([_][2]u16{ .{ 4, 11 }, .{ 31, 5 }, .{ 7, 24 }, .{ 7, 3 }, .{ 13, 7 } }) |grid| {
        var before = try readMappedText(&t);
        defer before.deinit();
        // Sample text bytes (every tracked pin is scanned per reflowed cell),
        // plus every cell of some rows, including blanks and wide spacers.
        positions.clearRetainingCapacity();
        var sampled: std.ArrayList(usize) = .empty;
        defer sampled.deinit(testing.allocator);
        for (before.text.items, before.cells.items, 0..) |byte, cell, i| {
            if (byte == '\n' or i % 7 != 0) continue;
            try sampled.append(testing.allocator, i);
            try positions.append(testing.allocator, cell);
        }
        const text_positions = positions.items.len;
        const old_rows = t.screens.active.pages.total_rows;
        var row: u64 = 0;
        while (row < old_rows) : (row += 97) {
            for (0..t.cols) |x| try positions.append(testing.allocator, .{ .x = @intCast(x), .y = row });
        }
        const pins = t.screens.active.pages.tracked_pins.count();
        try resize(testing.allocator, &t, grid[0], grid[1], positions.items);
        var after = try readMappedText(&t);
        defer after.deinit();
        try testing.expectEqualStrings(before.text.items, after.text.items);
        for (sampled.items, positions.items[0..text_positions]) |i, actual| {
            try testing.expectEqual(after.cells.items[i], actual);
        }
        const new_rows = t.screens.active.pages.total_rows;
        for (positions.items[text_positions..]) |cell| {
            try testing.expect(cell.x < grid[0] and cell.y < new_rows);
        }
        try testing.expectEqual(pins, t.screens.active.pages.tracked_pins.count());
    }
}

test "snapshot reflow survives subsequent resize from trimmed blank rows" {
    var t = try Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 8, .rows = 20 });
    defer t.deinit(std.testing.allocator);
    var cells = [_]Cell{.{ .x = 7, .y = 19 }};
    try resize(std.testing.allocator, &t, 4, 2, &cells);
    try std.testing.expect(cells[0].x < 4 and cells[0].y < t.screens.active.pages.total_rows);
    try resize(std.testing.allocator, &t, 12, 3, &cells);
    try std.testing.expect(cells[0].x < 12 and cells[0].y < t.screens.active.pages.total_rows);
}
