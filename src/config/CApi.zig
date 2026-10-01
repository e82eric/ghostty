const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

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

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    @import("../c_api_error.zig").clear();
    const result = global.alloc().create(Config) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    @import("../c_api_error.zig").clear();
    const result = global.alloc().create(Config) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    @import("../c_api_error.zig").clear();
    self.loadCliArgs(global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    @import("../c_api_error.zig").clear();
    self.loadDefaultFiles(global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    @import("../c_api_error.zig").clear();
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    @import("../c_api_error.zig").clear();
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    @import("../c_api_error.zig").clear();
    self.finalize() catch |err| {
        @import("../c_api_error.zig").set(err);
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}
