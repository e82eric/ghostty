//! Terminal regressions for the Windows embedding host.
const std = @import("std");
const testing = std.testing;
const Terminal = @import("Terminal.zig");
const size = @import("size.zig");

test "Terminal: resize without scrollback pull shrink and grow prompt" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer t.deinit(alloc);
    t.flags.resize_pull_scrollback = false;

    // Fill history, then leave a prompt with two blank rows below it.
    try t.printString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    t.setCursorPos(4, 1);
    t.eraseDisplay(.below, false);
    try t.printString("prompt> aaa");

    // Shrinking consumes the blank rows before pushing text into history.
    // Growing must keep the prompt on the same row as the ConPTY buffer.
    for (0..2) |_| {
        try t.resize(alloc, .{ .cols = 20, .rows = 3 });
        try testing.expectEqual(@as(size.CellCountInt, 2), t.screens.active.cursor.y);
        try t.resize(alloc, .{ .cols = 20, .rows = 6 });
        try testing.expectEqual(@as(size.CellCountInt, 2), t.screens.active.cursor.y);
    }

    try t.printString("aaa");
    const text = try t.plainString(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("6\n7\nprompt> aaaaaa", text);

    // The old output remains in history, even though growth doesn't show it.
    const first = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
    try testing.expectEqual(@as(u21, '1'), first.content.codepoint.data);
}

test "Terminal: resize without scrollback pull to one row and back keeps prompt" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 30 });
    defer t.deinit(alloc);
    t.flags.resize_pull_scrollback = false;

    // Five lines of output below a command, then a prompt with blank rows below.
    try t.printString("PS> 1..5\n1\n2\n3\n4\n5\nPS> ");

    // Drag the bottom edge up one row at a time, then back down.
    var rows: size.CellCountInt = 30;
    while (rows > 1) {
        rows -= 1;
        try t.resize(alloc, .{ .cols = 80, .rows = rows });
    }
    try testing.expectEqual(@as(size.CellCountInt, 0), t.screens.active.cursor.y);
    while (rows < 30) {
        rows += 1;
        try t.resize(alloc, .{ .cols = 80, .rows = rows });
    }
    try testing.expectEqual(@as(size.CellCountInt, 0), t.screens.active.cursor.y);

    const text = try t.plainString(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("PS> ", text);
}
