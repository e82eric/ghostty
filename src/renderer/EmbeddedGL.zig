//! Graphics API for hosts that embed libghostty and share their OpenGL
//! context with it (the egui sample). renderer.zig selects it in place of
//! OpenGL.zig for the embedded runtime.
//!
//! It wraps upstream's OpenGL backend instead of editing it: everything
//! that does not involve contexts or frame delivery forwards to `inner`.
//! Our own code creates a context that shares objects with the host's
//! (EGL on Linux, WGL on Windows) and hands each frame to the host as a
//! texture. Copied from upstream, and so to be compared with it when
//! syncing: createSharedContext (from OpenGL.init) and opengl/EmbeddedFrame.zig
//! (from opengl/Frame.zig).
const EmbeddedGL = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const OpenGL = @import("OpenGL.zig");
const HostContext = @import("opengl/HostContext.zig");
const Renderer = rendererpkg.GenericRenderer(EmbeddedGL);

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.opengl);

pub const GraphicsAPI = EmbeddedGL;
/// A copy of upstream's opengl/Frame.zig with the backend type changed,
/// because Frame.zig names OpenGL directly. The test at the end of this
/// file checks the copy still matches upstream.
pub const Frame = @import("opengl/EmbeddedFrame.zig");
pub const Target = OpenGL.Target;
pub const RenderPass = OpenGL.RenderPass;
pub const Pipeline = OpenGL.Pipeline;
pub const Buffer = OpenGL.Buffer;
pub const Sampler = OpenGL.Sampler;
pub const Texture = OpenGL.Texture;
pub const shaders = OpenGL.shaders;
pub const ImageTextureFormat = OpenGL.ImageTextureFormat;
pub const custom_shader_target = OpenGL.custom_shader_target;
pub const custom_shader_y_is_down = OpenGL.custom_shader_y_is_down;
pub const swap_chain_count = OpenGL.swap_chain_count;
pub const MIN_VERSION_MAJOR = OpenGL.MIN_VERSION_MAJOR;
pub const MIN_VERSION_MINOR = OpenGL.MIN_VERSION_MINOR;

comptime {
    // The generic renderer looks some declarations up with @hasDecl, so a
    // declaration upstream adds would otherwise be skipped here silently.
    for (@typeInfo(OpenGL).@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, "OpenGL")) continue;
        if (std.mem.eql(u8, decl.name, "prepareContext")) continue;
        if (!@hasDecl(EmbeddedGL, decl.name)) {
            @compileError("EmbeddedGL is missing OpenGL." ++ decl.name);
        }
    }
}

/// The app-wide render device. The host supplies its display along with
/// each surface's context, so each renderer creates its own upstream
/// device on that display (see init) and there is nothing to share here.
pub const Device = struct {
    pub const Options = struct {};

    pub fn init(alloc: Allocator, options: Options) !*Device {
        _ = options;
        return try alloc.create(Device);
    }

    pub fn deinit(self: *Device, alloc: Allocator) void {
        alloc.destroy(self);
    }
};

/// Upstream's backend. On Linux it holds our shared context and an
/// upstream device on the host's display; on Windows only the fields the
/// forwarded functions use are set.
inner: OpenGL,

/// The host's context, our WGL context on Windows, and the textures
/// handed to the host.
host: HostContext.State,

/// Alpha blending mode. The generic renderer sets this field directly
/// when the config changes; like OpenGL.zig, nothing here reads it.
blending: @FieldType(OpenGL, "blending"),

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !EmbeddedGL {
    _ = device;
    var host: HostContext.State = try .init(alloc, opts.rt_surface);
    errdefer host.deinit();
    const external = host.external orelse return error.OpenGLContextMustBeSet;

    var inner: OpenGL = .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = undefined,
        .egl_context = undefined,
    };
    if (comptime !is_windows) {
        const gl_device: *OpenGL.Device = try .init(alloc, .{
            .display = @ptrCast(@alignCast(external.display.?)),
        });
        errdefer gl_device.deinit(alloc);
        inner.device = gl_device;
        inner.egl_context = try createSharedContext(gl_device, external.context);
    }

    return .{ .inner = inner, .host = host, .blending = opts.config.blending };
}

pub fn deinit(self: *EmbeddedGL) void {
    self.host.deinit();
    if (comptime !is_windows) {
        const device: *OpenGL.Device = @constCast(self.inner.device);
        const alloc = self.inner.alloc;

        // Upstream releases whatever context is current, which on the
        // host's thread is the host's own; make that current again.
        const previous: Binding = .save();
        const ours = previous.context == @as(egl.c.EGLContext, self.inner.egl_context);
        self.inner.deinit();
        if (!ours) previous.restore(device.display);
        device.deinit(alloc);
    }
    self.* = undefined;
}

/// Create our context on the host's display, sharing objects with the
/// host's context. Copied from OpenGL.init, which creates an unshared one.
fn createSharedContext(
    device: *const OpenGL.Device,
    share: *anyopaque,
) !*egl.Context {
    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    const context = egl.Context.create(display, device.config, @ptrCast(share), &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    // The host calls us with its own context current; it must still be
    // current when we return.
    const previous: Binding = .save();
    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };
    previous.restore(display);

    return context;
}

/// The EGL binding current on the calling thread, so that the host's
/// context can be made current again after we borrow the thread.
const Binding = struct {
    display: egl.c.EGLDisplay,
    draw: egl.c.EGLSurface,
    read: egl.c.EGLSurface,
    context: egl.c.EGLContext,

    fn save() Binding {
        return .{
            .display = egl.c.eglGetCurrentDisplay(),
            .draw = egl.c.eglGetCurrentSurface(egl.c.EGL_DRAW),
            .read = egl.c.eglGetCurrentSurface(egl.c.EGL_READ),
            .context = egl.c.eglGetCurrentContext(),
        };
    }

    /// Restore the saved binding, or release the current context if
    /// nothing was current when it was saved.
    fn restore(self: Binding, fallback: *egl.Display) void {
        if (self.context == egl.c.EGL_NO_CONTEXT) {
            fallback.releaseCurrent();
            return;
        }
        _ = egl.c.eglMakeCurrent(self.display, self.draw, self.read, self.context);
    }
};

pub fn threadEnter(self: *EmbeddedGL, surface: *apprt.Surface) !void {
    if (comptime is_windows) return self.host.threadEnter(OpenGL.prepareContext);
    try self.inner.threadEnter(surface);
}

pub fn threadExit(self: *EmbeddedGL) void {
    self.host.threadExit();
    if (comptime !is_windows) self.inner.threadExit();
}

/// Hand a rendered target to the host as a texture it can sample.
pub fn present(
    self: *EmbeddedGL,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    _ = presentation_health;
    const frame = try self.host.exportFrame(target) orelse
        return error.OpenGLContextMustBeSet;
    return .{ .texture = frame };
}

/// A finished frame, taken by the host through ghostty_surface_take_gl_frame.
pub const ExportedFrame = union(enum) {
    texture: HostContext.TextureFrame,

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .texture => |v| v.deinit(),
        }
    }
};

/// Begin a frame.
pub inline fn beginFrame(
    self: *const EmbeddedGL,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

// Everything else is upstream's.

fn Return(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

pub fn surfaceSize(self: *const EmbeddedGL) Return(OpenGL.surfaceSize) {
    return self.inner.surfaceSize();
}

pub fn setViewport(self: *const EmbeddedGL, width: u32, height: u32) void {
    self.inner.setViewport(width, height);
}

pub fn drawFrameStart(self: *EmbeddedGL) void {
    self.inner.drawFrameStart();
}

pub fn drawFrameEnd(self: *EmbeddedGL) void {
    self.inner.drawFrameEnd();
}

pub fn initShaders(
    self: *const EmbeddedGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) Return(OpenGL.initShaders) {
    return self.inner.initShaders(alloc, custom_shaders);
}

pub fn initTarget(self: *const EmbeddedGL, width: usize, height: usize) Return(OpenGL.initTarget) {
    return self.inner.initTarget(width, height);
}

pub fn bufferOptions(self: EmbeddedGL) Return(OpenGL.bufferOptions) {
    return self.inner.bufferOptions();
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn textureOptions(self: EmbeddedGL) Return(OpenGL.textureOptions) {
    return self.inner.textureOptions();
}

pub fn samplerOptions(self: EmbeddedGL) Return(OpenGL.samplerOptions) {
    return self.inner.samplerOptions();
}

pub fn imageTextureOptions(
    self: EmbeddedGL,
    format: ImageTextureFormat,
    srgb: bool,
) Return(OpenGL.imageTextureOptions) {
    return self.inner.imageTextureOptions(format, srgb);
}

pub fn initAtlasTexture(
    self: *const EmbeddedGL,
    atlas: *const font.Atlas,
) Return(OpenGL.initAtlasTexture) {
    return self.inner.initAtlasTexture(atlas);
}

test "opengl/EmbeddedFrame.zig matches upstream opengl/Frame.zig" {
    // EmbeddedFrame.zig is Frame.zig with its backend type changed (see
    // the header of EmbeddedFrame.zig for why). Apply the same
    // substitutions to upstream's file and compare everything after the
    // header, so an upstream change to Frame.zig fails here instead of
    // being silently missed.
    const testing = std.testing;
    const alloc = testing.allocator;

    const substitutions = [_][2][]const u8{
        .{ "Renderer(OpenGL)", "Renderer(EmbeddedGL)" },
        .{
            "const OpenGL = @import(\"../OpenGL.zig\");",
            "const EmbeddedGL = @import(\"../EmbeddedGL.zig\");",
        },
        .{ "OpenGL.ExportedFrame", "EmbeddedGL.ExportedFrame" },
    };

    var expected = try frameBody(alloc, @embedFile("opengl/Frame.zig"));
    defer alloc.free(expected);
    for (substitutions) |s| {
        const next = try std.mem.replaceOwned(u8, alloc, expected, s[0], s[1]);
        alloc.free(expected);
        expected = next;
    }

    const actual = try frameBody(alloc, @embedFile("opengl/EmbeddedFrame.zig"));
    defer alloc.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

/// The code of a Frame.zig copy without its header comment (everything
/// from `const Self = @This();`), with carriage returns removed so that a
/// file saved with CRLF line endings still compares equal.
fn frameBody(alloc: Allocator, source: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, source, "const Self = @This();") orelse
        return error.FrameBodyNotFound;
    return std.mem.replaceOwned(u8, alloc, source[start..], "\r", "");
}
