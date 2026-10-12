//! Extra configuration values needed by the embedding host.
const std = @import("std");
const Config = @import("Config.zig");
const Color = Config.Color;
const Key = @import("key.zig").Key;
const get = @import("c_get.zig").get;

pub fn extra(config: *const Config, k: Key, ptr_raw: *anyopaque) ?bool {
    switch (k) {
        .theme => {
            const theme = config.theme orelse return false;
            const name = switch (config._conditional_state.theme) {
                .light => theme.light,
                .dark => theme.dark,
            };
            const ptr: *extern struct { ptr: [*]const u8, len: usize } = @ptrCast(@alignCast(ptr_raw));
            ptr.* = .{ .ptr = name.ptr, .len = name.len };
            return true;
        },
        else => return null,
    }
}

pub fn terminalColor(ptr_raw: *anyopaque, value: Config.TerminalColor) bool {
    switch (value) {
        .color => |color| {
            const ptr: *Color.C = @ptrCast(@alignCast(ptr_raw));
            ptr.* = color.cval();
            return true;
        },
        .@"cell-foreground", .@"cell-background" => return false,
    }
}

test "c_get: selected theme name" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    var name: extern struct { ptr: [*]const u8, len: usize } = undefined;
    try testing.expect(!get(&config, .theme, &name));
    config.theme = .{ .light = "day", .dark = "night" };
    config._conditional_state.theme = .dark;
    try testing.expect(get(&config, .theme, &name));
    try testing.expectEqualStrings("night", name.ptr[0..name.len]);
    config._conditional_state.theme = .light;
    try testing.expect(get(&config, .theme, &name));
    try testing.expectEqualStrings("day", name.ptr[0..name.len]);
}

test "c_get: literal selection colors" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.@"selection-background" = .{ .color = .{ .r = 18, .g = 52, .b = 86 } };
    var result: Color.C = undefined;
    try testing.expect(get(&config, .@"selection-background", &result));
    try testing.expectEqual(@as(u8, 18), result.r);
    try testing.expectEqual(@as(u8, 52), result.g);
    try testing.expectEqual(@as(u8, 86), result.b);
    config.@"selection-background" = .@"cell-foreground";
    try testing.expect(!get(&config, .@"selection-background", &result));
    config.@"selection-background" = null;
    try testing.expect(!get(&config, .@"selection-background", &result));
}
