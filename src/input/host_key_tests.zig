//! Key encoding regressions for translated host keyboard input.
const std = @import("std");
const testing = std.testing;

pub fn consumedShift(comptime kitty: anytype) !void {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .bracket_left,
        .mods = .{ .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "{",
        .unshifted_codepoint = '[',
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("{", writer.buffered());
}
