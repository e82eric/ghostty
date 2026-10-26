//! Build and install the embedded terminal samples and their runtime dependencies.
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
        conpty.addFileArg(b.path("example/rust-egui-terminal/conpty.ps1"));
        conpty.addArgs(&.{ "-Architecture", conpty_arch, "-Destination" });
        conpty.addDirectoryArg2(b.graph.path(.install_bin, ""), .{ .make_absolute = true });
        conpty.has_side_effects = true;
        const conpty_step = b.step("conpty", "Install the pinned Windows ConPTY DLL and console host");
        conpty_step.dependOn(&conpty.step);
        b.getInstallStep().dependOn(&conpty.step);
        const import_lib_install = b.addInstallFileWithDir(
            lib_shared.implib.?,
            .lib,
            "ghostty.lib",
        );
        b.getInstallStep().dependOn(&import_lib_install.step);

        const egui_step = b.step("egui-sample", "Build the egui terminal sample");
        egui_step.dependOn(&conpty.step);
        resources.addStepDependencies(egui_step);
        const cargo = cargoBuild(b, "ghostty-vt-static");
        cargo.step.dependOn(&import_lib_install.step);
        cargo.step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "ghostty-vt-static.lib",
        ).step);
        const egui_exe_install = b.addInstallFileWithDir(
            b.path(".zig-cache/egui-target/release/ghostty_egui.exe"),
            .bin,
            "ghostty_egui.exe",
        );
        egui_exe_install.step.dependOn(&cargo.step);
        egui_exe_install.step.dependOn(&b.addInstallFileWithDir(
            lib_shared.output,
            .bin,
            "ghostty.dll",
        ).step);
        egui_step.dependOn(&egui_exe_install.step);
        // Lua modules a config can require, e.g. require("ghostty.git").
        egui_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("example/rust-egui-terminal/lua"),
            .install_dir = .prefix,
            .install_subdir = "share/ghostty-egui/lua",
        }).step);
    } else {
        const public_lib_install = b.addInstallFileWithDir(
            lib_shared.output,
            .lib,
            "libghostty.so",
        );
        b.getInstallStep().dependOn(&public_lib_install.step);

        const egui_step = b.step("egui-sample", "Build the egui terminal sample");
        resources.addStepDependencies(egui_step);
        const cargo = cargoBuild(b, "ghostty-vt");
        cargo.step.dependOn(&public_lib_install.step);
        cargo.step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "libghostty-vt.a",
        ).step);
        const egui_exe_install = b.addInstallFileWithDir(
            b.path(".zig-cache/egui-target/release/ghostty_egui"),
            .bin,
            "ghostty_egui",
        );
        egui_exe_install.step.dependOn(&cargo.step);
        egui_step.dependOn(&egui_exe_install.step);
        // The shell-side client for the picker socket.
        const npick_install = b.addInstallFileWithDir(
            b.path(".zig-cache/egui-target/release/npick"),
            .bin,
            "npick",
        );
        npick_install.step.dependOn(&cargo.step);
        egui_step.dependOn(&npick_install.step);
        // Lua modules a config can require, e.g. require("ghostty.git").
        egui_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("example/rust-egui-terminal/lua"),
            .install_dir = .prefix,
            .install_subdir = "share/ghostty-egui/lua",
        }).step);
    }
}

/// Install paths are only known while the build runs, so they reach the
/// build scripts as cargo `[env]` settings rather than environment variables.
fn cargoBuild(b: *std.Build, vt_lib_name: []const u8) *std.Build.Step.Run {
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path" });
    cargo.addFileArg(b.path("example/rust-egui-terminal/Cargo.toml"));
    cargo.addArgs(&.{ "--release", "--target-dir" });
    cargo.addDirectoryArg2(b.path(".zig-cache/egui-target"), .{ .make_absolute = true });
    cargoEnv(cargo, "GHOSTTY_LIB_DIR", b.graph.path(.install_lib, ""));
    cargoEnv(cargo, "NFM_GHOSTTY_VT_INCLUDE_DIR", b.path("include"));
    cargoEnv(cargo, "NFM_GHOSTTY_VT_LIB_DIR", b.graph.path(.install_lib, ""));
    cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_LIB_NAME", vt_lib_name);
    cargo.has_side_effects = true;
    cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.toml"));
    cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.lock"));
    cargo.addFileInput(b.path("example/rust-egui-terminal/build.rs"));
    cargo.addFileInput(b.path("example/rust-egui-terminal/src/main.rs"));
    cargo.addFileInput(b.path("example/rust-egui-terminal/src/ghostty_shim.c"));
    cargo.addFileInput(b.path("include/ghostty.h"));
    return cargo;
}

/// A TOML literal string keeps Windows backslashes as written.
fn cargoEnv(cargo: *std.Build.Step.Run, key: []const u8, dir: std.Build.LazyPath) void {
    cargo.addArg("--config");
    cargo.addDirectoryArg2(dir, .{
        .prefix = cargo.step.owner.fmt("env.{s}='", .{key}),
        .suffix = "'",
        .make_absolute = true,
    });
}
