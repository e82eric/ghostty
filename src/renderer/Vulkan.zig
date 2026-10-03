//! Embedded wgpu backend. GPU operations execute on the host's shared Vulkan
//! device; terminal shaping and render scheduling remain in the Zig core.
const Self = @This();
const std = @import("std");
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const config = @import("../config.zig");
const font = @import("../font/main.zig");
const Allocator = std.mem.Allocator;
pub const GraphicsAPI = Self;
pub const swap_chain_count = 3;
pub const custom_shader_target: @import("shadertoy.zig").Target = .spirv;
pub const custom_shader_y_is_down = true;

/// Versioned host dispatch table. Resources belong to the host, whose device
/// must outlive every surface and frame lease. A zero result signals failure.
pub const Driver = extern struct {
    version: u32,
    context: *anyopaque,
    call: *const fn (*anyopaque, u32, *const [12]usize) callconv(.c) usize,
};
threadlocal var current: ?*const Driver = null;
fn invoke(driver: *const Driver, op: u32, args: [12]usize) !usize {
    const result = driver.call(driver.context, op, &args);
    if (result == 0) return error.VulkanHostFailed;
    return result;
}
fn active() *const Driver {
    return current orelse @panic("Vulkan renderer thread not entered");
}
fn args0(a: usize) [12]usize {
    var a_ = [_]usize{0} ** 12;
    a_[0] = a;
    return a_;
}
fn release(driver: *const Driver, handle: usize) void {
    _ = driver.call(driver.context, 0, &args0(handle));
}

driver: *const Driver,
blending: config.Config.AlphaBlending,
width: u32 = 1,
height: u32 = 1,

pub fn init(_: Allocator, opts: renderer.Options) !Self {
    const driver = switch (opts.rt_surface.platform) {
        .wgpu => |v| v.driver,
        else => return error.VulkanHostRequired,
    };
    if (driver.version != 1) return error.VulkanDriverVersionMismatch;
    return .{ .driver = driver, .blending = opts.config.blending };
}
pub fn deinit(_: *Self) void {}
pub fn threadEnter(self: *Self, _: *@import("../apprt.zig").Surface) !void {
    current = self.driver;
}
pub fn threadExit(_: *Self) void {
    current = null;
}
pub fn surfaceSize(self: *const Self) !struct { width: u32, height: u32 } {
    return .{ .width = self.width, .height = self.height };
}
pub fn setViewport(self: *Self, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
}
pub fn drawFrameStart(self: *Self) void {
    current = self.driver;
}
pub fn drawFrameEnd(_: *Self) void {}
pub fn initShaders(_: *const Self, alloc: Allocator, custom: []const [:0]const u8) !shaders.Shaders {
    return shaders.Shaders.init(alloc, custom);
}
pub fn initTarget(self: *const Self, width: usize, height: usize) !Target {
    return Target.init(width, height, self.blending.isLinear());
}
pub fn beginFrame(_: *const Self, owner: *renderer.GenericRenderer(Self), target: *Target) !Frame {
    return .{ .owner = owner, .target = target, .handle = try invoke(active(), 5, args0(target.texture.handle)) };
}
pub fn uniformBufferOptions(_: Self) BufferOptions {
    return .{ .uniform = true };
}
pub fn fgBufferOptions(_: Self) BufferOptions {
    return .{};
}
pub fn bgBufferOptions(_: Self) BufferOptions {
    return .{};
}
pub fn imageBufferOptions(_: Self) BufferOptions {
    return .{};
}
pub fn bgImageBufferOptions(_: Self) BufferOptions {
    return .{};
}
pub fn textureOptions(self: Self) Texture.Options {
    return .{ .format = .rgba, .srgb = self.blending.isLinear() };
}
pub fn samplerOptions(_: Self) Sampler.Options {
    return .{};
}
pub const ImageTextureFormat = enum { gray, rgba, bgra };
pub fn imageTextureOptions(_: Self, format: ImageTextureFormat, srgb: bool) Texture.Options {
    return .{ .format = format, .srgb = srgb };
}
pub fn initAtlasTexture(_: *const Self, atlas: *const font.Atlas) Texture.Error!Texture {
    return Texture.init(.{ .format = switch (atlas.format) {
        .grayscale => .gray,
        .bgra => .bgra,
        else => return error.VulkanHostFailed,
    }, .srgb = atlas.format == .bgra }, atlas.size, atlas.size, null);
}

pub const Resource = struct { handle: usize, driver: *const Driver };
pub const BufferOptions = struct { uniform: bool = false };
pub fn Buffer(comptime T: type) type {
    return struct {
        const B = @This();
        buffer: Resource,
        len: usize,
        opts: BufferOptions,
        pub fn init(opts: BufferOptions, len: usize) !B {
            var a = args0(@max(32, len * @sizeOf(T)));
            a[1] = @intFromBool(opts.uniform);
            return .{ .buffer = .{ .handle = try invoke(active(), 1, a), .driver = active() }, .len = len, .opts = opts };
        }
        pub fn initFill(opts: BufferOptions, data: []const T) !B {
            var b = try B.init(opts, data.len);
            errdefer b.deinit();
            try b.sync(data);
            return b;
        }
        pub fn deinit(self: B) void {
            release(self.buffer.driver, self.buffer.handle);
        }
        pub fn sync(self: *B, data: []const T) !void {
            if (data.len > self.len) {
                const replacement = try B.init(self.opts, data.len * 2);
                self.deinit();
                self.* = replacement;
            }
            try self.write(0, data);
        }
        fn write(self: *B, offset: usize, data: []const T) !void {
            if (data.len == 0) return;
            var a = args0(self.buffer.handle);
            a[1] = offset;
            a[2] = @intFromPtr(data.ptr);
            a[3] = data.len * @sizeOf(T);
            _ = try invoke(self.buffer.driver, 2, a);
        }
        pub fn syncFromArrayLists(self: *B, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var len: usize = 0;
            for (lists) |list| len += list.items.len;
            if (len > self.len) {
                const replacement = try B.init(self.opts, len * 2);
                self.deinit();
                self.* = replacement;
            }
            var offset: usize = 0;
            for (lists) |list| {
                try self.write(offset * @sizeOf(T), list.items);
                offset += list.items.len;
            }
            return len;
        }
    };
}
pub const Texture = struct {
    resource: Resource,
    width: usize,
    height: usize,
    format: ImageTextureFormat,
    pub const Error = error{VulkanHostFailed};
    pub const Options = struct { format: ImageTextureFormat, srgb: bool = false };
    pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Texture {
        var a = args0(width);
        a[1] = height;
        a[2] = @intFromEnum(opts.format);
        a[3] = @intFromBool(opts.srgb);
        if (data) |d| {
            a[4] = @intFromPtr(d.ptr);
            a[5] = d.len;
        }
        return .{ .resource = .{ .handle = try invoke(active(), 3, a), .driver = active() }, .width = width, .height = height, .format = opts.format };
    }
    pub fn deinit(self: Texture) void {
        release(self.resource.driver, self.resource.handle);
    }
    pub fn replaceRegion(self: Texture, x: usize, y: usize, width: usize, height: usize, data: []const u8) Error!void {
        var a = args0(self.resource.handle);
        a[1] = x;
        a[2] = y;
        a[3] = width;
        a[4] = height;
        a[5] = @intFromPtr(data.ptr);
        a[6] = data.len;
        _ = try invoke(self.resource.driver, 4, a);
    }
};
pub const Sampler = struct {
    pub const Options = struct {};
    pub fn init(_: Options) !Sampler {
        return .{};
    }
    pub fn deinit(_: Sampler) void {}
};
pub const Target = struct {
    texture: Resource,
    width: usize,
    height: usize,
    fn init(width: usize, height: usize, srgb: bool) !Target {
        var a = args0(width);
        a[1] = height;
        a[2] = 1;
        a[3] = @intFromBool(srgb);
        return .{ .texture = .{ .handle = try invoke(active(), 3, a), .driver = active() }, .width = width, .height = height };
    }
    pub fn deinit(self: *Target) void {
        release(self.texture.driver, self.texture.handle);
    }
};
pub const Pipeline = struct {
    resource: Resource,
    kind: usize,
    fn init(kind: usize, source: []const u8) !Pipeline {
        var a = args0(kind);
        a[1] = @intFromPtr(source.ptr);
        a[2] = source.len;
        return .{ .resource = .{ .handle = try invoke(active(), 8, a), .driver = active() }, .kind = kind };
    }
    pub fn deinit(self: Pipeline) void {
        release(self.resource.driver, self.resource.handle);
    }
};
pub const shaders = struct {
    const types = @import("opengl/shaders.zig");
    pub const Uniforms = types.Uniforms;
    pub const CellText = types.CellText;
    pub const CellBg = types.CellBg;
    pub const Image = types.Image;
    pub const BgImage = types.BgImage;
    pub const Shaders = struct {
        pipelines: struct { bg_color: Pipeline, cell_bg: Pipeline, cell_text: Pipeline, image: Pipeline, bg_image: Pipeline },
        post_pipelines: []const Pipeline = &.{},
        defunct: bool = false,
        pub const uninit: Shaders = .{ .pipelines = undefined, .defunct = true };
        fn init(alloc: Allocator, custom: []const [:0]const u8) !Shaders {
            var result: Shaders = .{ .pipelines = undefined };
            var n: usize = 0;
            errdefer inline for (std.meta.fields(@TypeOf(result.pipelines)), 0..) |field, i| {
                if (i < n) @field(result.pipelines, field.name).deinit();
            };
            inline for (std.meta.fields(@TypeOf(result.pipelines)), 0..) |field, i| {
                @field(result.pipelines, field.name) = try Pipeline.init(i, &.{});
                n += 1;
            }
            const post = try alloc.alloc(Pipeline, custom.len);
            errdefer alloc.free(post);
            var initialized: usize = 0;
            errdefer for (post[0..initialized]) |p| p.deinit();
            for (custom, post) |code, *p| {
                p.* = try Pipeline.init(5, code);
                initialized += 1;
            }
            result.post_pipelines = post;
            return result;
        }
        pub fn deinit(self: *Shaders, alloc: Allocator) void {
            if (self.defunct) return;
            self.defunct = true;
            inline for (std.meta.fields(@TypeOf(self.pipelines))) |field| @field(self.pipelines, field.name).deinit();
            for (self.post_pipelines) |p| p.deinit();
            alloc.free(self.post_pipelines);
        }
    };
};
threadlocal var encoding: usize = 0;
pub const RenderPass = struct {
    target: usize,
    clear: ?[4]f32,
    pub const Options = struct {
        pub const Attachment = struct {
            target: union(enum) { target: Target, texture: Texture },
            clear_color: ?[4]f32 = null,
        };
    };
    pub const Step = struct {
        pipeline: Pipeline,
        uniforms: ?Resource = null,
        buffers: []const ?Resource = &.{},
        textures: []const ?Texture = &.{},
        samplers: []const ?Sampler = &.{},
        draw: struct { type: enum { triangle, triangle_strip }, vertex_count: usize, instance_count: usize = 1 },
    };
    pub fn step(self: *RenderPass, s: Step) void {
        if (s.draw.instance_count == 0) return;
        var a = args0(encoding);
        a[1] = self.target;
        a[2] = s.pipeline.resource.handle;
        a[3] = if (s.uniforms) |v| v.handle else 0;
        for (s.buffers[0..@min(2, s.buffers.len)], 0..) |b, i| a[4 + i] = if (b) |v| v.handle else 0;
        for (s.textures[0..@min(2, s.textures.len)], 0..) |t, i| a[6 + i] = if (t) |v| v.resource.handle else 0;
        a[8] = s.draw.vertex_count;
        a[9] = s.draw.instance_count;
        if (self.clear) |*c| a[10] = @intFromPtr(c);
        _ = invoke(active(), 6, a) catch {
            std.log.err("Vulkan render step failed", .{});
            return;
        };
        self.clear = null;
    }
    pub fn complete(_: *const RenderPass) void {}
};
pub const Frame = struct {
    owner: *renderer.GenericRenderer(Self),
    target: *Target,
    handle: usize,
    pub fn renderPass(self: *const Frame, attachments: []const RenderPass.Options.Attachment) RenderPass {
        encoding = self.handle;
        return .{ .target = switch (attachments[0].target) {
            .target => |t| t.texture.handle,
            .texture => |t| t.resource.handle,
        }, .clear = attachments[0].clear_color };
    }
    pub fn complete(self: *const Frame, _: bool) void {
        var a = args0(self.handle);
        a[1] = self.target.texture.handle;
        const handle = invoke(self.target.texture.driver, 7, a) catch {
            self.owner.frameCompleted(.unhealthy);
            return;
        };
        self.owner.pushFrame(.{ .texture = .{ .resource = .{ .driver = self.target.texture.driver, .handle = handle }, .width = @intCast(self.target.width), .height = @intCast(self.target.height) } });
        _ = self.owner.surface_mailbox.push(.redraw, .{ .forever = {} });
        self.owner.frameCompleted(.healthy);
    }
};
pub const ExportedFrame = union(enum) {
    texture: struct {
        resource: Resource,
        width: u32,
        height: u32,
        generation: u64 = 0,
        pub fn deinit(self: @This()) void {
            release(self.resource.driver, self.resource.handle);
        }
    },
    pub fn deinit(self: ExportedFrame) void {
        self.texture.deinit();
    }
};
