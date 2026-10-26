//! Presentation-only snapshot decorations, applied like an overlay pane: after
//! each render state update they rewrite the renderer's copy of the viewport
//! cells. The terminal and its text are never mutated, and the renderer draws
//! decorated cells and replacement text as ordinary cells.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Decorations = @import("SnapshotDecorations.zig");
const Self = @This();

value: ?Decorations = null,

/// Set when the decorations change. The old ones are baked into rows of the
/// render state, so every row has to be copied from the terminal again.
redraw: bool = false,

pub fn deinit(self: *Self) void {
    if (self.value) |*value| value.arena.deinit();
    self.* = .{};
}

pub fn replace(self: *Self, value: Decorations) void {
    if (self.value) |*old| old.arena.deinit();
    self.value = value;
    self.redraw = true;
}

/// Call with the terminal locked, before the render state update.
pub fn prepare(self: *Self, t: *terminal.Terminal) void {
    if (!self.redraw) return;
    self.redraw = false;
    t.flags.dirty.clear = true;
}

/// Call after the render state update. Only rows the update copied again
/// (marked dirty) have lost their decorations; the others keep them.
pub fn apply(self: *const Self, state: *terminal.RenderState) void {
    const value = self.value orelse return;
    if (value.layers.len == 0 and value.text.len == 0) return;
    const row_data = state.row_data.slice();
    const pins = row_data.items(.pin);
    const serials = row_data.items(.serial);
    const dirties = row_data.items(.dirty);
    const row_cells = row_data.items(.cells);
    const applied = row_data.items(.applied_styles);
    const viewport = state.viewportStart();
    const range = state.rowDataRange();
    for (range.start..range.end) |i| {
        if (!dirties[i]) continue;
        const cells = row_cells[i].slice();
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const y: ?u16 = if (i >= viewport and i < viewport + state.rows) @intCast(i - viewport) else null;
        var changed = false;

        // Earlier layers take priority, so apply them last.
        var layer_i = value.layers.len;
        while (layer_i > 0) {
            layer_i -= 1;
            const layer = value.layers[layer_i];
            if (layer.style.foreground == null and layer.style.background == null) continue;
            for (layer.ranges) |hl| {
                const span = rowSpan(hl, pins[i], serials[i], state.cols) orelse continue;
                for (span[0]..@as(usize, span[1]) + 1) |head| {
                    // A wide character's spacer follows its head, as in the
                    // renderer's highlight check.
                    if (raws[head].wide == .spacer_tail) continue;
                    const end = if (raws[head].wide == .wide) @min(head + 2, raws.len) else head + 1;
                    for (head..end) |x| {
                        // Replacement text uses the cell's own colors, not layers.
                        if (y) |row| if (self.textAt(@intCast(x), row) != null) continue;
                        var style = cellStyle(&raws[x], styles[x]);
                        decorate(&style, layer.style, &state.colors);
                        setStyle(&raws[x], &styles[x], style, x);
                        changed = true;
                    }
                }
            }
        }

        if (y) |row| for (self.textInRow(row)) |text| {
            const x = text.coord.x;
            if (x >= raws.len) continue;
            var style = cellStyle(&raws[x], styles[x]);
            decorate(&style, text.style, &state.colors);
            style.flags = .{
                .bold = text.bold,
                .underline = if (text.underline) .single else .none,
            };
            raws[x].content_tag = .codepoint;
            raws[x].content = .{ .codepoint = .{ .data = text.codepoint } };
            raws[x].wide = .narrow;
            setStyle(&raws[x], &styles[x], style, x);
            changed = true;
        };

        // The render state skips refilling styles that match this record.
        if (changed) applied[i].clearRetainingCapacity();
    }
}

/// The columns of `hl` in the row at `pin`, mirroring
/// `RenderState.updateHighlightsFlattened`.
fn rowSpan(
    hl: terminal.highlight.Flattened,
    pin: terminal.PageList.Pin,
    serial: u64,
    cols: terminal.size.CellCountInt,
) ?[2]terminal.size.CellCountInt {
    const chunks = hl.chunks.slice();
    const nodes = chunks.items(.node);
    const serials = chunks.items(.serial);
    const starts = chunks.items(.start);
    const ends = chunks.items(.end);
    for (0.., nodes) |i, node| {
        if (node != pin.node or
            serials[i] != serial or
            pin.y < starts[i] or
            pin.y >= ends[i]) continue;
        return .{
            if (i == 0 and pin.y == starts[0]) hl.top_x else 0,
            if (i == nodes.len - 1 and pin.y == ends[nodes.len - 1] - 1) hl.bot_x else cols - 1,
        };
    }
    return null;
}

/// The cell's style, moving a background-only cell's color into the style.
fn cellStyle(raw: *terminal.page.Cell, style: terminal.Style) terminal.Style {
    var result: terminal.Style = if (raw.hasStyling()) style else .{};
    switch (raw.content_tag) {
        .bg_color_palette => result.bg_color = .{ .palette = raw.content.color_palette.data },
        .bg_color_rgb => {
            const rgb = raw.content.color_rgb;
            result.bg_color = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
        },
        .codepoint, .codepoint_grapheme => return result,
    }
    raw.content_tag = .codepoint;
    raw.content = .{ .codepoint = .{ .data = 0 } };
    return result;
}

/// Override the colors a decoration sets. The others keep the cell's colors,
/// so an inverse cell is resolved first.
fn decorate(style: *terminal.Style, decoration: Decorations.Style, colors: *const terminal.RenderState.Colors) void {
    if (decoration.foreground == null and decoration.background == null) return;
    if (style.flags.inverse) {
        const fg = style.fg_color;
        style.fg_color = if (style.bg_color == .none) .{ .rgb = colors.background } else style.bg_color;
        style.bg_color = if (fg == .none) .{ .rgb = colors.foreground } else fg;
        style.flags.inverse = false;
    }
    if (decoration.foreground) |rgb| style.fg_color = .{ .rgb = rgb };
    if (decoration.background) |rgb| style.bg_color = .{ .rgb = rgb };
}

fn setStyle(raw: *terminal.page.Cell, dst: *terminal.Style, style: terminal.Style, x: usize) void {
    // Any non-default ID makes the renderer read the style. Text shaping
    // treats equal neighboring IDs as equal styles, so alternate them.
    raw.style_id = std.math.maxInt(@TypeOf(raw.style_id)) - @as(@TypeOf(raw.style_id), @intCast(x & 1));
    dst.* = style;
}

/// Replacement text in viewport row `y`, sorted by column.
fn textInRow(self: *const Self, y: u16) []const Decorations.Text {
    const value = self.value orelse return &.{};
    const start = lowerBound(value.text, .{ .x = 0, .y = y });
    var end = start;
    while (end < value.text.len and value.text[end].coord.y == y) end += 1;
    return value.text[start..end];
}

fn textAt(self: *const Self, x: u16, y: u16) ?Decorations.Text {
    const value = self.value orelse return null;
    const i = lowerBound(value.text, .{ .x = x, .y = y });
    if (i < value.text.len and value.text[i].coord.x == x and value.text[i].coord.y == y)
        return value.text[i];
    return null;
}

fn lowerBound(text: []const Decorations.Text, coord: terminal.Coordinate) usize {
    var lo: usize = 0;
    var hi = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = text[mid].coord;
        if (c.y < coord.y or (c.y == coord.y and c.x < coord.x)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn caret(self: *const Self) ?Decorations.Caret {
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

const TestState = struct {
    t: terminal.Terminal,
    state: terminal.RenderState = .empty,

    fn init(text: []const u8) !TestState {
        var result: TestState = .{ .t = try .init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 2 }) };
        var s = result.t.vtStream();
        defer s.deinit();
        s.nextSlice(text);
        return result;
    }

    fn deinit(self: *TestState) void {
        self.state.deinit(std.testing.allocator);
        self.t.deinit(std.testing.allocator);
    }

    fn update(self: *TestState, overrides: *Self) !void {
        overrides.prepare(&self.t);
        try self.state.update(std.testing.allocator, &self.t);
        overrides.apply(&self.state);
        @memset(self.state.row_data.items(.dirty), false);
    }

    fn cell(self: *TestState, x: usize, y: usize) terminal.RenderState.Cell {
        const row = self.state.row_data.items(.cells)[self.state.viewportStart() + y];
        return row.get(x);
    }

    fn highlight(self: *TestState, arena: std.mem.Allocator, x0: u16, x1: u16, y: u16) !terminal.highlight.Flattened {
        const pages = &self.t.screens.active.pages;
        return terminal.highlight.Flattened.init(
            arena,
            pages.pin(.{ .viewport = .{ .x = x0, .y = y } }).?,
            pages.pin(.{ .viewport = .{ .x = x1, .y = y } }).?,
        );
    }
};

test "SnapshotOverrides replaces text in the render state only" {
    var ts: TestState = try .init("hello");
    defer ts.deinit();
    var overrides: Self = .{};
    defer overrides.deinit();
    const gold: terminal.color.RGB = .{ .r = 215, .g = 153, .b = 33 };
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
        .text = &.{.{ .coord = .{ .x = 1, .y = 0 }, .codepoint = 'A', .style = .{ .foreground = gold }, .bold = true, .underline = true }},
    });
    try ts.update(&overrides);

    const label = ts.cell(1, 0);
    try std.testing.expectEqual(@as(u21, 'A'), label.raw.codepoint());
    try std.testing.expect(label.raw.hasStyling());
    try std.testing.expect(label.style.flags.bold);
    try std.testing.expectEqual(.single, label.style.flags.underline);
    try std.testing.expect(label.style.fg_color.eql(.{ .rgb = gold }));
    try std.testing.expectEqual(@as(u21, 'h'), ts.cell(0, 0).raw.codepoint());
    try std.testing.expect(!ts.cell(0, 0).raw.hasStyling());

    // The terminal itself is untouched.
    const pages = &ts.t.screens.active.pages;
    try std.testing.expectEqual(@as(u21, 'e'), pages.pin(.{ .viewport = .{ .x = 1, .y = 0 } }).?.rowAndCell().cell.codepoint());

    // Unchanged rows keep the label across updates that don't copy them.
    try ts.update(&overrides);
    try std.testing.expectEqual(@as(u21, 'A'), ts.cell(1, 0).raw.codepoint());

    // Removing the label restores the original cell.
    overrides.replace(.{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .layers = &.{} });
    try ts.update(&overrides);
    try std.testing.expectEqual(@as(u21, 'e'), ts.cell(1, 0).raw.codepoint());
    try std.testing.expect(!ts.cell(1, 0).raw.hasStyling());
}

test "SnapshotOverrides earlier layers take priority and resolve inverse" {
    var ts: TestState = try .init("\x1b[7mhello\x1b[0m");
    defer ts.deinit();
    var overrides: Self = .{};
    defer overrides.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const red: terminal.color.RGB = .{ .r = 255, .g = 0, .b = 0 };
    const blue: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 255 };
    const layers = try arena.allocator().dupe(Decorations.Layer, &.{
        .{ .style = .{ .background = red }, .ranges = try arena.allocator().dupe(terminal.highlight.Flattened, &.{try ts.highlight(arena.allocator(), 1, 1, 0)}) },
        .{ .style = .{ .background = blue }, .ranges = try arena.allocator().dupe(terminal.highlight.Flattened, &.{try ts.highlight(arena.allocator(), 1, 2, 0)}) },
    });
    overrides.replace(.{ .arena = arena, .layers = layers });
    try ts.update(&overrides);

    const first = ts.cell(1, 0);
    try std.testing.expect(first.style.bg_color.eql(.{ .rgb = red }));
    try std.testing.expect(!first.style.flags.inverse);
    // The inverse cell's foreground is the default background.
    try std.testing.expect(first.style.fg_color.eql(.{ .rgb = ts.state.colors.background }));
    try std.testing.expect(ts.cell(2, 0).style.bg_color.eql(.{ .rgb = blue }));
    try std.testing.expect(ts.cell(3, 0).style.flags.inverse);
    // Neighboring decorated cells never share a style ID.
    try std.testing.expect(first.raw.style_id != ts.cell(2, 0).raw.style_id);
}

test "SnapshotOverrides layers cover wide characters by their head" {
    // "a", wide "中" at columns 1-2, "b", and "é" as a grapheme at column 4.
    var ts: TestState = try .init("a中be\u{301}");
    defer ts.deinit();
    var overrides: Self = .{};
    defer overrides.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const red: terminal.color.RGB = .{ .r = 255, .g = 0, .b = 0 };
    const blue: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 255 };
    const layers = try arena.allocator().dupe(Decorations.Layer, &.{
        // Ends on the wide head, so its spacer is included.
        .{ .style = .{ .background = red }, .ranges = try arena.allocator().dupe(terminal.highlight.Flattened, &.{try ts.highlight(arena.allocator(), 0, 1, 0)}) },
        // Starts on the spacer, so only the following cells are covered.
        .{ .style = .{ .background = blue }, .ranges = try arena.allocator().dupe(terminal.highlight.Flattened, &.{try ts.highlight(arena.allocator(), 2, 4, 0)}) },
    });
    overrides.replace(.{ .arena = arena, .layers = layers });
    try ts.update(&overrides);

    try std.testing.expectEqual(.wide, ts.cell(1, 0).raw.wide);
    try std.testing.expectEqual(.spacer_tail, ts.cell(2, 0).raw.wide);
    try std.testing.expect(ts.cell(1, 0).style.bg_color.eql(.{ .rgb = red }));
    try std.testing.expect(ts.cell(2, 0).style.bg_color.eql(.{ .rgb = red }));
    try std.testing.expect(ts.cell(3, 0).style.bg_color.eql(.{ .rgb = blue }));
    // Decorating keeps the cell's text, including combining marks.
    const accent = ts.cell(4, 0);
    try std.testing.expect(accent.style.bg_color.eql(.{ .rgb = blue }));
    try std.testing.expectEqual(.codepoint_grapheme, accent.raw.content_tag);
    try std.testing.expectEqualSlices(u21, &.{0x301}, accent.grapheme);
}

test "SnapshotOverrides text replaces graphemes and wide characters" {
    var ts: TestState = try .init("中e\u{301}");
    defer ts.deinit();
    var overrides: Self = .{};
    defer overrides.deinit();
    overrides.replace(.{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layers = &.{},
        .text = &.{
            .{ .coord = .{ .x = 0, .y = 0 }, .codepoint = 'A', .style = .{} },
            .{ .coord = .{ .x = 2, .y = 0 }, .codepoint = 'S', .style = .{} },
        },
    });
    try ts.update(&overrides);

    try std.testing.expectEqual(@as(u21, 'A'), ts.cell(0, 0).raw.codepoint());
    try std.testing.expectEqual(.narrow, ts.cell(0, 0).raw.wide);
    try std.testing.expectEqual(.spacer_tail, ts.cell(1, 0).raw.wide);
    try std.testing.expectEqual(@as(u21, 'S'), ts.cell(2, 0).raw.codepoint());
    try std.testing.expectEqual(.codepoint, ts.cell(2, 0).raw.content_tag);

    // Removing the labels restores the original characters.
    overrides.replace(.{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .layers = &.{} });
    try ts.update(&overrides);
    try std.testing.expectEqual(@as(u21, 0x4e2d), ts.cell(0, 0).raw.codepoint());
    try std.testing.expectEqual(.wide, ts.cell(0, 0).raw.wide);
    try std.testing.expectEqual(.codepoint_grapheme, ts.cell(2, 0).raw.content_tag);
    try std.testing.expectEqualSlices(u21, &.{0x301}, ts.cell(2, 0).grapheme);
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
