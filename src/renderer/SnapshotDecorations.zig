//! Owned presentation-only decorations sent atomically to the renderer.
const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const terminal = @import("../terminal/main.zig");

pub const Style = struct {
    foreground: ?terminal.color.RGB = null,
    background: ?terminal.color.RGB = null,
    invert_colored_background: bool = false,
};

pub const Layer = struct {
    style: Style,
    ranges: []const terminal.highlight.Flattened,
};

arena: ArenaAllocator,
layers: []const Layer,
text: []const Text = &.{},
/// Viewport cell of the presentation caret, when visible. Cursor shaders
/// track it while the terminal cursor is hidden.
caret: ?Caret = null,

pub const Caret = struct {
    coord: terminal.Coordinate,
    color: ?terminal.color.RGB = null,
};

pub const Text = struct {
    coord: terminal.Coordinate,
    codepoint: u21,
    style: Style,
    bold: bool = false,
    underline: bool = false,
};
