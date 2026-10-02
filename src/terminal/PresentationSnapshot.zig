//! In-process, independently owned frozen terminals with compressed history.
//! The wire codec is used only for active terminal state, never for history.
//! Historical encoded blocks are copied directly and decoded only for reads.
//! This uses the native compressor's retained mappings: physical residency
//! shrinks, but virtual address space and Windows commit accounting remain.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const PageList = @import("PageList.zig");
const snapshot = @import("snapshot/main.zig");

/// The caller must hold the source terminal's mutex throughout capture.
pub fn capture(alloc: std.mem.Allocator, io: std.Io, source: *const Terminal) !Terminal {
    var source_screens = source.screens.all;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    encodeActive(alloc, source, &encoded.writer) catch |err| switch (err) {
        // The writer is allocating memory, with no external I/O to fail.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoder: snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(alloc, io, .{ .max_continuation_bytes = 0 });
    defer decoded.deinit(alloc);
    const target = &decoded.terminal.?;
    var screens = source_screens.iterator();
    while (screens.next()) |entry| {
        const src = entry.value.*;
        const dst = target.screens.get(entry.key).?;
        var remap: PageList.Clone.TrackedPinsRemap = .init(alloc);
        defer remap.deinit();
        var pages = try src.pages.clonePreservingStorage(alloc, &remap);
        errdefer pages.deinit();
        const cursor_pin = remap.get(src.cursor.page_pin).?;
        const rac = cursor_pin.rowAndCell();

        // Page bytes and IDs are cloned exactly, so copy native cursor IDs.
        // Keep the independently decoded heap hyperlink, never the source's.
        const owned_hyperlink = dst.cursor.hyperlink;
        dst.pages.deinit();
        dst.pages = pages;
        dst.cursor = src.cursor;
        dst.cursor.hyperlink = owned_hyperlink;
        dst.cursor.page_pin = cursor_pin;
        dst.cursor.page_row = rac.row;
        dst.cursor.page_cell = rac.cell;
        dst.semantic_prompt = src.semantic_prompt;
        dst.assertIntegrity();
    }
    target.modes.set(.cursor_visible, false);
    target.flags.dirty.clear = true;
    return decoded.toOwned();
}

fn encodeActive(alloc: std.mem.Allocator, source: *const Terminal, writer: *std.Io.Writer) !void {
    var records: snapshot.record.Writer = .init(alloc, writer);
    defer records.deinit();
    try snapshot.envelope.encode(records.writer());
    try snapshot.terminal.encode(source, &records);
    var source_screens = source.screens.all;
    var screens = source_screens.iterator();
    while (screens.next()) |entry| {
        try snapshot.screen.encode(entry.value.*, entry.key, &records);
    }
    try snapshot.continuation.encode(.ground, &records);
    try snapshot.checkpoint.encode(.ready, &records);
}

test "presentation snapshot preserves compressed history and bounded search" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const TextCursor = @import("SnapshotTextCursor.zig");
    var live = try Terminal.init(testing.io, alloc, .{
        .cols = 80,
        .rows = 8,
        .max_scrollback_bytes = null,
    });
    defer live.deinit(alloc);
    var stream = live.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[31m\x1b]8;id=test;https://example.com\x1b\\");
    for (0..3000) |_| stream.nextSlice("original 界 e\u{301}\r\n");
    live.screens.active.scroll(.{ .row = 100 });
    _ = live.compress(.full);
    const viewport = live.screens.active.pages.scrollbar().offset;
    const compressed_before = countCompressed(&live);
    try testing.expect(compressed_before > 1);
    var frozen = try capture(alloc, testing.io, &live);
    defer frozen.deinit(alloc);
    try testing.expectEqual(compressed_before, countCompressed(&live));
    try testing.expectEqual(viewport, frozen.screens.active.pages.scrollbar().offset);
    try testing.expectEqual(live.screens.active.pages.total_rows, frozen.screens.active.pages.total_rows);
    try testing.expectEqual(live.screens.active.cursor.style_id, frozen.screens.active.cursor.style_id);
    try testing.expectEqual(live.screens.active.cursor.hyperlink_id, frozen.screens.active.cursor.hyperlink_id);
    try testing.expect(live.screens.active.cursor.hyperlink.? != frozen.screens.active.cursor.hyperlink.?);

    var a = live.screens.active.pages.pages.first;
    var b = frozen.screens.active.pages.pages.first;
    while (a) |src| : (a = src.next) {
        const dst = b.?;
        b = dst.next;
        try testing.expect(src != dst);
        if (src.data == .compressed) {
            try testing.expect(dst.data == .compressed);
            try testing.expect(src.data.compressed.page.memory.ptr != dst.data.compressed.page.memory.ptr);
            try testing.expect(src.data.compressed.encoded.ptr != dst.data.compressed.encoded.ptr);
            try testing.expectEqualSlices(u8, src.data.compressed.encoded, dst.data.compressed.encoded);
        }
        var src_page = try src.pagePreservingState(alloc);
        defer src_page.deinit();
        var dst_page = try dst.pagePreservingState(alloc);
        defer dst_page.deinit();
        try testing.expectEqualSlices(u8, src_page.page().memory, dst_page.page().memory);
    }
    try testing.expect(b == null);

    // Read the complete history twice, with exact text and coordinate parity.
    // Neither search pass is allowed to hydrate the compressed page mappings.
    const compressed_frozen = countCompressed(&frozen);
    var reference = try TextCursor.init(live.screens.active, alloc);
    defer reference.deinit();
    var cursor = try TextCursor.init(frozen.screens.active, alloc);
    defer cursor.deinit();
    for (0..2) |_| {
        while (try reference.next()) |expected| {
            const actual = (try cursor.next()).?;
            try testing.expectEqualSlices(u8, expected.text, actual.text);
            try testing.expectEqualSlices(@import("point.zig").Coordinate, expected.points, actual.points);
            try testing.expectEqual(expected.row_base, actual.row_base);
            try testing.expectEqual(expected.start_y, actual.start_y);
        }
        try testing.expect((try cursor.next()) == null);
        try testing.expectEqual(compressed_frozen, countCompressed(&frozen));
        try testing.expectEqual(compressed_before, countCompressed(&live));
        cursor.reset();
        reference.reset();
    }
    // Copying styled text also uses scratch pages rather than resident history.
    const formatter = @import("formatter.zig");
    var expected_text: std.Io.Writer.Allocating = .init(alloc);
    defer expected_text.deinit();
    var actual_text: std.Io.Writer.Allocating = .init(alloc);
    defer actual_text.deinit();
    try formatter.PageListFormatter.init(&live.screens.active.pages, .vt).format(&expected_text.writer);
    try formatter.PageListFormatter.init(&frozen.screens.active.pages, .vt).format(&actual_text.writer);
    try testing.expectEqualSlices(u8, expected_text.written(), actual_text.written());
    try testing.expectEqual(compressed_frozen, countCompressed(&frozen));
    try testing.expectEqual(compressed_before, countCompressed(&live));
    // Frozen contents and heap cursor state survive destruction of live data.
    live.fullReset();
    try testing.expect((try cursor.next()) != null);
    frozen.screens.active.assertIntegrity();
}

test "presentation snapshot compresses resident history and preserves alternate screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var live = try Terminal.init(testing.io, alloc, .{
        .cols = 80,
        .rows = 8,
        .max_scrollback_bytes = null,
    });
    defer live.deinit(alloc);
    var stream = live.vtStream();
    defer stream.deinit();
    for (0..1000) |_| stream.nextSlice("resident history\r\n");
    stream.nextSlice("\x1b[?1049h\x1b[32malternate screen");
    try testing.expectEqual(@as(usize, 0), countCompressed(&live));
    var frozen = try capture(alloc, testing.io, &live);
    defer frozen.deinit(alloc);
    try testing.expectEqual(live.screens.active_key, frozen.screens.active_key);
    try testing.expectEqual(@as(usize, 0), countCompressed(&live));
    try testing.expect(countCompressed(&frozen) > 0);
    var source_screens = live.screens.all;
    var screens = source_screens.iterator();
    while (screens.next()) |entry| {
        const src = entry.value.*;
        const dst = frozen.screens.get(entry.key).?;
        try testing.expectEqual(src.pages.total_rows, dst.pages.total_rows);
        try testing.expectEqual(src.cursor.x, dst.cursor.x);
        try testing.expectEqual(src.cursor.y, dst.cursor.y);
        dst.assertIntegrity();
    }
}

fn countCompressed(t: *const Terminal) usize {
    var count: usize = 0;
    var source_screens = t.screens.all;
    var screens = source_screens.iterator();
    while (screens.next()) |entry| {
        var node = entry.value.*.pages.pages.first;
        while (node) |n| : (node = n.next) {
            if (n.data == .compressed) count += 1;
        }
    }
    return count;
}

test "presentation snapshot capture allocation failures release owned storage" {
    const testing = std.testing;
    var source = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 8,
        .max_scrollback_bytes = null,
    });
    defer source.deinit(testing.allocator);
    var stream = source.vtStream();
    defer stream.deinit();
    for (0..1000) |_| stream.nextSlice("frozen history\r\n");
    _ = source.compress(.full);
    try testing.expect(countCompressed(&source) > 0);
    try testing.checkAllAllocationFailures(testing.allocator, captureFailureTest, .{&source});
}

fn captureFailureTest(alloc: std.mem.Allocator, source: *const Terminal) !void {
    var frozen = try capture(alloc, std.testing.io, source);
    defer frozen.deinit(alloc);
}
