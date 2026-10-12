//! Owned presentation-only decorations sent atomically to the renderer.
const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const terminal = @import("../terminal/main.zig");

pub const Style = struct {
    foreground: ?terminal.color.RGB = null,
    background: ?terminal.color.RGB = null,
};

pub const Layer = struct {
    style: Style,
    ranges: []const terminal.highlight.Flattened,
};

arena: ArenaAllocator,
layers: []const Layer,
text: []const Text = &.{},

pub const Text = struct {
    coord: terminal.Coordinate,
    codepoint: u21,
    style: Style,
    bold: bool = false,
    underline: bool = false,
};
