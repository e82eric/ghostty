//! Test entry point for fork-owned modules.
//!
//! The test root references this file once, so fork tests never need
//! references inside upstream files. Add new fork test files here.
test {
    _ = @import("apprt/snapshot_viewport.zig");
    _ = @import("apprt/embedded_snapshot.zig");
    _ = @import("terminal/host_regression_tests.zig");
    _ = @import("termio/host_process.zig");
}
