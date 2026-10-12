//! Process identity and path conversion for host integration.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub fn identity(pid: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.pid_t) struct { pid: u64, created: u64 } {
    if (comptime builtin.os.tag != .windows) return .{ .pid = @intCast(pid), .created = 0 };
    const Api = struct {
        extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) u32;
        extern "kernel32" fn GetProcessTimes(std.os.windows.HANDLE, *std.os.windows.FILETIME, *std.os.windows.FILETIME, *std.os.windows.FILETIME, *std.os.windows.FILETIME) callconv(.winapi) i32;
    };
    var created: std.os.windows.FILETIME = undefined;
    var exited: std.os.windows.FILETIME = undefined;
    var kernel: std.os.windows.FILETIME = undefined;
    var user: std.os.windows.FILETIME = undefined;
    const timestamp = if (Api.GetProcessTimes(pid, &created, &exited, &kernel, &user) != 0)
        (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime
    else
        0;
    return .{ .pid = Api.GetProcessId(pid), .created = timestamp };
}

pub fn msysTerminfoPath(alloc: Allocator, path: []const u8) ![]const u8 {
    const drive = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    const result = try alloc.alloc(u8, path.len);
    if (drive) {
        result[0] = '/';
        result[1] = std.ascii.toLower(path[0]);
        @memcpy(result[2..], path[2..]);
    } else {
        @memcpy(result, path);
    }
    for (result) |*char| if (char.* == '\\') {
        char.* = '/';
    };
    return result;
}

test "Windows TERMINFO path supports MSYS ncurses" {
    const cases = .{
        .{ "C:/Program Files/Ghostty/share/terminfo", "/c/Program Files/Ghostty/share/terminfo" },
        .{ "G:\\src\\ghostty\\share\\terminfo", "/g/src/ghostty/share/terminfo" },
        .{ "\\\\server\\share\\terminfo", "//server/share/terminfo" },
        .{ "/c/ghostty/share/terminfo", "/c/ghostty/share/terminfo" },
    };
    inline for (cases) |case| {
        const result = try msysTerminfoPath(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
}

pub fn signalQuit(pipe: std.os.windows.HANDLE) void {
    const windows = @import("../os/windows.zig");
    const Api = struct {
        extern "kernel32" fn WriteFile(windows.HANDLE, [*]const u8, windows.DWORD, ?*windows.DWORD, ?*windows.OVERLAPPED) callconv(.winapi) windows.BOOL;
    };
    var written: windows.DWORD = 0;
    if (Api.WriteFile(pipe, "x", 1, &written, null) == windows.FALSE) {
        std.log.scoped(.io_exec).warn("error writing quit pipe err={}", .{windows.GetLastError()});
    }
}
