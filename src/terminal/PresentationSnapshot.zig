//! Eager, independently owned frozen terminals using the upstream snapshot codec.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const snapshot = @import("snapshot/main.zig");

/// The caller must hold the source terminal's mutex throughout capture.
pub fn capture(alloc: std.mem.Allocator, io: std.Io, source: *const Terminal) !Terminal {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    snapshot.encode(alloc, &encoded.writer, source, .{ .continuation = .ground }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try snapshot.decodeExact(alloc, io, &reader, .{ .max_continuation_bytes = 0 });
    defer decoded.deinit(alloc);
    const target = &decoded.terminal.?;
    // The wire codec omits presentation viewport and derived prompt state.
    var source_screens = source.screens.all;
    var screens = source_screens.iterator();
    while (screens.next()) |entry| {
        const src = entry.value.*;
        const dst = target.screens.get(entry.key).?;
        dst.scroll(switch (src.pages.viewport) {
            .active => .active,
            .top => .top,
            .pin => .{ .row = src.pages.scrollbar().offset },
        });
        dst.semantic_prompt = src.semantic_prompt;
    }
    target.modes.set(.cursor_visible, false);
    target.flags.dirty.clear = true;
    return decoded.toOwned();
}

test "eager presentation snapshot preserves full history viewport and independent text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var live = try Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 8, .max_scrollback_bytes = null });
    defer live.deinit(alloc);
    var stream = live.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[31m\x1b]8;id=test;https://example.com\x1b\\");
    for (0..1000) |_| stream.nextSlice("original 界 e\u{301}\r\n");
    live.screens.active.scroll(.{ .row = 100 });
    // Upstream live compression still works; captured history is resident.
    _ = live.compress(.full);
    const viewport = live.screens.active.pages.scrollbar().offset;
    const expected = try live.screens.active.selectionString(alloc, .{
        .sel = .init(live.screens.active.pages.getTopLeft(.screen), live.screens.active.pages.getBottomRight(.screen).?, false),
        .trim = false,
    });
    defer alloc.free(expected);
    var frozen = try capture(alloc, testing.io, &live);
    defer frozen.deinit(alloc);
    try testing.expectEqual(viewport, live.screens.active.pages.scrollbar().offset);
    try testing.expectEqual(viewport, frozen.screens.active.pages.scrollbar().offset);
    try testing.expectEqual(live.screens.active.pages.total_rows, frozen.screens.active.pages.total_rows);
    var node = frozen.screens.active.pages.pages.first;
    while (node) |n| : (node = n.next) try testing.expect(n.data == .resident);
    live.fullReset();
    const TextCursor = @import("SnapshotTextCursor.zig");
    var cursor = try TextCursor.init(frozen.screens.active, alloc);
    defer cursor.deinit();
    var actual: std.Io.Writer.Allocating = .init(alloc);
    defer actual.deinit();
    while (try cursor.next()) |chunk| try actual.writer.writeAll(chunk.text);
    try testing.expectEqualStrings(expected, actual.written());
    cursor.reset();
    try testing.expect((try cursor.next()) != null);
    frozen.screens.active.assertIntegrity();
}

test "eager presentation snapshot preserves alternate screen and releases failed captures" {
    const testing = std.testing;
    var live = try Terminal.init(testing.io, testing.allocator, .{ .cols = 16, .rows = 2, .max_scrollback_bytes = null });
    defer live.deinit(testing.allocator);
    var stream = live.vtStream();
    defer stream.deinit();
    for (0..12) |_| stream.nextSlice("history\r\n");
    stream.nextSlice("\x1b[?1049halternate");
    try testing.checkAllAllocationFailures(testing.allocator, captureFailureTest, .{&live});
}

fn captureFailureTest(alloc: std.mem.Allocator, live: *const Terminal) !void {
    var frozen = try capture(alloc, std.testing.io, live);
    defer frozen.deinit(alloc);
    try std.testing.expectEqual(live.screens.active_key, frozen.screens.active_key);
    try std.testing.expectEqual(live.screens.get(.primary).?.pages.total_rows, frozen.screens.get(.primary).?.pages.total_rows);
    frozen.screens.active.assertIntegrity();
}
