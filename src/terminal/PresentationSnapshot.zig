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

/// A frozen terminal from a whole encoded snapshot made elsewhere, fitted to
/// `live`: the terminal a surface shows, which may hold less history than the
/// bytes do. Under the host backend the host's terminal is the complete one.
/// The caller must hold `live`'s mutex.
pub fn decode(alloc: std.mem.Allocator, io: std.Io, bytes: []const u8, live: *const Terminal) !Terminal {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try snapshot.decodeExact(alloc, io, &reader, .{
        // An unfinished escape sequence is the live terminal's business.
        .max_continuation_bytes = 1 << 20,
    });
    defer decoded.deinit(alloc);
    var result = decoded.toOwned();
    errdefer result.deinit(alloc);
    result.width_px = live.width_px;
    result.height_px = live.height_px;
    result.flags.resize_pull_scrollback = live.flags.resize_pull_scrollback;
    if (result.cols != live.cols or result.rows != live.rows) {
        try result.resize(alloc, .{ .cols = live.cols, .rows = live.rows });
    }
    // The wire codec omits derived prompt state. The viewport starts at the
    // bottom, where the live one is while its history is elsewhere.
    var live_screens = live.screens.all;
    var screens = live_screens.iterator();
    while (screens.next()) |entry| {
        if (result.screens.get(entry.key)) |dst| dst.semantic_prompt = entry.value.*.semantic_prompt;
    }
    result.modes.set(.cursor_visible, false);
    result.flags.dirty.clear = true;
    return result;
}

fn screenText(alloc: std.mem.Allocator, t: *Terminal) ![:0]const u8 {
    return t.screens.active.selectionString(alloc, .{
        .sel = .init(t.screens.active.pages.getTopLeft(.screen), t.screens.active.pages.getBottomRight(.screen).?, false),
        .trim = false,
    });
}

test "decoded presentation snapshot shows history the live terminal lacks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // The host's terminal keeps everything; the surface's keeps its screen.
    var host = try Terminal.init(testing.io, alloc, .{ .cols = 40, .rows = 6, .max_scrollback_bytes = null });
    defer host.deinit(alloc);
    var live = try Terminal.init(testing.io, alloc, .{ .cols = 40, .rows = 6, .max_scrollback_bytes = 0 });
    defer live.deinit(alloc);
    var host_stream = host.vtStream();
    defer host_stream.deinit();
    var live_stream = live.vtStream();
    defer live_stream.deinit();
    for (0..3000) |i| {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "\x1b[3{d}mrow {d} 界\x1b[0m\r\n", .{ i % 8, i });
        host_stream.nextSlice(line);
        live_stream.nextSlice(line);
    }
    // Left unfinished: a snapshot from a running shell can end mid-sequence.
    host_stream.nextSlice("prompt> \x1b[3");
    live_stream.nextSlice("prompt> \x1b[3");
    try testing.expect(live.screens.active.pages.total_rows < 1000);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &host, .{ .continuation = .{ .bytes = "\x1b[3" } });

    var frozen = try decode(alloc, testing.io, encoded.written(), &live);
    defer frozen.deinit(alloc);
    try testing.expectEqual(host.screens.active.pages.total_rows, frozen.screens.active.pages.total_rows);
    try testing.expect(!frozen.modes.get(.cursor_visible));
    const expected = try screenText(alloc, &host);
    defer alloc.free(expected);
    const actual = try screenText(alloc, &frozen);
    defer alloc.free(actual);
    try testing.expectEqualStrings(expected, actual);
    try testing.expect(std.mem.indexOf(u8, actual, "row 0 界\n") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "row 2999 界\n") != null);
    frozen.screens.active.assertIntegrity();
}

test "decoded presentation snapshot is fitted to the live terminal's size" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var host = try Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
    defer host.deinit(alloc);
    var live = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer live.deinit(alloc);
    var stream = host.vtStream();
    defer stream.deinit();
    for (0..200) |i| {
        var buf: [96]u8 = undefined;
        stream.nextSlice(try std.fmt.bufPrint(&buf, "a line of text that is longer than twenty cells {d}\r\n", .{i}));
    }
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &host, .{ .continuation = .ground });

    var frozen = try decode(alloc, testing.io, encoded.written(), &live);
    defer frozen.deinit(alloc);
    try testing.expectEqual(@as(usize, 20), frozen.cols);
    try testing.expectEqual(@as(usize, 5), frozen.rows);
    // Reflowed, not cut: each line now wraps over three rows.
    try testing.expect(frozen.screens.active.pages.total_rows >= 600);
    frozen.screens.active.assertIntegrity();

    try testing.expectError(error.EndOfStream, decode(alloc, testing.io, encoded.written()[0 .. encoded.written().len / 2], &live));
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
