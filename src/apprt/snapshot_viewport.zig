const std = @import("std");

pub fn revealTop(top: usize, height: usize, total: usize, row: u64, padding_rows: u32) usize {
    if (height == 0) return top;
    const padding = @min(padding_rows, (height - 1) / 2);
    const max_top = total -| height;
    const target: usize = @intCast(@min(row, total -| 1));
    const current = @min(top, max_top);
    const desired = if (target < current + padding)
        target -| padding
    else if (target > current + height - 1 - padding)
        target -| (height - 1 - padding)
    else
        current;
    return @min(desired, max_top);
}

test "snapshot viewport reveal padding" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(usize, 40), revealTop(40, 20, 100, 43, 3));
    try expectEqual(@as(usize, 40), revealTop(40, 20, 100, 56, 3));
    try expectEqual(@as(usize, 39), revealTop(40, 20, 100, 42, 3));
    try expectEqual(@as(usize, 41), revealTop(40, 20, 100, 57, 3));
    try expectEqual(@as(usize, 7), revealTop(40, 20, 100, 10, 3));
    try expectEqual(@as(usize, 74), revealTop(40, 20, 100, 90, 3));
    try expectEqual(@as(usize, 0), revealTop(40, 20, 100, 0, 3));
    try expectEqual(@as(usize, 80), revealTop(40, 20, 100, 99, 3));
    // Zero padding keeps the original minimal-reveal behavior.
    try expectEqual(@as(usize, 39), revealTop(40, 20, 100, 39, 0));
    try expectEqual(@as(usize, 41), revealTop(40, 20, 100, 60, 0));
}

test "snapshot viewport reveal short windows" {
    var height: usize = 1;
    while (height <= 7) : (height += 1) {
        const margin = @min(3, (height - 1) / 2);
        for ([_]usize{ 0, 9, 10, 11, 50, 99 }) |row| {
            const top = revealTop(10, height, 100, row, 3);
            try std.testing.expect(top <= row and row < top + height);
            if (top > 0 and top < 100 - height) {
                try std.testing.expect(row >= top + margin and row < top + height - margin);
            }
        }
    }
}
