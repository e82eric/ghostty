//! Page-sized, on-demand byte-to-pin mapping for exported snapshot text.
//! The search worker owns the flat UTF-8 text; this only retains page
//! boundaries. A point map is materialized for one frozen page at a time.
const SnapshotTextIndex = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const formatter = @import("formatter.zig");
const Coordinate = @import("point.zig").Coordinate;

const PageEntry = struct {
    start_byte: usize,
    end_byte: usize,
    row_base: u64,
    node: *PageList.List.Node,
    start_y: u16,
    end_y: u16,
    start_x: u16,
    end_x: ?u16,
    trailing_state: ?formatter.PageFormatter.TrailingState,

    fn rowCount(self: PageEntry) u64 {
        return @as(u64, self.end_y) - self.start_y + 1;
    }
};

alloc: Allocator,
pages: []PageEntry,
text_len: usize,
cached_page: ?usize = null,
cached_points: std.ArrayList(Coordinate) = .empty,

pub const Export = struct {
    index: SnapshotTextIndex,
    text: [:0]const u8,
};

pub const ByteRange = struct { start: usize, end: usize };

pub fn build(screen: *Screen, alloc: Allocator) !Export {
    const pages = &screen.pages;
    const tl = pages.getTopLeft(.screen);
    const br = pages.getBottomRight(.screen) orelse return error.EmptySnapshot;

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    var entries: std.ArrayList(PageEntry) = .empty;
    errdefer entries.deinit(alloc);

    var trailing_state: ?formatter.PageFormatter.TrailingState = null;
    var row_base: u64 = 0;
    var iter = tl.pageIterator(.right_down, br);
    while (iter.next()) |chunk| {
        const start_byte = text.written().len;
        const start_x = if (chunk.node == tl.node) tl.x else 0;
        const end_x: ?u16 = if (chunk.node == br.node) br.x else null;
        var page_formatter: formatter.PageFormatter = .init(chunk.node.page(), .{
            .emit = .plain,
            .unwrap = true,
            .trim = false,
        });
        page_formatter.start_y = chunk.start;
        page_formatter.end_y = chunk.end - 1;
        page_formatter.start_x = start_x;
        page_formatter.end_x = end_x;
        page_formatter.trailing_state = trailing_state;
        trailing_state = try page_formatter.formatWithState(&text.writer);
        try entries.append(alloc, .{
            .start_byte = start_byte,
            .end_byte = text.written().len,
            .row_base = row_base,
            .node = chunk.node,
            .start_y = chunk.start,
            .end_y = chunk.end - 1,
            .start_x = start_x,
            .end_x = end_x,
            .trailing_state = page_formatter.trailing_state,
        });
        row_base += chunk.end - chunk.start;
    }

    const owned_text = try text.toOwnedSliceSentinel(0);
    errdefer alloc.free(owned_text);
    return .{
        .index = .{
            .alloc = alloc,
            .pages = try entries.toOwnedSlice(alloc),
            .text_len = owned_text.len,
        },
        .text = owned_text,
    };
}

pub fn deinit(self: *SnapshotTextIndex, alloc: Allocator) void {
    self.cached_points.deinit(alloc);
    alloc.free(self.pages);
}

fn loadPage(self: *SnapshotTextIndex, page_index: usize) !void {
    if (self.cached_page == page_index) return;
    const entry = self.pages[page_index];
    self.cached_page = null;
    self.cached_points.clearRetainingCapacity();
    var text: std.Io.Writer.Allocating = .init(self.alloc);
    defer text.deinit();
    var page_formatter: formatter.PageFormatter = .init(entry.node.page(), .{
        .emit = .plain,
        .unwrap = true,
        .trim = false,
    });
    page_formatter.start_y = entry.start_y;
    page_formatter.end_y = entry.end_y;
    page_formatter.start_x = entry.start_x;
    page_formatter.end_x = entry.end_x;
    page_formatter.trailing_state = entry.trailing_state;
    page_formatter.point_map = .{ .alloc = self.alloc, .map = &self.cached_points };
    _ = try page_formatter.formatWithState(&text.writer);
    if (self.cached_points.items.len != entry.end_byte - entry.start_byte or
        text.written().len != self.cached_points.items.len)
        return error.SnapshotTextMapMismatch;
    self.cached_page = page_index;
}

pub fn pinAt(self: *SnapshotTextIndex, offset: usize) ?PageList.Pin {
    if (offset >= self.text_len) return null;
    var lo: usize = 0;
    var hi: usize = self.pages.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.pages[mid].end_byte <= offset) lo = mid + 1 else hi = mid;
    }
    if (lo == self.pages.len) return null;
    self.loadPage(lo) catch return null;
    const entry = self.pages[lo];
    const point = self.cached_points.items[offset - entry.start_byte];
    return .{
        .node = entry.node,
        .x = std.math.cast(u16, point.x) orelse return null,
        .y = std.math.cast(u16, point.y) orelse return null,
    };
}

pub fn viewportBytes(self: *SnapshotTextIndex, screen: *Screen) ?ByteRange {
    const pages = &screen.pages;
    const top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const bottom_pin = pages.getBottomRight(.viewport) orelse return null;
    const bottom = pages.pointFromPin(.screen, bottom_pin) orelse return null;
    const start = self.firstByteAtRow(@intCast(top.screen.y)) orelse return null;
    const end = self.firstByteAtRow(@as(u64, @intCast(bottom.screen.y)) + 1) orelse return null;
    return .{ .start = start, .end = end };
}

fn firstByteAtRow(self: *SnapshotTextIndex, row: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = self.pages.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = self.pages[mid];
        if (entry.row_base + entry.rowCount() <= row) lo = mid + 1 else hi = mid;
    }
    for (lo..self.pages.len) |i| {
        const entry = self.pages[i];
        self.loadPage(i) catch return null;
        const local_row = if (row > entry.row_base) row - entry.row_base else 0;
        for (self.cached_points.items, 0..) |point, j| {
            if (point.y >= @as(u64, entry.start_y) + local_row)
                return entry.start_byte + j;
        }
    }
    return self.text_len;
}
