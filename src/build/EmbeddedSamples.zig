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
            if (builtin.os.tag == .windows) "powershell.exe" else "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            b.pathFromRoot("example/rust-egui-terminal/conpty.ps1"),
            "-Architecture",
            conpty_arch,
            "-Destination",
            b.getInstallPath(.bin, ""),
        });
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
        const sample = b.addExecutable(.{
            .name = "ghostty_win32",
            .root_module = b.createModule(.{
                .target = config.target,
                .optimize = config.optimize,
                .link_libc = true,
            }),
        });
        sample.root_module.addCSourceFile(.{
            .file = b.path("example/c-win32/src/main.c"),
            .flags = &.{ "-std=c11", "-D_CRT_SECURE_NO_WARNINGS" },
        });
        sample.root_module.addIncludePath(b.path("include"));
        sample.root_module.addObjectFile(lib_shared.implib.?);
        sample.root_module.linkSystemLibrary("user32", .{});
        sample.root_module.linkSystemLibrary("gdi32", .{});
        const sample_step = b.step("win32-sample", "Build the native Win32 OpenGL terminal sample");
        sample_step.dependOn(&conpty.step);
        sample_step.dependOn(&b.addInstallArtifact(sample, .{}).step);
        // The import library records ghostty.dll, irrespective of
        // the internal library's installed filename.
        sample_step.dependOn(&b.addInstallFileWithDir(lib_shared.output, .bin, "ghostty.dll").step);

        const egui_step = b.step("egui-sample", "Build the egui terminal sample");
        egui_step.dependOn(&conpty.step);
        resources.addStepDependencies(egui_step);
        const cargo = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--manifest-path",
            b.pathFromRoot("example/rust-egui-terminal/Cargo.toml"),
            "--release",
            "--target-dir",
            b.pathFromRoot(".zig-cache/egui-target"),
        });
        cargo.has_side_effects = true;
        cargo.setEnvironmentVariable("GHOSTTY_ROOT", b.pathFromRoot("."));
        cargo.setEnvironmentVariable("GHOSTTY_LIB_DIR", b.getInstallPath(.lib, ""));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_INCLUDE_DIR", b.pathFromRoot("include"));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_LIB_DIR", b.getInstallPath(.lib, ""));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_LIB_NAME", "ghostty-vt-static");
        cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.toml"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.lock"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/build.rs"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/src/main.rs"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/src/ghostty_shim.c"));
        cargo.addFileInput(b.path("include/ghostty.h"));
        cargo.step.dependOn(&import_lib_install.step);
        cargo.step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "ghostty-vt-static.lib",
        ).step);
        const egui_exe_install = b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathFromRoot(".zig-cache/egui-target/release/ghostty_egui.exe") },
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
    } else {
        const public_lib_install = b.addInstallFileWithDir(
            lib_shared.output,
            .lib,
            "libghostty.so",
        );
        b.getInstallStep().dependOn(&public_lib_install.step);

        const egui_step = b.step("egui-sample", "Build the egui terminal sample");
        resources.addStepDependencies(egui_step);
        const cargo = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--manifest-path",
            b.pathFromRoot("example/rust-egui-terminal/Cargo.toml"),
            "--release",
            "--target-dir",
            b.pathFromRoot(".zig-cache/egui-target"),
        });
        cargo.has_side_effects = true;
        cargo.setEnvironmentVariable("GHOSTTY_ROOT", b.pathFromRoot("."));
        cargo.setEnvironmentVariable("GHOSTTY_LIB_DIR", b.getInstallPath(.lib, ""));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_INCLUDE_DIR", b.pathFromRoot("include"));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_LIB_DIR", b.getInstallPath(.lib, ""));
        cargo.setEnvironmentVariable("NFM_GHOSTTY_VT_LIB_NAME", "ghostty-vt");
        cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.toml"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/Cargo.lock"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/build.rs"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/src/main.rs"));
        cargo.addFileInput(b.path("example/rust-egui-terminal/src/ghostty_shim.c"));
        cargo.addFileInput(b.path("include/ghostty.h"));
        cargo.step.dependOn(&public_lib_install.step);
        cargo.step.dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            "libghostty-vt.a",
        ).step);
        const egui_exe_install = b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathFromRoot(".zig-cache/egui-target/release/ghostty_egui") },
            .bin,
            "ghostty_egui",
        );
        egui_exe_install.step.dependOn(&cargo.step);
        egui_step.dependOn(&egui_exe_install.step);
    }
}

/// Additional GL symbols and WGL support for native Windows embedding.
pub fn linkWindowsOpenGL(b: *std.Build, step: *std.Build.Step.Compile) void {
    step.root_module.addIncludePath(b.path("vendor/glad/include"));
    if (step.kind == .lib) step.root_module.addCSourceFile(.{
        .file = b.path("vendor/glad/src/gl.c"),
        .flags = &.{},
    });
    step.root_module.addCSourceFile(.{ .file = b.path("src/renderer/opengl/wgl.c"), .flags = &.{} });
    step.root_module.linkSystemLibrary("opengl32", .{});
    step.root_module.linkSystemLibrary("gdi32", .{});
    step.root_module.linkSystemLibrary("user32", .{});
}
