//! Fatal initialization errors at the embedding boundary. Configuration
//! diagnostics remain separate and can still be recovered with defaults.
threadlocal var last_error: ?[:0]const u8 = null;

pub fn clear() void {
    last_error = null;
}
pub fn set(err: anyerror) void {
    last_error = @errorName(err);
}
pub fn get() ?[*:0]const u8 {
    return if (last_error) |value| value.ptr else null;
}

test "initialization error cleared between operations" {
    const std = @import("std");
    clear();
    try std.testing.expect(get() == null);
    set(error.OutOfMemory);
    try std.testing.expectEqualStrings("OutOfMemory", std.mem.span(get().?));
    clear();
    try std.testing.expect(get() == null);
}
