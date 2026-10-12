//! Shared host OpenGL contexts and native Windows presentation.
const gl = @import("opengl");
const Target = @import("Target.zig");

extern fn ghostty_wgl_create(*anyopaque, ?*anyopaque) ?*anyopaque;
extern fn ghostty_wgl_enter(*anyopaque, c_int) c_int;
extern fn ghostty_wgl_leave() void;
extern fn ghostty_wgl_destroy(*anyopaque) void;
extern fn ghostty_wgl_swap(*anyopaque) c_int;
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

pub fn create(surface: anytype, external: ?ExternalContext) !*anyopaque {
    const window, const share = if (external) |v|
        .{ v.window orelse return error.HWNDMustBeSet, @as(?*anyopaque, v.context) }
    else
        .{ surface.platform.windows.hwnd, @as(?*anyopaque, null) };

    return ghostty_wgl_create(window, share) orelse error.WGLContextCreationFailed;
}

pub fn destroy(context: *anyopaque) void {
    ghostty_wgl_destroy(context);
}

pub fn enter(context: *anyopaque, vsync: bool, comptime prepare: anytype) !void {
    if (ghostty_wgl_enter(context, @intFromBool(vsync)) == 0) return error.WGLMakeCurrentFailed;
    errdefer ghostty_wgl_leave();
    try prepare(&ghostty_wgl_proc);
}

pub fn leave() void {
    gl.finish();
    ghostty_wgl_leave();
    gl.glad.unload();
}

pub fn present(context: *anyopaque, target: Target) !void {
    // Copy encoded sRGB pixels on the GPU to the native window backbuffer.
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch {};
    gl.glad.context.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, target.framebuffer.id);
    gl.glad.context.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, 0);
    defer gl.glad.context.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
    try gl.blitFramebuffer(0, 0, @intCast(target.width), @intCast(target.height), 0, 0, @intCast(target.width), @intCast(target.height), .{ .color_buffer_bit = true }, .nearest);
    if (ghostty_wgl_swap(context) == 0) return error.WGLSwapFailed;
}

/// Consume direct Win32 presentation, otherwise leave normal frame export alone.
pub fn completeFrame(renderer: anytype, target: Target) bool {
    if (!renderer.api.directPresentation()) return false;
    const Health = @import("../../renderer.zig").Health;
    const health: Health = if (renderer.api.presentDirect(target)) .healthy else |err| failed: {
        @import("std").log.scoped(.opengl).err("failed to present Win32 frame: {}", .{err});
        break :failed .unhealthy;
    };
    // Keep the existing conservative completion contract for reusable frames.
    gl.finish();
    renderer.frameCompleted(health);
    return true;
}
