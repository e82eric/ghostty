//! Host initialization helpers and thread-local C API error accessors.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const global = @import("global.zig");

pub export fn ghostty_last_error() ?[*:0]const u8 {
    return @import("c_api_error.zig").get();
}
pub export fn ghostty_clear_error() void {
    @import("c_api_error.zig").clear();
}

/// The Windows std.process.Args iterator parses a UTF-16 command line, so
/// quote each supplied UTF-8 argument using the CRT backslash rules.
pub fn windowsCommandLineFromUtf8Args(argc: usize, argv: [*][*:0]u8) ![]u16 {
    const alloc = std.heap.page_allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    for (argv[0..argc], 0..) |ptr, index| {
        if (index != 0) try line.append(alloc, ' ');
        try line.append(alloc, '"');
        var slashes: usize = 0;
        for (std.mem.span(ptr)) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            const count = slashes * (if (byte == '"') @as(usize, 2) else 1);
            for (0..count) |_| try line.append(alloc, '\\');
            slashes = 0;
            if (byte == '"') try line.append(alloc, '\\');
            try line.append(alloc, byte);
        }
        for (0..slashes * 2) |_| try line.append(alloc, '\\');
        try line.append(alloc, '"');
    }
    // Global argument parsing retains this slice for the host's lifetime.
    return std.unicode.utf8ToUtf16LeAlloc(alloc, line.items);
}

/// Trust UTF-8 arguments supplied by an embedding host on Windows.
pub export fn ghostty_init_utf8(argc: usize, argv: [*][*:0]u8) c_int {
    @import("c_api_error.zig").clear();
    assert(builtin.link_libc);

    const environ: std.process.Environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
        // Asserting libc means that we can fast-path all POSIX blocks
        .{ .block = .{ .slice = std.c.environ[0..env_len: {
            var len: usize = 0;
            while (std.c.environ[len]) |_| : (len += 1) {}
            break :env_len len;
        } :null] } }
    else
        // Anything that is not using PosixBlock is a global block for
        // purposes of initialization.
        .{ .block = .{ .use_global = true } };
    const args: std.process.Args = if (builtin.os.tag == .windows)
        .{ .vector = windowsCommandLineFromUtf8Args(argc, argv) catch |err| {
            @import("c_api_error.zig").set(err);
            std.log.err("failed to encode UTF-8 arguments error={}", .{err});
            return 1;
        } }
    else
        .{ .vector = argv[0..argc] };
    // Prepared arguments make this the same as an executable's startup.
    global.init(.{ .main = .{ .args = args, .environ = environ } }) catch |err| {
        @import("c_api_error.zig").set(err);
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}
