//! Export textures retained by an embedding host until its frame lease ends.
const OutputPool = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const Target = @import("Target.zig");

pub const TextureFrame = struct {
    pool: *OutputPool,
    slot: u8,
    texture: u32,
    width: u32,
    height: u32,
    generation: u64,

    pub fn deinit(self: TextureFrame) void {
        self.pool.slots[self.slot].state.store(0, .release);
    }
};

alloc: Allocator,
slots: [3]Slot = .{ .{}, .{}, .{} },
generation: u64 = 0,

const Slot = struct {
    // 0 is free, 1 is owned by an exported frame, and 2 is being written.
    state: std.atomic.Value(u8) = .init(0),
    texture: ?gl.Texture = null,
    framebuffer: ?gl.Framebuffer = null,
    width: u32 = 0,
    height: u32 = 0,

    fn ensureSize(self: *Slot, width: u32, height: u32) !void {
        if (self.texture != null and self.width == width and self.height == height) return;
        self.deinitResources();

        const texture = try gl.Texture.create();
        errdefer texture.destroy();
        {
            const bound = try texture.bind(.@"2d");
            defer bound.unbind();
            try bound.parameter(.min_filter, .nearest);
            try bound.parameter(.mag_filter, .nearest);
            try bound.parameter(.wrap_s, .clamp_to_edge);
            try bound.parameter(.wrap_t, .clamp_to_edge);
            try bound.image2D(0, .rgba, @intCast(width), @intCast(height), .rgba, .unsigned_byte, null);
            try bound.parameter(.base_level, 0);
            try bound.parameter(.max_level, 0);
        }

        const framebuffer = try gl.Framebuffer.create();
        errdefer framebuffer.destroy();
        {
            const bound = try framebuffer.bind(.framebuffer);
            defer bound.unbind();
            try bound.texture2D(.color0, .@"2d", texture, 0);
            if (bound.checkStatus() != .complete) return error.FramebufferIncomplete;
        }

        self.texture = texture;
        self.framebuffer = framebuffer;
        self.width = width;
        self.height = height;
    }

    fn deinitResources(self: *Slot) void {
        if (self.framebuffer) |v| v.destroy();
        if (self.texture) |v| v.destroy();
        self.framebuffer = null;
        self.texture = null;
        self.width = 0;
        self.height = 0;
    }
};

pub fn create(alloc: Allocator) !*OutputPool {
    const result = try alloc.create(OutputPool);
    result.* = .{ .alloc = alloc };
    return result;
}

pub fn destroy(self: *OutputPool) void {
    self.alloc.destroy(self);
}

pub fn deinitResources(self: *OutputPool) void {
    for (&self.slots) |*slot| slot.deinitResources();
}

pub fn exportFrame(self: *OutputPool, target: Target) !TextureFrame {
    for (&self.slots, 0..) |*slot, i| {
        if (slot.state.load(.acquire) != 0) continue;
        slot.state.store(2, .release);
        errdefer slot.state.store(0, .release);

        const width: u32 = @intCast(target.width);
        const height: u32 = @intCast(target.height);
        try slot.ensureSize(width, height);

        try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
        defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch {};
        const read = try target.framebuffer.bind(.read);
        defer read.unbind();
        const draw = try slot.framebuffer.?.bind(.draw);
        defer draw.unbind();
        try gl.blitFramebuffer(
            0,
            0,
            @intCast(width),
            @intCast(height),
            0,
            @intCast(height),
            @intCast(width),
            0,
            .{ .color_buffer_bit = true },
            .nearest,
        );
        gl.finish();

        self.generation +%= 1;
        slot.state.store(1, .release);
        return .{
            .pool = self,
            .slot = @intCast(i),
            .texture = slot.texture.?.id,
            .width = width,
            .height = height,
            .generation = self.generation,
        };
    }

    return error.NoExportTextureAvailable;
}
