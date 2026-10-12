//! Reflow a frozen terminal in place and return an owned indexed translation map.
const std = @import("std");
const Terminal = @import("Terminal.zig");

pub const Cell = extern struct { x: u32, y: u64 };

pub const Map = @import("ReflowMap.zig");

pub fn resizeMapped(alloc: std.mem.Allocator, t: *Terminal, cols: u16, rows: u16) !Map {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    const screen = t.screens.active;
    const pages = &screen.pages;
    var map = try Map.init(alloc, pages.total_rows, t.cols, cols);
    errdefer map.deinit();
    var tabstops = try @import("Tabstops.zig").init(alloc, cols, 8);
    defer tabstops.deinit(alloc);
    // Only the viewport needs an upstream tracked pin. Rust positions and
    // preview anchors use the map and never enlarge the tracked pin set.
    const top_pin = try pages.trackPin(pages.getTopLeft(.viewport));
    defer pages.untrackPin(top_pin);
    pages.setMaxBytes(null);
    pages.setMaxLines(null);
    screen.no_scrollback = false;
    if (t.cols == cols) {
        for (0..pages.total_rows) |y| {
            map.beginRow(y);
            try map.record(0, y, 0, cols, 1);
            map.endRow();
        }
    }
    try screen.resize(.{ .cols = cols, .rows = rows, .reflow = true, .pull_scrollback = true, .reflow_map = &map });
    // A frozen snapshot can be captured again for a fresh picker preview.
    // Keep all terminal-wide dimensions consistent with the reflowed screen,
    // just as Terminal.resize does for the live terminal.
    var screens = t.screens.all.iterator();
    while (screens.next()) |entry| {
        const other = entry.value.*;
        if (other == screen) continue;
        try other.resize(.{ .cols = cols, .rows = rows, .reflow = false });
    }
    std.mem.swap(@import("Tabstops.zig"), &t.tabstops, &tabstops);
    t.cols = cols;
    t.rows = rows;
    t.scrolling_region = .{ .top = 0, .bottom = rows - 1, .left = 0, .right = cols - 1 };
    try map.finish(pages.total_rows);
    const top = pages.pointFromPin(.screen, top_pin.*).?.screen.y;
    screen.scroll(.{ .row = @min(top, pages.total_rows -| rows) });
    t.flags.dirty.clear = true;
    return map;
}

pub fn resize(alloc: std.mem.Allocator, t: *Terminal, cols: u16, rows: u16, positions: []Cell) !void {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    for (positions) |cell| {
        if (cell.x >= t.cols or cell.y >= t.screens.active.pages.total_rows) return error.InvalidPosition;
    }
    if (t.cols == cols and t.rows == rows) return;
    var map = try resizeMapped(alloc, t, cols, rows);
    defer map.deinit();
    for (positions) |*cell| {
        const translated = map.translate(.{ .x = cell.x, .y = cell.y }) orelse return error.InvalidPosition;
        cell.* = .{ .x = translated.x, .y = translated.y };
    }
}

test "snapshot reflow allows fresh preview capture after resize" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("preview content\r\nnext line\x1b[?1049h alternate\x1b[?1049l");
    for ([_][2]u16{ .{ 40, 12 }, .{ 120, 30 }, .{ 120, 10 } }) |grid| {
        var map = try resizeMapped(testing.allocator, &t, grid[0], grid[1]);
        map.deinit();
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
    cells: std.ArrayList(Map.Cell) = .empty,

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

test "snapshot reflow map translates every text byte across Unicode and page boundaries" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 13, .rows = 7, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..700) |_| stream.nextSlice("\x1b[31mab界e\u{301}XYZ界0123456789\x1b[0m\r\n\r\n");
    for ([_][2]u16{ .{ 4, 11 }, .{ 31, 5 }, .{ 7, 24 }, .{ 7, 3 }, .{ 13, 7 } }) |grid| {
        var before = try readMappedText(&t);
        defer before.deinit();
        const pins = t.screens.active.pages.tracked_pins.count();
        var map = try resizeMapped(testing.allocator, &t, grid[0], grid[1]);
        defer map.deinit();
        var after = try readMappedText(&t);
        defer after.deinit();
        try testing.expectEqualStrings(before.text.items, after.text.items);
        for (before.text.items, before.cells.items, after.cells.items) |byte, old, actual| {
            if (byte == '\n') continue;
            try testing.expectEqual(actual, map.translate(old).?);
        }
        // Every original cell has a valid indexed translation, including
        // blank rows and wide-character spacers not emitted by the formatter.
        for (0..map.row_offsets.len - 1) |row| {
            try testing.expect(map.row_offsets[row] <= map.row_offsets[row + 1]);
            for (0..map.old_columns) |column| {
                const cell = map.translate(.{ .x = @intCast(column), .y = row }).?;
                try testing.expect(cell.x < map.new_columns and cell.y < map.new_rows);
            }
        }
        try testing.expectEqual(pins, t.screens.active.pages.tracked_pins.count());
    }
}

test "snapshot reflow map survives subsequent resize and maps trimmed blank rows" {
    var t = try Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 8, .rows = 20 });
    defer t.deinit(std.testing.allocator);
    var map = try resizeMapped(std.testing.allocator, &t, 4, 2);
    defer map.deinit();
    const translated = map.translate(.{ .x = 7, .y = 19 }).?;
    var next = try resizeMapped(std.testing.allocator, &t, 12, 3);
    defer next.deinit();
    try std.testing.expectEqual(translated, map.translate(.{ .x = 7, .y = 19 }).?);
    try std.testing.expect(translated.x < 4 and translated.y < map.new_rows);
}
