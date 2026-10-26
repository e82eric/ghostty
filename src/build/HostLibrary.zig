//! Install the embedding library, VT library, resources, and Windows ConPTY
//! runtime that external hosts such as nterm build against.
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");
const GhosttyLib = @import("GhosttyLib.zig");
const GhosttyLibVt = @import("GhosttyLibVt.zig");
const GhosttyResources = @import("GhosttyResources.zig");

/// Called for non-Darwin embedded-library builds after the core libraries exist.
pub fn add(
    b: *std.Build,
    config: *const Config,
    lib_shared: GhosttyLib,
    libghostty_vt_static: GhosttyLibVt,
    resources: GhosttyResources,
) !void {
    const host_step = b.step("host-lib", "Install the libraries and resources an embedding host links against");
    resources.addStepDependencies(host_step);

    if (config.target.result.os.tag == .windows) {
        const conpty_arch = switch (config.target.result.cpu.arch) {
            .x86_64 => "x64",
            .x86 => "x86",
            .aarch64 => "arm64",
            else => return error.UnsupportedConPtyArchitecture,
        };
        const conpty = b.addSystemCommand(&.{
            if (builtin.target.os.tag == .windows) "powershell.exe" else "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        });
        conpty.addFileArg(b.path("dist/windows/conpty.ps1"));
        conpty.addArgs(&.{ "-Architecture", conpty_arch, "-Destination" });
        conpty.addDirectoryArg2(b.graph.path(.install_bin, ""), .{ .make_absolute = true });
        conpty.has_side_effects = true;
        const conpty_step = b.step("conpty", "Install the pinned Windows ConPTY DLL and console host");
        conpty_step.dependOn(&conpty.step);
        b.getInstallStep().dependOn(&conpty.step);
        host_step.dependOn(&conpty.step);

        const import_lib_install = b.addInstallFileWithDir(
            lib_shared.implib.?,
            .lib,
            "ghostty.lib",
        );
        b.getInstallStep().dependOn(&import_lib_install.step);
        host_step.dependOn(&import_lib_install.step);
        host_step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "ghostty-vt-static.lib",
        ).step);
        host_step.dependOn(&b.addInstallFileWithDir(
            lib_shared.output,
            .bin,
            "ghostty.dll",
        ).step);
    } else {
        const public_lib_install = b.addInstallFileWithDir(
            lib_shared.output,
            .lib,
            "libghostty.so",
        );
        b.getInstallStep().dependOn(&public_lib_install.step);
        host_step.dependOn(&public_lib_install.step);
        host_step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "libghostty-vt.a",
        ).step);
    }
}
