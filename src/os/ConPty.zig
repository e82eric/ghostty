//! Resolve an application-local ConPTY DLL, falling back to the system API.
const ConPtyApi = @This();
const std = @import("std");
const windows = @import("windows.zig");
const log = std.log.scoped(.pty);

const CreatePseudoConsoleFn = *const fn (
    windows.COORD,
    windows.HANDLE,
    windows.HANDLE,
    windows.DWORD,
    *windows.HPCON,
) callconv(.winapi) windows.HRESULT;
const ResizePseudoConsoleFn = *const fn (
    windows.HPCON,
    windows.COORD,
) callconv(.winapi) windows.HRESULT;
const ClosePseudoConsoleFn = *const fn (windows.HPCON) callconv(.winapi) void;

module: ?std.os.windows.HMODULE = null,
create: CreatePseudoConsoleFn = windows.exp.kernel32.CreatePseudoConsole,
resize: ResizePseudoConsoleFn = windows.exp.kernel32.ResizePseudoConsole,
close: ClosePseudoConsoleFn = windows.exp.kernel32.ClosePseudoConsole,

pub fn load() ConPtyApi {
    const module = LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll"),
        null,
        0x00000200,
    ) orelse {
        log.info("using system ConPTY", .{});
        return .{};
    };

    const create = GetProcAddress(
        module,
        "CreatePseudoConsole",
    ) orelse return invalidSidecar(module, "CreatePseudoConsole");
    const resize = GetProcAddress(
        module,
        "ResizePseudoConsole",
    ) orelse return invalidSidecar(module, "ResizePseudoConsole");
    const close = GetProcAddress(
        module,
        "ClosePseudoConsole",
    ) orelse return invalidSidecar(module, "ClosePseudoConsole");

    log.info("using side-by-side conpty.dll", .{});
    return .{
        .module = module,
        .create = @ptrCast(create),
        .resize = @ptrCast(resize),
        .close = @ptrCast(close),
    };
}

fn invalidSidecar(module: std.os.windows.HMODULE, symbol: []const u8) ConPtyApi {
    _ = FreeLibrary(module);
    log.warn("side-by-side conpty.dll has no {s}; using system ConPTY", .{symbol});
    return .{};
}

pub fn deinit(self: *ConPtyApi) void {
    if (self.module) |module| {
        _ = FreeLibrary(module);
    }
    self.* = undefined;
}

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: windows.LPCWSTR,
    hFile: ?windows.HANDLE,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?std.os.windows.HMODULE;
extern "kernel32" fn GetProcAddress(
    hModule: std.os.windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?std.os.windows.FARPROC;
extern "kernel32" fn FreeLibrary(hLibModule: std.os.windows.HMODULE) callconv(.winapi) windows.BOOL;
