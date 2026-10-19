//! Additional embedding APIs for native host composition and live terminal input.
const std = @import("std");
const input = @import("../input.zig");
const log = std.log.scoped(.embedded_window);
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const font = @import("../font/main.zig");
const Surface = @import("embedded.zig").Surface;

const GLFrame = struct {
    alloc: Allocator,
    frame: renderer.Renderer.ExportedFrame,
};

const GLFrameDescription = extern struct {
    handle: ?*GLFrame,
    texture: u32,
    width: u32,
    height: u32,
    generation: u64,
};
/// Take the newest frame exported for composition by an OpenGL host.
/// The caller owns a successful result until ghostty_gl_frame_release.
export fn ghostty_surface_take_gl_frame(
    surface: *Surface,
    result: *GLFrameDescription,
) bool {
    @import("../c_api_error.zig").clear();
    if (comptime renderer.Renderer.ExportedFrame == void or @import("../build_config.zig").renderer != .opengl) return false;

    const frame = surface.core_surface.renderer.takeFrame() orelse return false;
    const texture = frame.texture;

    const alloc = surface.app.core_app.alloc;
    const owned = alloc.create(GLFrame) catch |err| {
        @import("../c_api_error.zig").set(err);
        frame.deinit();
        return false;
    };
    owned.* = .{ .alloc = alloc, .frame = frame };
    result.* = .{
        .handle = owned,
        .texture = texture.texture,
        .width = texture.width,
        .height = texture.height,
        .generation = texture.generation,
    };
    return true;
}

export fn ghostty_gl_frame_release(frame: *GLFrame) void {
    @import("../c_api_error.zig").clear();
    if (comptime renderer.Renderer.ExportedFrame != void) {
        const alloc = frame.alloc;
        frame.frame.deinit();
        alloc.destroy(frame);
    }
}

const FontVariation = extern struct {
    tag: u32 = 0,
    value: f32 = 0,
};
const FontData = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
    face_index: u32 = 0,
    variation_count: u32 = 0,
    variations: [32]FontVariation = @splat(.{}),
};

export fn ghostty_surface_read_font(surface: *Surface, bold: bool, result: *FontData) bool {
    @import("../c_api_error.zig").clear();
    result.* = .{};
    if (comptime !font.options.backend.hasFreetype()) return false;
    const grid = surface.core_surface.renderer.font_grid;
    // The bold face may still be deferred; getFace can load and cache it.
    grid.lock.lockUncancelable(global.io());
    defer grid.lock.unlock(global.io());
    const face = grid.resolver.collection.getFace(.{ .style = if (bold) .bold else .regular }) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    face.ft_mutex.lockUncancelable(global.io());
    defer face.ft_mutex.unlock(global.io());
    var exported: FontData = .{};
    if (face.face.hasMultipleMasters()) {
        const mm = face.face.getMMVar() catch |err| {
            @import("../c_api_error.zig").set(err);
            return false;
        };
        defer face.lib.lib.doneMMVar(mm);
        if (mm.num_axis > exported.variations.len) {
            @import("../c_api_error.zig").set(error.UnsupportedFontVariationAxes);
            return false;
        }
        var coordinates: [32]@import("freetype").c.FT_Fixed = undefined;
        face.face.getVarDesignCoordinates(coordinates[0..mm.num_axis]) catch |err| {
            @import("../c_api_error.zig").set(err);
            return false;
        };
        exported.variation_count = @intCast(mm.num_axis);
        for (0..mm.num_axis) |i| {
            exported.variations[i] = .{
                .tag = @intCast(mm.axis[i].tag),
                .value = @as(f32, @floatFromInt(coordinates[i])) / 65536.0,
            };
        }
    }
    // FreeType's zero SFNT tag reads the original complete font stream,
    // including TTC collections and Ghostty's in-memory default font.
    const bytes = (face.copyTable(global.alloc(), &.{ 0, 0, 0, 0 }) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    }) orelse return false;
    exported.data = bytes.ptr;
    exported.len = bytes.len;
    exported.face_index = @intCast(face.face.handle.*.face_index & 0xffff);
    result.* = exported;
    return true;
}

export fn ghostty_font_data_free(result: *FontData) void {
    @import("../c_api_error.zig").clear();
    if (result.data) |data| global.alloc().free(data[0..result.len]);
    result.* = .{};
}

const LiveCursorLine = extern struct {
    text: ?[*]const u8,
    len: usize,
    cursor_byte: usize,
    cursor_column: u32,
};

const LiveCursorPosition = extern struct { column: u32, row: u32 };

export fn ghostty_surface_live_cursor_position(surface: *Surface, result: *LiveCursorPosition) bool {
    @import("../c_api_error.zig").clear();
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const screen = state.terminal.screens.active;
    const point = screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*) orelse return false;
    result.* = .{ .column = point.viewport.x, .row = point.viewport.y };
    return true;
}

export fn ghostty_surface_live_cursor_line(surface: *Surface, result: *LiveCursorLine) bool {
    @import("../c_api_error.zig").clear();
    result.* = .{ .text = null, .len = 0, .cursor_byte = 0, .cursor_column = 0 };
    const state = &surface.core_surface.renderer_state;
    state.mutex.lockUncancelable(global.io());
    defer state.mutex.unlock(global.io());
    const screen = state.terminal.screens.active;
    const pin = screen.cursor.page_pin.*;
    const alloc = global.alloc();
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    var points: std.ArrayList(terminal.Coordinate) = .empty;
    defer points.deinit(alloc);
    var formatter: @import("../terminal/formatter.zig").PageFormatter = .init(pin.node.page(), .{
        .emit = .plain,
        .unwrap = false,
        .trim = false,
    });
    formatter.start_y = pin.y;
    formatter.end_y = pin.y;
    formatter.point_map = .{ .alloc = alloc, .map = &points };
    formatter.format(&writer.writer) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    const written = writer.written();
    if (written.len != points.items.len) return false;
    var cursor_byte = written.len;
    for (points.items, 0..) |point, index| {
        if (point.x >= pin.x) {
            cursor_byte = index;
            break;
        }
    }
    const copy = alloc.dupe(u8, written) catch |err| {
        @import("../c_api_error.zig").set(err);
        return false;
    };
    result.* = .{ .text = copy.ptr, .len = copy.len, .cursor_byte = cursor_byte, .cursor_column = pin.x };
    return true;
}

export fn ghostty_surface_live_cursor_line_free(result: *LiveCursorLine) void {
    @import("../c_api_error.zig").clear();
    if (result.text) |ptr| global.alloc().free(ptr[0..result.len]);
    result.* = .{ .text = null, .len = 0, .cursor_byte = 0, .cursor_column = 0 };
}

export fn ghostty_surface_shell_pid(surface: *Surface) u64 {
    return surface.core_surface.getProcessInfo(.shell_pid) orelse 0;
}
export fn ghostty_surface_shell_creation_time(surface: *Surface) u64 {
    return surface.core_surface.getProcessInfo(.shell_creation_time) orelse 0;
}

/// Send a key event identified by its USB HID usage code. This avoids
/// requiring cross-platform embedders to reproduce Ghostty's native
/// keycode tables.
/// The optional translated text is part of the key event so applications
/// can use their active keyboard protocol instead of receiving a paste.
export fn ghostty_surface_key_usb(
    surface: *Surface,
    action: input.Action,
    mods: c_int,
    usb: u32,
    unshifted_codepoint: u32,
    text: ?[*:0]const u8,
) bool {
    @import("../c_api_error.zig").clear();
    const native = for (input.keycodes.entries) |entry| {
        if (entry.usb == usb) break entry.native;
    } else 0;

    return surface.app.keyEvent(.{ .surface = surface }, .{
        .action = action,
        .mods = @bitCast(@as(input.Mods.Backing, @truncate(@as(c_uint, @bitCast(mods))))),
        // A printable shifted key has already used Shift to produce its
        // text. Keep it out of the effective modifiers for key encoding.
        .consumed_mods = .{ .shift = text != null and mods & 1 != 0 },
        .keycode = native,
        .text = if (text) |v| std.mem.span(v) else null,
        .unshifted_codepoint = unshifted_codepoint,
        .composing = false,
    }) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.warn("error processing key event err={}", .{err});
        return false;
    };
}

pub fn screenPointSpansScrollback(comptime Point: type, comptime pinFn: anytype) !void {
    var t: terminal.Terminal = try .init(std.testing.io, std.testing.allocator, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(std.testing.allocator);

    var stream = t.vtStream();
    defer stream.deinit();
    for (0..200) |_| stream.nextSlice("history\r\n");

    const screen = t.screens.active;
    try std.testing.expect(screen.pages.total_rows > screen.pages.rows);
    const last_y: u32 = @intCast(screen.pages.total_rows - 1);
    const p: Point = .{
        .tag = .screen,
        .coord_tag = .exact,
        .x = 0,
        .y = last_y,
    };
    const pin = pinFn(p, screen).?;
    try std.testing.expectEqual(
        last_y,
        screen.pages.pointFromPin(.screen, pin).?.screen.y,
    );
}
