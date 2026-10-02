//! Sequential, page-sized text access to an immutable presentation snapshot.
//! Text and byte-to-cell points share the PageFormatter's exact layout rules.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const formatter = @import("formatter.zig");
const Coordinate = @import("point.zig").Coordinate;

alloc: Allocator,
screen: *Screen,
iterator: PageList.PageIterator,
top: PageList.Pin,
bottom: PageList.Pin,
trailing_state: ?formatter.PageFormatter.TrailingState = null,
row_base: u64 = 0,
text: std.Io.Writer.Allocating,
points: std.ArrayList(Coordinate) = .empty,

pub const Chunk = struct {
    text: []const u8,
    points: []const Coordinate,
    row_base: u64,
    start_y: u16,
};

pub fn init(screen: *Screen, alloc: Allocator) !Self {
    const top = screen.pages.getTopLeft(.screen);
    const bottom = screen.pages.getBottomRight(.screen) orelse return error.EmptySnapshot;
    return .{
        .alloc = alloc,
        .screen = screen,
        .iterator = top.pageIterator(.right_down, bottom),
        .top = top,
        .bottom = bottom,
        .text = .init(alloc),
    };
}

/// Rebind to independently owned pages after lazy capture, preserving the
/// physical row progress and trailing wrapped-line state of an active scan.
pub fn rebind(self: *Self, screen: *Screen) !void {
    if (self.screen == screen) return;
    self.screen = screen;
    self.top = screen.pages.getTopLeft(.screen);
    self.bottom = screen.pages.getBottomRight(.screen) orelse return error.EmptySnapshot;
    if (self.row_base >= screen.pages.total_rows) {
        self.iterator = .{};
    } else {
        const next_pin = screen.pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(self.row_base) } }) orelse
            return error.EmptySnapshot;
        self.iterator = next_pin.pageIterator(.right_down, self.bottom);
    }
}

test "snapshot text cursor rebind preserves progress across lazy capture" {
    const Terminal = @import("Terminal.zig");
    const snapshot = @import("PresentationSnapshot.zig");
    const testing = std.testing;
    const alloc = testing.allocator;
    var live = try Terminal.init(testing.io, alloc, .{
        .cols = 80,
        .rows = 2,
        .max_scrollback_bytes = null,
    });
    defer live.deinit(alloc);
    var stream = live.vtStream();
    defer stream.deinit();
    for (0..2000) |_| stream.nextSlice("a界e\u{301}b\r\n");
    const screen = live.screens.active;
    const expected = try screen.selectionString(alloc, .{
        .sel = .init(screen.pages.getTopLeft(.screen), screen.pages.getBottomRight(.screen).?, false),
        .trim = false,
    });
    defer alloc.free(expected);
    var cursor = try Self.init(screen, alloc);
    defer cursor.deinit();
    var actual: std.Io.Writer.Allocating = .init(alloc);
    defer actual.deinit();
    const first = (try cursor.next()).?;
    try actual.writer.writeAll(first.text);
    try testing.expect(cursor.row_base < screen.pages.total_rows);

    _ = live.compress(.full);
    var frozen = try snapshot.capture(alloc, testing.io, &live);
    defer frozen.deinit(alloc);
    try cursor.rebind(frozen.screens.active);
    live.fullReset();
    while (try cursor.next()) |chunk| try actual.writer.writeAll(chunk.text);
    try testing.expectEqualStrings(expected, actual.written());
    // Rebinding an exhausted cursor must not restart the scan.
    try cursor.rebind(screen);
    try testing.expectEqual(@as(?Chunk, null), try cursor.next());
    try cursor.rebind(frozen.screens.active);
    cursor.reset();
    try testing.expect((try cursor.next()) != null);
}

pub fn deinit(self: *Self) void {
    self.text.deinit();
    self.points.deinit(self.alloc);
}

pub fn reset(self: *Self) void {
    self.iterator = self.top.pageIterator(.right_down, self.bottom);
    self.trailing_state = null;
    self.row_base = 0;
    self.text.clearRetainingCapacity();
    self.points.clearRetainingCapacity();
}

pub fn next(self: *Self) !?Chunk {
    while (self.iterator.next()) |page| {
        self.text.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        const start_y = page.start;
        var preserved = try page.node.pagePreservingState(self.alloc);
        defer preserved.deinit();
        var f: formatter.PageFormatter = .init(preserved.page(), .{
            .emit = .plain,
            .unwrap = true,
            .trim = false,
        });
        f.start_y = page.start;
        f.end_y = page.end - 1;
        f.start_x = if (page.node == self.top.node) self.top.x else 0;
        f.end_x = if (page.node == self.bottom.node) self.bottom.x else null;
        f.trailing_state = self.trailing_state;
        f.point_map = .{ .alloc = self.alloc, .map = &self.points };
        self.trailing_state = try f.formatWithState(&self.text.writer);
        const chunk: Chunk = .{
            .text = self.text.written(),
            .points = self.points.items,
            .row_base = self.row_base,
            .start_y = start_y,
        };
        self.row_base += page.end - page.start;
        if (chunk.text.len != chunk.points.len) return error.SnapshotTextMapMismatch;
        if (chunk.text.len > 0) return chunk;
    }
    return null;
}
