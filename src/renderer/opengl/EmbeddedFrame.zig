//! Wrapper for handling render passes, for EmbeddedGL.
//!
//! This is a copy of upstream's Frame.zig. That file cannot be reused for
//! EmbeddedGL because it names its backend directly: it imports OpenGL.zig
//! by path, is typed against `Renderer(OpenGL)`, and builds an
//! `OpenGL.ExportedFrame`. Zig's @import paths are fixed, so the backend
//! cannot be swapped from outside, and making Frame.zig generic would mean
//! rewriting an upstream file.
//!
//! Everything below this header must stay identical to Frame.zig except
//! for these substitutions:
//!   Renderer(OpenGL)                       -> Renderer(EmbeddedGL)
//!   const OpenGL = @import("../OpenGL.zig") -> const EmbeddedGL = @import("../EmbeddedGL.zig")
//!   OpenGL.ExportedFrame                   -> EmbeddedGL.ExportedFrame
//!
//! A test in EmbeddedGL.zig applies them to Frame.zig and fails if the
//! result differs from this file, so an upstream change to Frame.zig is
//! noticed at `zig build test` time. To update after such a change, copy
//! Frame.zig below this header and reapply the substitutions.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const global = @import("../../global.zig");
const Renderer = @import("../generic.zig").Renderer(EmbeddedGL);
const EmbeddedGL = @import("../EmbeddedGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we never block, instead
/// pushing the newly presented and exported frame to the frame queue.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    // If there are any GL errors, consider the frame unhealthy.
    const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

    // If the frame is healthy, draw it to an ExportedFrame
    // Then sync before exporting and pushing to the present queue.
    // The apprt pulls from this queue in its snapshot handler.
    const presented_frame: ?EmbeddedGL.ExportedFrame = if (health == .healthy) frame: {
        const frame = self.renderer.api.present(
            self.target.*,
            self.renderer.presentationHealth(),
        ) catch |err| {
            log.warn("failed to present render target: err={}", .{err});
            break :frame null;
        };
        break :frame frame;
    } else null;

    // Sync after frame draw AND frame present GL calls.
    gl.finish();

    // At this point the ExportedFrame is finished and can be shared
    if (presented_frame) |frame| {
        self.renderer.pushFrame(frame);

        // Notify the surface that it should redraw
        _ = self.renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
