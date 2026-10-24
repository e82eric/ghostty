//! Presentation-only snapshot decorations. The terminal and its text are never
//! mutated. The renderer supplies its normal cell drawing machinery.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Self = @This();

value: ?@import("SnapshotDecorations.zig") = null,
highlights_dirty: bool = false,
glyphs_dirty: bool = false,

pub fn deinit(self: *Self) void {
    if (self.value) |*value| value.arena.deinit();
    self.* = .{};
}

pub fn replace(self: *Self, value: @import("SnapshotDecorations.zig")) void {
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

pub fn styleForTag(self: *const Self, tag: u8) ?@import("SnapshotDecorations.zig").Style {
    if (tag < 2) return null;
    const value = self.value orelse return null;
    const index = tag - 2;
    if (index >= value.layers.len) return null;
    return value.layers[index].style;
}

pub fn caret(self: *const Self) ?@import("SnapshotDecorations.zig").Caret {
    const value = self.value orelse return null;
    return value.caret;
}

/// Report the caret to custom shaders as a full-cell block cursor. Positions
/// use the renderer's cursor glyph convention: the cursor's +Y edge.
pub fn updateCaretUniforms(self: *const Self, uniforms: anytype, size: anytype, y_is_down: bool, colors: anytype) void {
    const value = self.caret() orelse return;
    const cell = size.cell;
    const pixel_x: f32 = @floatFromInt(@as(u32, value.coord.x) * cell.width + size.padding.left);
    const top: f32 = @floatFromInt(@as(u32, value.coord.y) * cell.height + size.padding.top);
    const cell_height: f32 = @floatFromInt(cell.height);
    const pixel_y = if (y_is_down) top + cell_height else @as(f32, @floatFromInt(size.screen.height)) - top;
    const color = value.color orelse colors.cursor orelse colors.foreground;
    const new_cursor: [4]f32 = .{ pixel_x, pixel_y, @floatFromInt(cell.width), cell_height };
    const cursor_color: [4]f32 = .{
        @as(f32, @floatFromInt(color.r)) / 255.0,
        @as(f32, @floatFromInt(color.g)) / 255.0,
        @as(f32, @floatFromInt(color.b)) / 255.0,
        1.0,
    };
    uniforms.cursor_visible = 1;
    if (std.meta.eql(new_cursor, uniforms.current_cursor) and
        std.meta.eql(cursor_color, uniforms.current_cursor_color)) return;
    uniforms.previous_cursor = uniforms.current_cursor;
    uniforms.previous_cursor_color = uniforms.current_cursor_color;
    uniforms.current_cursor = new_cursor;
    uniforms.current_cursor_color = cursor_color;
    uniforms.cursor_change_time = uniforms.time;
}

pub fn textAt(self: *const Self, x: u16, y: u16) ?@import("SnapshotDecorations.zig").Text {
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
pub fn drawText(r: anytype, text: @import("SnapshotDecorations.zig").Text, color: terminal.color.RGB) !void {
    if (text.underline) {
        const font = @import("../font/main.zig");
        const line = try r.font_grid.renderGlyph(r.alloc, font.sprite_index, @intFromEnum(font.Sprite.underline), .{
            .cell_width = 1,
            .grid_metrics = r.grid_metrics,
        });
        try r.cells.add(r.alloc, .underline, .{
            .atlas = .grayscale,
            .grid_pos = .{ text.coord.x, @intCast(text.coord.y) },
            .color = .{ color.r, color.g, color.b, 255 },
            .glyph_pos = .{ line.glyph.atlas_x, line.glyph.atlas_y },
            .glyph_size = .{ line.glyph.width, line.glyph.height },
            .bearings = .{ @intCast(line.glyph.offset_x), @intCast(line.glyph.offset_y) },
        });
    }
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
    const text: @import("SnapshotDecorations.zig").Text = .{
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
    const style: @import("SnapshotDecorations.zig").Style = .{ .foreground = .{ .r = 215, .g = 153, .b = 33 } };
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

test "SnapshotOverrides caret uniforms report a block cursor and track moves" {
    var overrides: Self = .{};
    defer overrides.deinit();
    const RGB = terminal.color.RGB;
    const colors: struct { cursor: ?RGB = null, foreground: RGB = .{ .r = 255, .g = 255, .b = 255 } } = .{};
    const size = .{
        .cell = .{ .width = @as(u32, 10), .height = @as(u32, 20) },
        .padding = .{ .left = @as(u32, 5), .top = @as(u32, 3) },
        .screen = .{ .height = @as(u32, 200) },
    };
    var uniforms: struct {
        time: f32 = 4,
        cursor_visible: i32 = 0,
        current_cursor: [4]f32 = @splat(0),
        previous_cursor: [4]f32 = @splat(0),
        current_cursor_color: [4]f32 = @splat(0),
        previous_cursor_color: [4]f32 = @splat(0),
        cursor_change_time: f32 = 0,
    } = .{};

    // No caret leaves the uniforms untouched.
    overrides.updateCaretUniforms(&uniforms, size, true, &colors);
    try std.testing.expectEqual(@as(i32, 0), uniforms.cursor_visible);

    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
        .caret = .{ .coord = .{ .x = 2, .y = 1 }, .color = .{ .r = 255, .g = 0, .b = 0 } },
    });
    overrides.updateCaretUniforms(&uniforms, size, true, &colors);
    try std.testing.expectEqual(@as(i32, 1), uniforms.cursor_visible);
    try std.testing.expectEqual([4]f32{ 25, 43, 10, 20 }, uniforms.current_cursor);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, uniforms.current_cursor_color);
    try std.testing.expectEqual(@as(f32, 4), uniforms.cursor_change_time);

    // +Y up measures the top edge from the bottom of the screen.
    uniforms.time = 5;
    overrides.updateCaretUniforms(&uniforms, size, false, &colors);
    try std.testing.expectEqual([4]f32{ 25, 177, 10, 20 }, uniforms.current_cursor);
    try std.testing.expectEqual([4]f32{ 25, 43, 10, 20 }, uniforms.previous_cursor);
    try std.testing.expectEqual(@as(f32, 5), uniforms.cursor_change_time);

    // An unchanged caret keeps the previous change time.
    uniforms.time = 6;
    overrides.updateCaretUniforms(&uniforms, size, false, &colors);
    try std.testing.expectEqual(@as(f32, 5), uniforms.cursor_change_time);
}
