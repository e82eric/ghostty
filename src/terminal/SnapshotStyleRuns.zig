//! Resolved compact style runs for a frozen document row.
const std = @import("std");
const terminal = @import("main.zig");
pub const Run = extern struct {
    start: u32,
    end: u32,
    foreground: u32,
    background: u32,
    underline_color: u32,
    flags: u8,
    underline: u8,
    reserved: u16 = 0,
};
fn packedColor(rgb: ?terminal.color.RGB) u32 {
    const c = rgb orelse return std.math.maxInt(u32);
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

pub fn capture(alloc: std.mem.Allocator, t: *const terminal.Terminal, pin: terminal.PageList.Pin) ![]Run {
    const page = pin.node.page();
    const cells = page.getCells(page.getRow(pin.y));
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(alloc);
    for (cells, 0..) |*cell, x| {
        const style: terminal.Style = if (cell.style_id == 0) .{} else page.styles.get(page.memory, cell.style_id).*;
        const fg: ?terminal.color.RGB = switch (style.fg_color) {
            .none => t.colors.foreground.get(),
            else => style.fg(.{ .default = .{ .r = 255, .g = 255, .b = 255 }, .palette = &t.colors.palette.current }),
        };
        const run: Run = .{
            .start = @intCast(x),
            .end = @intCast(x + 1),
            .foreground = packedColor(fg),
            // Default background belongs to the preview canvas, not the row's
            // content. Only explicit backgrounds should retain trailing blanks.
            .background = packedColor(style.bg(cell, &t.colors.palette.current)),
            .underline_color = packedColor(style.underlineColor(&t.colors.palette.current)),
            .flags = @as(u8, @intFromBool(style.flags.bold)) | (@as(u8, @intFromBool(style.flags.italic)) << 1) | (@as(u8, @intFromBool(style.flags.strikethrough)) << 2) | (@as(u8, @intFromBool(style.flags.inverse)) << 3) | (@as(u8, @intFromBool(style.flags.invisible)) << 4) | (@as(u8, @intFromBool(style.flags.faint)) << 5),
            .underline = @intFromBool(style.flags.underline != .none),
        };
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            if (last.foreground == run.foreground and last.background == run.background and last.underline_color == run.underline_color and last.flags == run.flags and last.underline == run.underline) {
                last.end = run.end;
                continue;
            }
        }
        try runs.append(alloc, run);
    }
    return runs.toOwnedSlice(alloc);
}

test "snapshot style runs resolve RGB palette flags and blank backgrounds" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 2 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[38;2;12;34;56;1;3;4mabc\x1b[0m\x1b[48;2;90;80;70m  \x1b[0mrest");
    const pin = t.screens.active.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const runs = try capture(testing.allocator, &t, pin);
    defer testing.allocator.free(runs);
    try testing.expectEqual(@as(u32, 0x0c2238), runs[0].foreground);
    try testing.expectEqual(@as(u32, 3), runs[0].end);
    try testing.expectEqual(@as(u8, 3), runs[0].flags);
    try testing.expectEqual(@as(u8, 1), runs[0].underline);
    try testing.expectEqual(@as(u32, 0x5a5046), runs[1].background);
    try testing.expectEqual(@as(u32, 20), runs[runs.len - 1].end);
    try testing.expectEqual(std.math.maxInt(u32), runs[0].background);
    try testing.expectEqual(std.math.maxInt(u32), runs[runs.len - 1].background);
    try testing.expectEqual(@as(usize, 24), @sizeOf(Run));
}
