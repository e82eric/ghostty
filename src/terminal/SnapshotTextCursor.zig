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
        var f: formatter.PageFormatter = .init(page.node.page(), .{
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
