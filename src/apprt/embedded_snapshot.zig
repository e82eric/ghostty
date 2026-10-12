//! Frozen terminal C APIs used by the host's modal navigation and previews.
const std = @import("std");
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Surface = @import("embedded.zig").Surface;
const log = std.log.scoped(.embedded_window);

export fn ghostty_surface_snapshot_logical_position(surface: *Surface, generation: u64, cell: terminal.SnapshotLogicalPosition.Cell, result: *terminal.SnapshotLogicalPosition.Position) bool {
    const core = surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    if (core.snapshot.generation != generation) return false;
    const t = core.snapshot.terminal orelse return false;
    result.* = terminal.SnapshotLogicalPosition.fromCell(global.alloc(), t, cell) catch return false;
    return true;
}

export fn ghostty_surface_snapshot_resolve_logical_range(surface: *Surface, generation: u64, range: terminal.SnapshotLogicalPosition.Range, result: *terminal.SnapshotLogicalPosition.CellRange) bool {
    const core = surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    if (core.snapshot.generation != generation) return false;
    const t = core.snapshot.terminal orelse return false;
    result.* = terminal.SnapshotLogicalPosition.resolve(global.alloc(), t, range) catch return false;
    return true;
}

const SnapshotStyleRun = terminal.SnapshotStyleRuns.Run;
const SnapshotStyleRuns = extern struct { runs: ?[*]SnapshotStyleRun, len: usize };

/// Read resolved styles once while loading the Rust-owned document. Runs use
/// physical source columns; UINT32_MAX means the preview's default color.
export fn ghostty_surface_snapshot_style_runs(surface: *Surface, generation: u64, row: u64, result: *SnapshotStyleRuns) bool {
    result.* = .{ .runs = null, .len = 0 };
    const core = surface.core_surface;
    const state = &core.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (core.snapshot.generation != generation) return false;
    const t = core.snapshot.terminal orelse return false;
    const screen = t.screens.active;
    const anchor: ?SnapshotAnchor = if (core.snapshot.text_row_anchor) |a|
        .{ .pin = a.pin, .row = a.row }
    else
        snapshotViewportAnchor(screen);
    const pin = snapshotCellPin(screen, .{ .x = 0, .y = row }, anchor) orelse return false;
    const owned = terminal.SnapshotStyleRuns.capture(global.alloc(), t, pin) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    result.* = .{ .runs = owned.ptr, .len = owned.len };
    return true;
}
export fn ghostty_snapshot_style_runs_free(result: *SnapshotStyleRuns) void {
    if (result.runs) |ptr| global.alloc().free(ptr[0..result.len]);
    result.* = .{ .runs = null, .len = 0 };
}

// ghostty_snapshot_text_chunk_s
const SnapshotTextChunk = extern struct {
    text: ?[*]const u8,
    points: ?[*]const terminal.Coordinate,
    len: usize,
    row_base: u64,
    start_y: u16,
};

const SnapshotTextRow = extern struct {
    text: ?[*]const u8,
    columns: ?[*]const u32,
    len: usize,
    wraps_to_next: bool,
};

const SnapshotTextCursor = struct {
    surface: *Surface,
    generation: u64,
    cursor: terminal.SnapshotTextCursor,
};

const SnapshotCell = terminal.SnapshotReflow.Cell;
const SnapshotCellRange = extern struct { start: SnapshotCell, end: SnapshotCell };
const SnapshotSelectionText = extern struct { text: ?[*]const u8, len: usize };
const SnapshotView = extern struct {
    cursor: SnapshotCell,
    viewport_top: u64,
    total_rows: u64,
    viewport_rows: u32,
    columns: u32,
};
const SnapshotDecorationStyle = extern struct {
    foreground_rgb: u32,
    background_rgb: u32,
    flags: u32,

    fn toCore(self: SnapshotDecorationStyle) @import("../renderer/SnapshotDecorations.zig").Style {
        return .{
            .foreground = if (self.flags & 1 != 0) snapshotRgb(self.foreground_rgb) else null,
            .background = if (self.flags & 2 != 0) snapshotRgb(self.background_rgb) else null,
        };
    }
};
const SnapshotDecorationLayer = extern struct {
    ranges: ?[*]const SnapshotCellRange,
    range_count: usize,
    style: SnapshotDecorationStyle,
};
const SnapshotCellText = extern struct {
    cell: SnapshotCell,
    codepoint: u32,
    style: SnapshotDecorationStyle,
    bold: bool,
};

const SnapshotAnchor = struct { pin: terminal.PageList.Pin, row: u64 };

fn snapshotCellPin(
    screen: *terminal.Screen,
    cell: SnapshotCell,
    anchor: ?SnapshotAnchor,
) ?terminal.PageList.Pin {
    if (cell.y >= screen.pages.total_rows) return null;
    const x = std.math.cast(u16, cell.x) orelse return null;
    var p: terminal.PageList.Pin = (if (anchor) |a| blk: {
        const delta = if (cell.y >= a.row) cell.y - a.row else a.row - cell.y;
        const steps = std.math.cast(usize, delta) orelse return null;
        break :blk if (cell.y >= a.row) a.pin.down(steps) else a.pin.up(steps);
    } else screen.pages.pin(.{ .screen = .{
        .x = 0,
        .y = std.math.cast(u32, cell.y) orelse return null,
    } })) orelse return null;
    if (x >= p.node.cols()) return null;
    p.x = x;
    return p;
}

fn snapshotCellSelection(
    screen: *terminal.Screen,
    range: SnapshotCellRange,
    anchor: ?SnapshotAnchor,
) ?terminal.Selection {
    const a = snapshotCellPin(screen, range.start, anchor) orelse return null;
    const b = snapshotCellPin(screen, range.end, anchor) orelse return null;
    if (b.before(a)) return null;
    return .init(a, b, false);
}

fn snapshotViewportRows(screen: *terminal.Screen) ?@import("../surface/Snapshot.zig").Viewport {
    const pages = &screen.pages;
    const top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const bottom = pages.pointFromPin(.screen, pages.getBottomRight(.viewport) orelse return null) orelse return null;
    return .{ .start = top.screen.y, .end = @as(usize, bottom.screen.y) + 1 };
}

fn snapshotViewportAnchor(screen: *terminal.Screen) ?SnapshotAnchor {
    const rows = snapshotViewportRows(screen) orelse return null;
    return .{ .pin = screen.pages.getTopLeft(.viewport), .row = rows.start };
}

// The map owns numeric coordinates, never terminal pages. Rust stops snapshot
// readers before resize and uses this result to translate all retained cells.
const ReflowMap = terminal.SnapshotReflow.Map;
const SnapshotReflowMap = extern struct {
    handle: ?*ReflowMap = null,
    segments: ?[*]const ReflowMap.Segment = null,
    segment_count: usize = 0,
    row_offsets: ?[*]const u32 = null,
    old_rows: u64 = 0,
    new_rows: u64 = 0,
    old_columns: u32 = 0,
    new_columns: u32 = 0,
};

export fn ghostty_snapshot_reflow_map_free(result: *SnapshotReflowMap) void {
    if (result.handle) |map| {
        const alloc = map.alloc;
        map.deinit();
        alloc.destroy(map);
    }
    result.* = .{};
}

export fn ghostty_surface_snapshot_resize(surface: *Surface, generation: u64, result: *SnapshotReflowMap) bool {
    result.* = .{};
    @import("../c_api_error.zig").clear();
    const core = &surface.core_surface;
    const state = &core.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (core.snapshot.generation != generation) return false;
    const t = core.snapshot.terminal orelse return false;
    const map = core.alloc.create(ReflowMap) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    const grid = core.size.grid();
    // Flattened decorations and row caches refer to the old pages.
    const arena = std.heap.ArenaAllocator.init(core.alloc);
    _ = core.renderer_thread.mailbox.push(global.io(), .{
        .snapshot_decorations = .{ .arena = arena, .layers = &.{} },
    }, .{ .forever = {} });
    core.snapshot.decoration_viewport = null;
    core.snapshot.text_row_anchor = null;
    map.* = terminal.SnapshotReflow.resizeMapped(core.alloc, t, grid.columns, grid.rows) catch |err| {
        core.alloc.destroy(map);
        @import("../c_api_error.zig").set(err);
        return false;
    };
    result.* = .{
        .handle = map,
        .segments = map.segments.items.ptr,
        .segment_count = map.segments.items.len,
        .row_offsets = map.row_offsets.ptr,
        .old_rows = map.row_offsets.len - 1,
        .new_rows = map.new_rows,
        .old_columns = map.old_columns,
        .new_columns = map.new_columns,
    };
    core.renderer_thread.wakeup.notify() catch {};
    return true;
}

export fn ghostty_surface_snapshot_view(
    surface: *Surface,
    generation: u64,
    result: *SnapshotView,
) bool {
    @import("../c_api_error.zig").clear();
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = state.presentation_terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    const screen = t.screens.active;
    const document = surface.core_surface.snapshot.terminal.?;
    const original = document.screens.active;
    const point = original.pages.pointFromPin(.screen, original.cursor.page_pin.*) orelse return false;
    const visible = snapshotViewportRows(screen) orelse return false;
    result.* = .{
        .cursor = .{ .x = point.screen.x, .y = point.screen.y },
        .viewport_top = visible.start,
        .total_rows = original.pages.total_rows,
        .viewport_rows = @intCast(@max(1, visible.end - visible.start)),
        .columns = original.pages.cols,
    };
    return true;
}

export fn ghostty_surface_snapshot_resolve_cell(
    surface: *Surface,
    generation: u64,
    requested: SnapshotCell,
    snap_right: bool,
    result: *SnapshotCell,
) bool {
    @import("../c_api_error.zig").clear();
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = surface.core_surface.snapshot.terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    return snapshotResolveCell(t, requested, snap_right, result);
}

fn snapshotResolveCell(t: *terminal.Terminal, requested: SnapshotCell, snap_right: bool, result: *SnapshotCell) bool {
    const screen = t.screens.active;
    var pin = snapshotCellPin(screen, requested, snapshotViewportAnchor(screen)) orelse return false;
    const page = pin.node.page();
    const row = &page.rows.ptr(page.memory)[pin.y];
    if (page.getCells(row)[pin.x].wide == .spacer_tail) {
        if (snap_right and pin.x + 1 < pin.node.cols()) {
            pin.x += 1;
        } else if (pin.x > 0) {
            pin.x -= 1;
        }
    }
    result.* = .{ .x = pin.x, .y = requested.y };
    return true;
}

export fn ghostty_surface_snapshot_selection_text(
    surface: *Surface,
    generation: u64,
    range: SnapshotCellRange,
    trim: bool,
    rectangle: bool,
    result: *SnapshotSelectionText,
) bool {
    @import("../c_api_error.zig").clear();
    result.* = .{ .text = null, .len = 0 };
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = surface.core_surface.snapshot.terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    return snapshotSelectionText(t, range, trim, rectangle, result);
}

fn snapshotSelectionText(t: *terminal.Terminal, range: SnapshotCellRange, trim: bool, rectangle: bool, result: *SnapshotSelectionText) bool {
    const screen = t.screens.active;
    var sel = snapshotCellSelection(screen, range, snapshotViewportAnchor(screen)) orelse return false;
    sel.rectangle = rectangle;
    const text_result = screen.selectionString(global.alloc(), .{ .sel = sel, .trim = trim }) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    result.* = .{ .text = text_result.ptr, .len = text_result.len };
    return true;
}

export fn ghostty_surface_snapshot_selection_text_free(result: *SnapshotSelectionText) void {
    @import("../c_api_error.zig").clear();
    if (result.text) |ptr| global.alloc().free(ptr[0 .. result.len + 1]);
    result.* = .{ .text = null, .len = 0 };
}

const SnapshotViewportOptions = extern struct {
    reveal: ?*const SnapshotCell,
    padding_rows: u32,
    top_row: ?*const u64,
};

export fn ghostty_surface_snapshot_apply_decorations(
    surface: *Surface,
    generation: u64,
    layers_ptr: ?[*]const SnapshotDecorationLayer,
    layer_count: usize,
    text_ptr: ?[*]const SnapshotCellText,
    text_count: usize,
    viewport_options: ?*const SnapshotViewportOptions,
) bool {
    @import("../c_api_error.zig").clear();
    if (layer_count > 254) return false;
    const layers = if (layers_ptr) |ptr| ptr[0..layer_count] else if (layer_count == 0) &.{} else return false;
    const text = if (text_ptr) |ptr| ptr[0..text_count] else if (text_count == 0) &.{} else return false;
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = state.presentation_terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    const screen = t.screens.active;
    if (viewport_options) |options| {
        const max_top = screen.pages.total_rows -| screen.pages.rows;
        const top: ?usize = if (options.top_row) |row|
            @intCast(@min(row.*, max_top))
        else if (options.reveal) |cell| blk: {
            _ = snapshotCellPin(screen, cell.*, snapshotViewportAnchor(screen)) orelse return false;
            const before = snapshotViewportRows(screen) orelse return false;
            break :blk @import("snapshot_viewport.zig").revealTop(before.start, before.end - before.start, screen.pages.total_rows, cell.y, options.padding_rows);
        } else null;
        if (top) |row| {
            const before = snapshotViewportRows(screen) orelse return false;
            if (row != before.start) {
                screen.scroll(.{ .row = row });
                t.flags.dirty.clear = true;
            }
        }
    }
    const viewport = snapshotViewportRows(screen) orelse return false;
    const anchor: SnapshotAnchor = .{
        .pin = screen.pages.getTopLeft(.viewport),
        .row = viewport.start,
    };
    var arena = std.heap.ArenaAllocator.init(global.alloc());
    var owned = true;
    defer if (owned) arena.deinit();
    const alloc = arena.allocator();
    const core_layers = alloc.alloc(@import("../renderer/SnapshotDecorations.zig").Layer, layers.len) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    for (layers, core_layers) |layer, *dst| {
        if (layer.style.flags & ~@as(u32, 3) != 0) return false;
        const ordered = if (layer.ranges) |ptr| ptr[0..layer.range_count] else if (layer.range_count == 0) &.{} else return false;
        const visible = snapshotVisibleOrderedCellRanges(ordered, viewport);
        const flattened = alloc.alloc(terminal.highlight.Flattened, visible.len) catch |err| {
            @import("../c_api_error.zig").set(err);
            return false;
        };
        for (visible, flattened) |range, *item| {
            const sel = snapshotCellSelection(screen, range, anchor) orelse return false;
            item.* = terminal.highlight.Flattened.init(
                alloc,
                sel.topLeft(screen),
                sel.bottomRight(screen),
            ) catch |err| {
                @import("../c_api_error.zig").set(err);
                return false;
            };
        }
        dst.* = .{
            .ranges = flattened,
            .style = layer.style.toCore(),
        };
    }
    var core_text: std.ArrayList(@import("../renderer/SnapshotDecorations.zig").Text) = .empty;
    for (text) |item| {
        if (item.style.flags & ~@as(u32, 3) != 0) return false;
        if (item.codepoint < 0x20 or item.codepoint > 0x7e) return false;
        const cell = item.cell;
        if (cell.y < viewport.start or cell.y >= viewport.end) continue;
        _ = snapshotCellPin(screen, cell, anchor) orelse return false;
        core_text.append(alloc, .{
            .coord = .{ .x = @intCast(cell.x), .y = @intCast(cell.y - viewport.start) },
            .codepoint = @intCast(item.codepoint),
            .style = item.style.toCore(),
            .bold = item.bold,
        }) catch |err| {
            @import("../c_api_error.zig").set(err);
            return false;
        };
    }
    std.mem.sort(@import("../renderer/SnapshotDecorations.zig").Text, core_text.items, {}, struct {
        fn less(_: void, a: @import("../renderer/SnapshotDecorations.zig").Text, b: @import("../renderer/SnapshotDecorations.zig").Text) bool {
            return a.coord.y < b.coord.y or (a.coord.y == b.coord.y and a.coord.x < b.coord.x);
        }
    }.less);
    var text_len: usize = 0;
    for (core_text.items) |item| {
        if (text_len > 0 and std.meta.eql(item.coord, core_text.items[text_len - 1].coord)) {
            return false;
        }
        core_text.items[text_len] = item;
        text_len += 1;
    }
    core_text.items.len = text_len;
    _ = surface.core_surface.renderer_thread.mailbox.push(
        global.io(),
        .{ .snapshot_decorations = .{ .arena = arena, .layers = core_layers, .text = core_text.items } },
        .{ .forever = {} },
    );
    owned = false;
    surface.core_surface.snapshot.decoration_viewport = viewport;
    surface.core_surface.renderer_thread.wakeup.notify() catch {};
    return true;
}

fn snapshotRgb(rgb: u32) terminal.color.RGB {
    return .{
        .r = @truncate(rgb >> 16),
        .g = @truncate(rgb >> 8),
        .b = @truncate(rgb),
    };
}

fn snapshotVisibleOrderedCellRanges(
    ranges: []const SnapshotCellRange,
    viewport: @import("../surface/Snapshot.zig").Viewport,
) []const SnapshotCellRange {
    var first: usize = 0;
    var last: usize = ranges.len;
    while (first < last) {
        const mid = first + (last - first) / 2;
        if (ranges[mid].start.y >= viewport.end) first = mid + 1 else last = mid;
    }
    const visible_start = first;
    last = ranges.len;
    while (first < last) {
        const mid = first + (last - first) / 2;
        if (ranges[mid].end.y >= viewport.start) first = mid + 1 else last = mid;
    }
    return ranges[visible_start..first];
}

export fn ghostty_surface_snapshot_decorations_need_refresh(
    surface: *Surface,
    generation: u64,
) bool {
    @import("../c_api_error.zig").clear();
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = state.presentation_terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    const viewport = snapshotViewportRows(t.screens.active) orelse return false;
    return !std.meta.eql(viewport, surface.core_surface.snapshot.decoration_viewport orelse return true);
}

export fn ghostty_surface_snapshot_text_cursor_new(
    surface: *Surface,
    generation: u64,
) ?*SnapshotTextCursor {
    @import("../c_api_error.zig").clear();
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return null;
    }
    const t = surface.core_surface.snapshot.terminal orelse return null;
    const cursor = terminal.SnapshotTextCursor.init(t.screens.active, global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        return null;
    };
    const result = global.alloc().create(SnapshotTextCursor) catch |err| {
        @import("../c_api_error.zig").set(err);
        var owned = cursor;
        owned.deinit();
        return null;
    };
    result.* = .{ .surface = surface, .generation = generation, .cursor = cursor };
    return result;
}

export fn ghostty_surface_snapshot_text_cursor_free(cursor: *SnapshotTextCursor) void {
    @import("../c_api_error.zig").clear();
    cursor.cursor.deinit();
    global.alloc().destroy(cursor);
}

export fn ghostty_surface_snapshot_text_cursor_reset(cursor: *SnapshotTextCursor) bool {
    @import("../c_api_error.zig").clear();
    const state = &cursor.surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (cursor.surface.core_surface.snapshot.generation != cursor.generation or
        cursor.surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    cursor.cursor.reset();
    return true;
}

export fn ghostty_surface_snapshot_text_cursor_next(
    cursor: *SnapshotTextCursor,
    result: *SnapshotTextChunk,
) c_int {
    @import("../c_api_error.zig").clear();
    const state = &cursor.surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (cursor.surface.core_surface.snapshot.generation != cursor.generation or
        cursor.surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return -1;
    }
    const chunk = (cursor.cursor.next() catch |err| {
        @import("../c_api_error.zig").set(err);
        return -1;
    }) orelse {
        return 0;
    };
    result.* = .{
        .text = chunk.text.ptr,
        .points = chunk.points.ptr,
        .len = chunk.text.len,
        .row_base = chunk.row_base,
        .start_y = chunk.start_y,
    };
    return 1;
}

export fn ghostty_surface_snapshot_text_row(
    surface: *Surface,
    generation: u64,
    row: u64,
    result: *SnapshotTextRow,
) bool {
    @import("../c_api_error.zig").clear();
    result.* = .{ .text = null, .columns = null, .len = 0, .wraps_to_next = false };
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    if (surface.core_surface.snapshot.generation != generation or
        surface.core_surface.snapshot.terminal == null)
    {
        @import("../c_api_error.zig").set(error.SnapshotExpired);
        return false;
    }
    const t = surface.core_surface.snapshot.terminal orelse {
        @import("../c_api_error.zig").set(error.SnapshotUnavailable);
        return false;
    };
    const screen = t.screens.active;
    const anchor: ?SnapshotAnchor = if (surface.core_surface.snapshot.text_row_anchor) |a|
        .{ .pin = a.pin, .row = a.row }
    else
        snapshotViewportAnchor(screen);
    const pin = snapshotCellPin(screen, .{ .x = 0, .y = row }, anchor) orelse return false;
    surface.core_surface.snapshot.text_row_anchor = .{ .pin = pin, .row = row };
    return snapshotTextRow(pin, result);
}

fn snapshotTextRow(pin: terminal.PageList.Pin, result: *SnapshotTextRow) bool {
    const alloc = global.alloc();
    const page = pin.node.page();
    var text_writer: std.Io.Writer.Allocating = .init(alloc);
    defer text_writer.deinit();
    var points: std.ArrayList(terminal.Coordinate) = .empty;
    defer points.deinit(alloc);
    var formatter: @import("../terminal/formatter.zig").PageFormatter = .init(page, .{
        .emit = .plain,
        .unwrap = false,
        .trim = false,
    });
    formatter.start_y = pin.y;
    formatter.end_y = pin.y;
    formatter.point_map = .{ .alloc = alloc, .map = &points };
    formatter.format(&text_writer.writer) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    const written = text_writer.written();
    if (written.len != points.items.len) return false;
    const text_copy = alloc.dupe(u8, written) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    const columns = alloc.alloc(u32, written.len) catch |err| {
        @import("../c_api_error.zig").set(err);
        alloc.free(text_copy);
        return false;
    };
    for (points.items, columns) |point, *column| column.* = point.x;
    result.* = .{
        .text = text_copy.ptr,
        .columns = columns.ptr,
        .len = written.len,
        .wraps_to_next = page.rows.ptr(page.memory)[pin.y].wrap,
    };
    return true;
}

export fn ghostty_surface_snapshot_text_row_free(result: *SnapshotTextRow) void {
    @import("../c_api_error.zig").clear();
    const alloc = global.alloc();
    if (result.text) |ptr| alloc.free(ptr[0..result.len]);
    if (result.columns) |ptr| alloc.free(ptr[0..result.len]);
    result.* = .{ .text = null, .columns = null, .len = 0, .wraps_to_next = false };
}

export fn ghostty_surface_snapshot_begin(
    surface: *Surface,
    generation: *u64,
) bool {
    @import("../c_api_error.zig").clear();
    surface.core_surface.snapshot.begin(&surface.core_surface) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.warn("error beginning snapshot presentation err={}", .{err});
        return false;
    };
    generation.* = surface.core_surface.snapshot.generation;
    return true;
}

export fn ghostty_surface_snapshot_end(
    surface: *Surface,
    generation: u64,
) bool {
    @import("../c_api_error.zig").clear();
    if (surface.core_surface.snapshot.terminal == null or
        surface.core_surface.snapshot.generation != generation)
    {
        return false;
    }
    surface.core_surface.snapshot.end(&surface.core_surface);
    return true;
}

test "snapshot text cursor streams exact text and cell points across pages" {
    const alloc = std.testing.allocator;
    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..100) |_| stream.nextSlice("a界e\u{301}b\r\n");
    const screen = t.screens.active;
    try std.testing.expect(screen.pages.pages.first != screen.pages.pages.last);
    const full = try screen.selectionStringMap(alloc, .{
        .sel = .init(
            screen.pages.getTopLeft(.screen),
            screen.pages.getBottomRight(.screen).?,
            false,
        ),
        .trim = false,
    });
    defer full.deinit(alloc);
    var cursor = try terminal.SnapshotTextCursor.init(screen, alloc);
    defer cursor.deinit();
    const anchor = snapshotViewportAnchor(screen);
    var count: usize = 0;
    while (try cursor.next()) |chunk| {
        try std.testing.expectEqual(chunk.text.len, chunk.points.len);
        for (chunk.text, chunk.points) |byte, point| {
            try std.testing.expectEqual(full.string[count], byte);
            const pin = screen.pages.pin(.{ .screen = .{
                .x = point.x,
                .y = @intCast(chunk.row_base + point.y - chunk.start_y),
            } }).?;
            try std.testing.expect(pin.eql(full.map.get(count).?));
            const cell: SnapshotCell = .{
                .x = point.x,
                .y = chunk.row_base + point.y - chunk.start_y,
            };
            const selection = snapshotCellSelection(screen, .{
                .start = cell,
                .end = cell,
            }, anchor).?;
            try std.testing.expect(selection.start().eql(pin));
            count += 1;
        }
    }
    try std.testing.expectEqual(full.string.len, count);
    cursor.reset();
    try std.testing.expect((try cursor.next()) != null);
}

test "ordered cell highlights select only viewport overlaps" {
    const ranges = [_]SnapshotCellRange{
        .{ .start = .{ .x = 1, .y = 40 }, .end = .{ .x = 3, .y = 40 } },
        .{ .start = .{ .x = 2, .y = 22 }, .end = .{ .x = 4, .y = 24 } },
        .{ .start = .{ .x = 1, .y = 18 }, .end = .{ .x = 2, .y = 18 } },
        .{ .start = .{ .x = 0, .y = 4 }, .end = .{ .x = 2, .y = 4 } },
    };
    const visible = snapshotVisibleOrderedCellRanges(&ranges, .{ .start = 20, .end = 23 });
    try std.testing.expectEqualSlices(SnapshotCellRange, ranges[1..2], visible);
}
