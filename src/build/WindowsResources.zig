//! Compile a Windows terminfo database using Git/MSYS ncurses tools.
const std = @import("std");

pub fn compileTerminfo(b: *std.Build, source: std.Build.LazyPath, terminfo_share_dir: []const u8) !*std.Build.Step {
    const compiler = b.option([]const u8, "terminfo-compiler", "Path to tic for compiling the Windows terminfo database") orelse blk: {
        var search: std.ArrayList([]const u8) = .empty;
        defer search.deinit(b.allocator);
        inline for (.{ "ProgramFiles", "ProgramFiles(x86)" }) |key| {
            if (b.graph.environ_map.get(key)) |base| {
                try search.append(b.allocator, b.fmt("{s}/Git/usr/bin", .{base}));
            }
        }
        break :blk b.findProgram(&.{"tic"}, search.items) catch {
            std.log.err("Windows resources require tic: install Git for Windows or pass -Dterminfo-compiler=<path to tic>", .{});
            return error.TerminfoCompilerNotFound;
        };
    };
    const compile_step = b.addSystemCommand(&.{ compiler, "-x", "-o" });
    const database = compile_step.addOutputFileArg(terminfo_share_dir);
    compile_step.addFileArg(source);
    _ = compile_step.captureStdErr(.{});
    const install_step = b.addInstallDirectory(.{
        .source_dir = database,
        .install_dir = .prefix,
        .install_subdir = "share/terminfo",
    });
    return &install_step.step;
}
