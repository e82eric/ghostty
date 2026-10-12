//! Configuration extensions used by the embedding host's theme and font pickers.
const std = @import("std");
const global = @import("../global.zig");
const Config = @import("Config.zig");

/// Replace terminal color overrides with a theme before finalization.
export fn ghostty_config_set_theme(self: *Config, name: [*:0]const u8) bool {
    removeColorOverrides(self);
    appendTheme(self, global.alloc(), std.mem.span(name)) catch return false;
    return true;
}

/// A picker choice replaces terminal colors, including explicit colors from
/// configuration files. Other replay inputs and command arguments stay intact.
fn removeColorOverrides(self: *Config) void {
    var write: usize = 0;
    var command = false;
    for (self._replay_steps.items) |step| {
        if (step == .@"-e") command = true;
        if (!command and step == .arg) {
            const argument = std.mem.trimStart(u8, step.arg, "-");
            const end = std.mem.indexOfScalar(u8, argument, '=') orelse argument.len;
            const key = argument[0..end];
            var color = false;
            inline for (.{ "background", "foreground", "palette", "cursor-color", "cursor-text", "selection-background", "selection-foreground" }) |name| {
                if (std.mem.eql(u8, key, name)) color = true;
            }
            if (color) continue;
        }
        self._replay_steps.items[write] = step;
        write += 1;
    }
    self._replay_steps.items.len = write;
}

fn appendTheme(self: *Config, alloc: std.mem.Allocator, name: []const u8) !void {
    const argument = try std.fmt.allocPrint(alloc, "--theme={s}", .{name});
    defer alloc.free(argument);
    try appendArgument(self, alloc, argument);
}

fn appendArgument(self: *Config, alloc: std.mem.Allocator, argument: []const u8) !void {
    var iter = @import("../cli.zig").args.sliceIterator(&.{argument});
    const previous_len = self._replay_steps.items.len;
    try self.loadIter(alloc, &iter);
    // Keep the new option before the initial-command tail during replay.
    for (self._replay_steps.items[0..previous_len], 0..) |step, index| {
        if (step == .@"-e" and self._replay_steps.items.len == previous_len + 1) {
            const added = self._replay_steps.items[previous_len];
            std.mem.copyBackwards(@TypeOf(added), self._replay_steps.items[index + 1 ..], self._replay_steps.items[index..previous_len]);
            self._replay_steps.items[index] = added;
            break;
        }
    }
}

/// Apply explicitly supplied font settings before finalization.
export fn ghostty_config_set_font(self: *Config, family: ?[*:0]const u8, size: f32) bool {
    setFont(self, global.alloc(), if (family) |value| std.mem.span(value) else null, size) catch return false;
    return true;
}

fn setFont(self: *Config, alloc: std.mem.Allocator, family: ?[]const u8, size: f32) !void {
    if (family) |value| {
        if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidFont;
        try appendArgument(self, alloc, "--font-family=");
        const argument = try std.fmt.allocPrint(alloc, "--font-family={s}", .{value});
        defer alloc.free(argument);
        try appendArgument(self, alloc, argument);
    }
    if (size != 0) {
        if (!std.math.isFinite(size) or size <= 0) return error.InvalidFont;
        const argument = try std.fmt.allocPrint(alloc, "--font-size={d}", .{size});
        defer alloc.free(argument);
        try appendArgument(self, alloc, argument);
    }
}

test "font reload preserves command tail and replaces font family" {
    const alloc = std.testing.allocator;
    var config = try Config.default(alloc);
    defer config.deinit();
    var iter = @import("../cli.zig").args.sliceIterator(&.{ "--font-family=old", "-e", "echo", "--font-size=99" });
    try config.loadIter(alloc, &iter);
    try setFont(&config, alloc, "new", 23);
    try config.finalize();
    try std.testing.expect(config._diagnostics.empty());
    try std.testing.expectEqual(@as(f32, 23), config.@"font-size");
    try std.testing.expectEqual(@as(usize, 1), config.@"font-family".list.items.len);
    try std.testing.expectEqualStrings("new", config.@"font-family".list.items[0]);
    try std.testing.expectEqualStrings("--font-size=99", config.@"initial-command".?.direct[1]);
}

test "theme switching replaces colors and preserves other settings" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var td = testing.tmpDir(.{});
    defer td.cleanup();
    for ([_][]const u8{ "one", "two" }, [_][]const u8{
        "background = #112233\nforeground = #ffffff\n",
        "background = #445566\nforeground = #000000\n",
    }) |name, content| {
        var file = try td.dir.createFile(testing.io, name, .{});
        defer file.close(testing.io);
        var buffer: [256]u8 = undefined;
        var writer = file.writer(testing.io, &buffer);
        try writer.interface.writeAll(content);
        try writer.end();
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const first = path_buffer[0..try td.dir.realPathFile(testing.io, "one", &path_buffer)];
    var base = try Config.default(alloc);
    defer base.deinit();
    var iter = @import("../cli.zig").args.sliceIterator(&.{ "--font-size=23", "--foreground=#abcdef", "--palette=1=#abcdef", "-e", "echo", "hello" });
    try base.loadIter(alloc, &iter);
    try appendTheme(&base, alloc, first);
    var candidate = try base.clone(alloc);
    defer candidate.deinit();
    try base.finalize();
    const second = path_buffer[0..try td.dir.realPathFile(testing.io, "two", &path_buffer)];
    try appendTheme(&candidate, alloc, second);
    removeColorOverrides(&candidate);
    try candidate.finalize();
    try testing.expect(candidate._diagnostics.empty());
    try testing.expectEqual(@as(f32, 23), candidate.@"font-size");
    try testing.expectEqual(@as(u8, 0), candidate.foreground.r);
    try testing.expect(candidate.palette.value[1].r != 0xab);
    try testing.expectEqual(@as(u8, 0x44), candidate.background.r);
    try testing.expectEqual(@as(u8, 0x11), base.background.r);
    const command = candidate.@"initial-command".?.direct;
    try testing.expectEqual(@as(usize, 2), command.len);
    try testing.expectEqualStrings("echo", command[0]);
    try testing.expectEqualStrings("hello", command[1]);
}

/// Enumerate the same search directories used by the theme loader, in priority order.
export fn ghostty_config_theme_directories(userdata: ?*anyopaque, callback: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void) bool {
    var arena = std.heap.ArenaAllocator.init(global.alloc());
    defer arena.deinit();
    var iter: @import("theme.zig").LocationIterator = .{ .arena_alloc = arena.allocator() };
    while (iter.next() catch return false) |location| {
        const path = arena.allocator().dupeZ(u8, location.dir) catch return false;
        callback(userdata, path);
    }
    return true;
}
