//! OpenGL contexts shared with the embedding host.
const gl = @import("opengl");

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

/// Create a WGL context sharing objects with the host's context.
pub fn create(external: ?ExternalContext) !*anyopaque {
    const v = external orelse return error.OpenGLContextMustBeSet;
    const window = v.window orelse return error.HWNDMustBeSet;
    return ghostty_wgl_create(window, v.context) orelse error.WGLContextCreationFailed;
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
