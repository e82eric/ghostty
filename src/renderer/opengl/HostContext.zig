//! OpenGL contexts shared with the embedding host.
//!
//! OpenGL.zig calls into this file through one-line hooks so that the
//! embedding support stays out of upstream's function bodies.
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const OutputPool = @import("OutputPool.zig");
const Target = @import("Target.zig");

pub const TextureFrame = OutputPool.TextureFrame;

const is_windows = builtin.os.tag == .windows;

extern fn ghostty_wgl_create(*anyopaque, *anyopaque) ?*anyopaque;
extern fn ghostty_wgl_enter(*anyopaque, c_int) c_int;
extern fn ghostty_wgl_leave() void;
extern fn ghostty_wgl_destroy(*anyopaque) void;
extern fn ghostty_wgl_proc([*:0]const u8) ?*const anyopaque;

pub const ExternalContext = struct {
    window: ?*anyopaque,
    display: ?*anyopaque,
    context: *anyopaque,
};

pub fn externalContext(surface: anytype) ?ExternalContext {
    if (comptime !@hasField(@TypeOf(surface.*), "platform")) return null;
    return switch (surface.platform) {
        .opengl => |v| .{
            .window = v.window,
            .display = v.display,
            .context = v.context,
        },
        else => null,
    };
}

/// Per-renderer state for rendering into a host's shared OpenGL context.
pub const State = struct {
    /// The host's context, when it shares one with us.
    external: ?ExternalContext = null,

    /// Textures handed to the host, when it shares its context.
    output_pool: ?*OutputPool = null,

    /// Our WGL context on Windows, which always shares the host's.
    wgl_context: ?*anyopaque = null,
    wgl_vsync: bool = true,

    pub fn init(alloc: Allocator, surface: anytype, vsync: bool) !State {
        const external = externalContext(surface);
        if (external) |v| {
            // On EGL a shared context must live on the host's display,
            // which the embedded apprt passes to the device (see
            // renderDeviceOptions).
            if (comptime !is_windows) {
                if (v.display == null) return error.EGLDisplayMustBeSet;
            }
        }

        const output_pool = if (external != null) try OutputPool.create(alloc) else null;
        errdefer if (output_pool) |v| v.destroy();

        return .{
            .external = external,
            .output_pool = output_pool,
            .wgl_context = if (comptime is_windows) try createWgl(external) else null,
            .wgl_vsync = vsync,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.output_pool) |v| v.destroy();
        if (comptime is_windows) ghostty_wgl_destroy(self.wgl_context.?);
    }

    /// The context an EGL context must share objects with, if any.
    pub fn eglShareContext(self: *const State) ?*anyopaque {
        return if (self.external) |v| v.context else null;
    }

    /// Make our WGL context current on the render thread (Windows only;
    /// elsewhere the caller makes its EGL context current).
    pub fn threadEnter(self: *State, comptime prepare: anytype) !void {
        if (comptime !is_windows) unreachable;
        if (ghostty_wgl_enter(self.wgl_context.?, @intFromBool(self.wgl_vsync)) == 0)
            return error.WGLMakeCurrentFailed;
        errdefer ghostty_wgl_leave();
        try prepare(&ghostty_wgl_proc);
    }

    /// Release render thread resources, and on Windows our WGL context.
    /// Elsewhere the caller releases its EGL context afterwards.
    pub fn threadExit(self: *State) void {
        if (self.output_pool) |v| v.deinitResources();
        if (comptime !is_windows) return;
        gl.finish();
        ghostty_wgl_leave();
        gl.glad.unload();
    }

    /// Export a frame as a texture the host can sample, or null when
    /// there is no host context and the frame is exported as usual.
    pub fn exportFrame(self: *State, target: Target) !?TextureFrame {
        const pool = self.output_pool orelse return null;
        return try pool.exportFrame(target);
    }
};

/// Create a WGL context sharing objects with the host's context.
fn createWgl(external: ?ExternalContext) !*anyopaque {
    const v = external orelse return error.OpenGLContextMustBeSet;
    const window = v.window orelse return error.HWNDMustBeSet;
    return ghostty_wgl_create(window, v.context) orelse error.WGLContextCreationFailed;
}
