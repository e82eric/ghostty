//! How the threads each surface keeps are started.
const std = @import("std");
const builtin = @import("builtin");

/// The stack of a surface's renderer, IO and IO reader threads.
///
/// `std.Thread` gives a thread 16 MiB unless told otherwise. Elsewhere that
/// is address space, used as the stack grows. On Windows it is asked for as
/// the stack's initial commit, so every thread is charged all of it at once:
/// 48 MiB of commit for each surface, of which these threads have been seen
/// to touch about a tenth of one. A host with many surfaces pays that for
/// each.
pub const surface: std.Thread.SpawnConfig = .{
    .stack_size = switch (builtin.os.tag) {
        .windows => 2 * 1024 * 1024,
        else => std.Thread.SpawnConfig.default_stack_size,
    },
};
