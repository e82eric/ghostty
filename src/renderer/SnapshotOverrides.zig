//! Presentation-only snapshot decorations. The terminal and its text are never
//! mutated. The renderer supplies its normal cell drawing machinery.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Message = @import("message.zig").Message;
const Self = @This();

value: ?Message.SnapshotDecorations = null,
highlights_dirty: bool = false,
glyphs_dirty: bool = false,

pub fn deinit(self: *Self) void {
    if (self.value) |*value| value.arena.deinit();
    self.* = .{};
}

pub fn replace(self: *Self, value: Message.SnapshotDecorations) void {
    const old_text = if (self.value) |old| old.text.len else 0;
    self.glyphs_dirty = self.glyphs_dirty or old_text > 0 or value.text.len > 0;
    if (self.value) |*old| old.arena.deinit();
    self.value = value;
    self.highlights_dirty = true;
}

/// Keep full invalidation for text replacement, including removal of labels.
pub fn invalidate(self: *Self, state: anytype) void {
    if (self.glyphs_dirty) {
        self.glyphs_dirty = false;
        state.dirty = .full;
    }
}

/// Tags 0 and 1 remain reserved for upstream search highlights.
pub fn updateHighlights(self: *Self, alloc: std.mem.Allocator, state: anytype) void {
    self.highlights_dirty = false;
    const value = self.value orelse return;
    for (value.layers, 0..) |layer, index| {
        state.updateHighlightsFlattened(alloc, @intCast(index + 2), layer.ranges) catch |err| {
            std.log.scoped(.snapshot_overrides).warn("error updating snapshot decoration err={}", .{err});
        };
    }
}

pub fn styleForTag(self: *const Self, tag: u8) ?Message.DecorationStyle {
    if (tag < 2) return null;
    const value = self.value orelse return null;
    const index = tag - 2;
    if (index >= value.layers.len) return null;
    return value.layers[index].style;
}

pub fn textAt(self: *const Self, x: u16, y: u16) ?Message.DecorationText {
    const value = self.value orelse return null;
    var lo: usize = 0;
    var hi = value.text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const coord = value.text[mid].coord;
        if (coord.y < y or (coord.y == y and coord.x < x)) lo = mid + 1 else hi = mid;
    }
    if (lo < value.text.len and value.text[lo].coord.x == x and value.text[lo].coord.y == y)
        return value.text[lo];
    return null;
}

/// Use the renderer's font atlas and GPU cell buffers for replacement glyphs.
pub fn drawText(r: anytype, text: Message.DecorationText, color: terminal.color.RGB) !void {
    const render = (try r.font_grid.renderCodepoint(r.alloc, text.codepoint, if (text.bold) .bold else .regular, .text, .{
        .cell_width = 1,
        .grid_metrics = r.grid_metrics,
        .thicken = r.config.font_thicken,
        .thicken_strength = r.config.font_thicken_strength,
    })) orelse return;
    try r.cells.add(r.alloc, .text, .{
        .atlas = .grayscale,
        .grid_pos = .{ text.coord.x, @intCast(text.coord.y) },
        .color = .{ color.r, color.g, color.b, 255 },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{ @intCast(render.glyph.offset_x), @intCast(render.glyph.offset_y) },
    });
}

test "SnapshotOverrides removing text invalidates glyphs but ranges alone do not" {
    var overrides: Self = .{};
    defer overrides.deinit();
    const text: Message.DecorationText = .{
        .coord = .{ .x = 2, .y = 3 },
        .codepoint = 'A',
        .style = .{},
    };
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
        .text = &.{text},
    });
    const Dirty = enum { false, partial, full };
    var state: struct { dirty: Dirty = .false } = .{};
    overrides.invalidate(&state);
    try std.testing.expectEqual(Dirty.full, state.dirty);
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
    });
    state.dirty = .false;
    overrides.invalidate(&state);
    try std.testing.expectEqual(Dirty.full, state.dirty);
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
    });
    state.dirty = .false;
    overrides.invalidate(&state);
    try std.testing.expectEqual(Dirty.false, state.dirty);
    try std.testing.expect(overrides.highlights_dirty);
}

test "SnapshotOverrides lookup preserves upstream tags and exact cell positions" {
    var overrides: Self = .{};
    defer overrides.deinit();
    const style: Message.DecorationStyle = .{ .foreground = .{ .r = 215, .g = 153, .b = 33 } };
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{.{ .style = style, .ranges = &.{} }},
        .text = &.{
            .{ .coord = .{ .x = 4, .y = 1 }, .codepoint = 'A', .style = style, .bold = true },
            .{ .coord = .{ .x = 0, .y = 2 }, .codepoint = 'S', .style = style },
        },
    });
    try std.testing.expect(overrides.styleForTag(0) == null);
    try std.testing.expect(overrides.styleForTag(1) == null);
    try std.testing.expectEqualDeep(style, overrides.styleForTag(2).?);
    try std.testing.expect(overrides.styleForTag(3) == null);
    try std.testing.expect(overrides.textAt(3, 1) == null);
    try std.testing.expectEqual(@as(u21, 'A'), overrides.textAt(4, 1).?.codepoint);
    try std.testing.expect(overrides.textAt(4, 1).?.bold);
    try std.testing.expectEqual(@as(u21, 'S'), overrides.textAt(0, 2).?.codepoint);
    try std.testing.expect(overrides.textAt(1, 2) == null);
}
