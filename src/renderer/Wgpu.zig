//! Graphics API for hosts that render with wgpu (the egui sample). Every GPU
//! operation is forwarded through a dispatch table to the host, which
//! executes it on the same wgpu device and queue it uses for its own UI, so
//! finished frames are host textures and nothing is shared across devices or
//! APIs. Terminal shaping and render scheduling remain in the Zig core.
//!
//! The host's dispatch table is versioned. See ghostty_wgpu_driver_s in
//! include/ghostty.h for the operation list, and the host's gpu/bridge.rs for
//! the argument layouts, which must match the calls below.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const config = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

const log = std.log.scoped(.wgpu);

pub const GraphicsAPI = Self;

/// One frame state is enough: the host stages every buffer and texture write
/// on its queue, so the CPU-side state can be reused as soon as a frame is
/// submitted, and the host renders each frame into its own pooled texture.
pub const swap_chain_count = 1;
pub const custom_shader_target: shadertoy.Target = .spirv;
pub const custom_shader_y_is_down = true;

/// Must match the host's dispatch table version.
pub const driver_version = 2;

/// Versioned host dispatch table. Resources belong to the host, whose device
/// must outlive every surface and frame lease. A zero result signals failure.
pub const Driver = extern struct {
    version: u32,
    context: *anyopaque,
    call: *const fn (*anyopaque, u32, *const [12]usize) callconv(.c) usize,
};

/// Host operations. Keep in sync with gpu/bridge.rs.
const Op = enum(u32) {
    release = 0,
    create_buffer = 1,
    write_buffer = 2,
    create_texture = 3,
    write_texture = 4,
    begin_frame = 5,
    draw = 6,
    submit_frame = 7,
    create_pipeline = 8,
    end_pass = 9,
};

threadlocal var current: ?*const Driver = null;

fn invoke(driver: *const Driver, op: Op, args: [12]usize) !usize {
    const result = driver.call(driver.context, @intFromEnum(op), &args);
    if (result == 0) return error.WgpuHostFailed;
    return result;
}

fn active() *const Driver {
    return current orelse @panic("wgpu renderer thread not entered");
}

fn args0(a: usize) [12]usize {
    var a_ = [_]usize{0} ** 12;
    a_[0] = a;
    return a_;
}

fn release(driver: *const Driver, handle: usize) void {
    _ = driver.call(driver.context, @intFromEnum(Op.release), &args0(handle));
}

/// The app-wide render device. The host's dispatch table arrives with each
/// surface, so there is nothing to share here.
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

driver: *const Driver,
blending: config.Config.AlphaBlending,
width: u32 = 1,
height: u32 = 1,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Self {
    _ = alloc;
    _ = device;
    const driver = switch (opts.rt_surface.platform) {
        .wgpu => |v| v.driver,
        else => return error.WgpuHostRequired,
    };
    if (driver.version != driver_version) {
        log.err("wgpu host driver version mismatch host={} expected={}", .{
            driver.version,
            driver_version,
        });
        return error.WgpuDriverVersionMismatch;
    }
    return .{ .driver = driver, .blending = opts.config.blending };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn threadEnter(self: *Self, _: *apprt.Surface) !void {
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

pub fn initShaders(
    _: *const Self,
    alloc: Allocator,
    custom: []const [:0]const u8,
) !shaders.Shaders {
    return shaders.Shaders.init(alloc, custom);
}

pub fn initTarget(self: *const Self, width: usize, height: usize) !Target {
    return Target.init(width, height, self.blending.isLinear());
}

pub fn beginFrame(
    _: *const Self,
    owner: *rendererpkg.GenericRenderer(Self),
    target: *Target,
) !Frame {
    return .{
        .owner = owner,
        .target = target,
        .handle = try invoke(active(), .begin_frame, args0(target.texture.handle)),
    };
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
    return Texture.init(.{
        .format = switch (atlas.format) {
            .grayscale => .gray,
            .bgra => .bgra,
            else => return error.WgpuHostFailed,
        },
        .srgb = atlas.format == .bgra,
    }, atlas.size, atlas.size, null);
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
            return .{
                .buffer = .{ .handle = try invoke(active(), .create_buffer, a), .driver = active() },
                .len = len,
                .opts = opts,
            };
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
            _ = try invoke(self.buffer.driver, .write_buffer, a);
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

    pub const Error = error{WgpuHostFailed};
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
        return .{
            .resource = .{ .handle = try invoke(active(), .create_texture, a), .driver = active() },
            .width = width,
            .height = height,
            .format = opts.format,
        };
    }

    pub fn deinit(self: Texture) void {
        release(self.resource.driver, self.resource.handle);
    }

    pub fn replaceRegion(
        self: Texture,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        data: []const u8,
    ) Error!void {
        var a = args0(self.resource.handle);
        a[1] = x;
        a[2] = y;
        a[3] = width;
        a[4] = height;
        a[5] = @intFromPtr(data.ptr);
        a[6] = data.len;
        _ = try invoke(self.resource.driver, .write_texture, a);
    }
};

pub const Sampler = struct {
    pub const Options = struct {};

    pub fn init(_: Options) !Sampler {
        return .{};
    }

    pub fn deinit(_: Sampler) void {}
};

/// A frame target. The host backs it with a pool of textures and renders
/// each frame into one that no exported frame still holds, so a frame can
/// be handed to the host for composition without a copy.
pub const Target = struct {
    texture: Resource,
    width: usize,
    height: usize,

    fn init(width: usize, height: usize, srgb: bool) !Target {
        var a = args0(width);
        a[1] = height;
        a[2] = @intFromEnum(ImageTextureFormat.rgba);
        a[3] = @intFromBool(srgb);
        a[6] = 1; // frame target
        return .{
            .texture = .{ .handle = try invoke(active(), .create_texture, a), .driver = active() },
            .width = width,
            .height = height,
        };
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
        return .{
            .resource = .{ .handle = try invoke(active(), .create_pipeline, a), .driver = active() },
            .kind = kind,
        };
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

    /// Pipeline kinds, by index; the host maps them to terminal.wgsl entry
    /// points. Custom shaders use `custom_kind`.
    const custom_kind = 5;

    pub const Shaders = struct {
        pipelines: struct {
            bg_color: Pipeline,
            cell_bg: Pipeline,
            cell_text: Pipeline,
            image: Pipeline,
            bg_image: Pipeline,
        },
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
                p.* = try Pipeline.init(custom_kind, code);
                initialized += 1;
            }
            result.post_pipelines = post;
            return result;
        }

        pub fn deinit(self: *Shaders, alloc: Allocator) void {
            if (self.defunct) return;
            self.defunct = true;
            inline for (std.meta.fields(@TypeOf(self.pipelines))) |field| {
                @field(self.pipelines, field.name).deinit();
            }
            for (self.post_pipelines) |p| p.deinit();
            alloc.free(self.post_pipelines);
        }
    };
};

/// The frame being encoded on this thread. The host records each render
/// pass's steps into one wgpu render pass.
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
        draw: struct {
            type: enum { triangle, triangle_strip },
            vertex_count: usize,
            instance_count: usize = 1,
        },
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
        _ = invoke(active(), .draw, a) catch {
            log.err("wgpu render step failed", .{});
            return;
        };
        self.clear = null;
    }

    pub fn complete(self: *const RenderPass) void {
        var a = args0(encoding);
        a[1] = self.target;
        // A pass with no steps still clears its target.
        if (self.clear) |*c| a[2] = @intFromPtr(c);
        _ = invoke(active(), .end_pass, a) catch {
            log.err("wgpu render pass failed", .{});
        };
    }
};

pub const Frame = struct {
    owner: *rendererpkg.GenericRenderer(Self),
    target: *Target,
    handle: usize,

    pub fn renderPass(
        self: *const Frame,
        attachments: []const RenderPass.Options.Attachment,
    ) RenderPass {
        encoding = self.handle;
        return .{
            .target = switch (attachments[0].target) {
                .target => |t| t.texture.handle,
                .texture => |t| t.resource.handle,
            },
            .clear = attachments[0].clear_color,
        };
    }

    /// Submit the frame and hand its texture to the host. `sync` is ignored:
    /// the frame is ordered on the host's queue ahead of anything that
    /// samples it, so there is nothing to wait for.
    pub fn complete(self: *const Frame, sync: bool) void {
        _ = sync;
        var a = args0(self.handle);
        a[1] = self.target.texture.handle;
        const handle = invoke(self.target.texture.driver, .submit_frame, a) catch {
            self.owner.frameCompleted(.unhealthy);
            return;
        };
        self.owner.pushFrame(.{ .texture = .{
            .resource = .{ .driver = self.target.texture.driver, .handle = handle },
            .width = @intCast(self.target.width),
            .height = @intCast(self.target.height),
        } });
        _ = self.owner.surface_mailbox.push(.redraw, .{ .forever = {} });
        self.owner.frameCompleted(.healthy);
    }
};

/// A finished frame, taken by the host through ghostty_surface_take_gpu_frame.
/// It holds the host texture until released.
pub const ExportedFrame = union(enum) {
    texture: struct {
        resource: Resource,
        width: u32,
        height: u32,
    },

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .texture => |v| release(v.resource.driver, v.resource.handle),
        }
    }
};
