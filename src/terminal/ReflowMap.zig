//! Sorted cell translation segments recorded by the existing reflow pass.
const Self = @This();
const std = @import("std");

pub const Cell = extern struct { x: u32, y: u64 };
pub const Segment = extern struct {
    old_row: u64,
    new_row: u64,
    old_column: u32,
    new_column: u32,
    count: u32,
    /// 1 for a contiguous run, 0 for collapsed padding/blank cells.
    step: u32,
};

alloc: std.mem.Allocator,
segments: std.ArrayList(Segment) = .empty,
row_offsets: []u32,
old_columns: u32,
new_columns: u32,
new_rows: u64 = 0,
source_row: usize = 0,
processed_rows: usize = 0,

pub fn init(alloc: std.mem.Allocator, rows: usize, old_columns: u32, new_columns: u32) !Self {
    const offsets = try alloc.alloc(u32, rows + 1);
    @memset(offsets, 0);
    return .{ .alloc = alloc, .row_offsets = offsets, .old_columns = old_columns, .new_columns = new_columns };
}

pub fn deinit(self: *Self) void {
    self.segments.deinit(self.alloc);
    self.alloc.free(self.row_offsets);
    self.* = undefined;
}

pub fn beginRow(self: *Self, row: usize) void {
    self.source_row = row;
    self.row_offsets[row] = @intCast(self.segments.items.len);
}

pub fn record(self: *Self, old_column: usize, new_row: usize, new_column: usize, count: usize, step: u32) std.mem.Allocator.Error!void {
    if (count == 0) return;
    if (self.segments.items.len > 0) {
        const last = &self.segments.items[self.segments.items.len - 1];
        if (last.old_row == self.source_row and last.new_row == new_row and last.step == step and
            last.old_column + last.count == old_column and
            last.new_column + last.count * step == new_column)
        {
            last.count += @intCast(count);
            return;
        }
    }
    // u32 offsets deliberately bound the representation, not the history rows.
    if (self.segments.items.len == std.math.maxInt(u32)) return error.OutOfMemory;
    try self.segments.append(self.alloc, .{
        .old_row = self.source_row,
        .new_row = new_row,
        .old_column = @intCast(old_column),
        .new_column = @intCast(new_column),
        .count = @intCast(count),
        .step = step,
    });
}

pub fn endRow(self: *Self) void {
    self.row_offsets[self.source_row + 1] = @intCast(self.segments.items.len);
    self.processed_rows = self.source_row + 1;
}

pub fn finish(self: *Self, rows: usize) std.mem.Allocator.Error!void {
    self.new_rows = rows;
    // A height reduction may trim blank source rows before column reflow.
    for (self.processed_rows..self.row_offsets.len - 1) |row| {
        self.beginRow(row);
        try self.record(0, rows -| 1, 0, self.old_columns, 0);
        self.endRow();
    }
    // Upstream drops trailing empty rows. Positions there resolve to the last
    // retained row, rather than pointing past the new screen.
    for (self.segments.items) |*segment| segment.new_row = @min(segment.new_row, rows -| 1);
}

pub fn translate(self: *const Self, cell: Cell) ?Cell {
    if (cell.y >= self.row_offsets.len - 1 or cell.x >= self.old_columns) return null;
    var lo: usize = self.row_offsets[@intCast(cell.y)];
    var hi: usize = self.row_offsets[@intCast(cell.y + 1)];
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const segment = self.segments.items[mid];
        if (cell.x < segment.old_column) {
            hi = mid;
        } else if (cell.x - segment.old_column >= segment.count) {
            lo = mid + 1;
        } else {
            return .{ .x = segment.new_column + (cell.x - segment.old_column) * segment.step, .y = segment.new_row };
        }
    }
    return null;
}

test "reflow map indexes split rows and collapsed padding" {
    var map = try Self.init(std.testing.allocator, 2, 12, 6);
    defer map.deinit();
    map.beginRow(0);
    try map.record(0, 0, 0, 6, 1);
    try map.record(6, 1, 0, 6, 1);
    map.endRow();
    map.beginRow(1);
    try map.record(0, 2, 0, 3, 1);
    try map.record(3, 2, 2, 9, 0);
    map.endRow();
    try map.finish(3);
    try std.testing.expectEqual(Cell{ .x = 4, .y = 1 }, map.translate(.{ .x = 10, .y = 0 }).?);
    try std.testing.expectEqual(Cell{ .x = 2, .y = 2 }, map.translate(.{ .x = 11, .y = 1 }).?);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, map.row_offsets);
    try std.testing.expect(map.translate(.{ .x = 12, .y = 0 }) == null);
}
