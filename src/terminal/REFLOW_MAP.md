# Frozen snapshot resize translation

`PageList.resizeCols` optionally records source-to-destination positions while
its existing reflow pass copies cells. Live terminal resizing leaves the recorder
null. `Screen.Resize` forwards the recorder; `SnapshotReflow.resizeMapped` owns it.

Snapshot resize also synchronizes tab stops, the scrolling region, and inactive
screen dimensions. This keeps the resized terminal valid for later snapshot capture.

The map contains 32-byte segments ordered by old row and old column. Each segment
has old/new row, old/new starting column, source cell count, and a column step.
Step 1 describes a contiguous run. Step 0 describes source padding or blanks
collapsed onto a destination cell. Wide characters that require a new spacer are
recorded after the retry actually places the character. Bulk copies record a
whole run. Destination rows are absolute, so page moves do not invalidate entries.

`row_offsets` contains `old_rows + 1` unsigned 32-bit indices. Row r's segments
are `[row_offsets[r], row_offsets[r + 1])`. Rust indexes that row directly and
binary-searches only its column segments. A map covers every old cell, including
trailing rows removed by a height reduction. Trimmed blanks resolve to retained
positions; they do not force Ghostty to retain padding as real content.

The C resize API returns one owned map, with no retained terminal-page pointers.
Rust's `SnapshotReflowMap` releases it through `ghostty_snapshot_reflow_map_free`
on drop. It translates copy cursor, visual anchor, selected row-segment endpoints,
saved copy-search origin and quick-select yank origin through the
same map before rebuilding decorations/search state. Linewise selections are
expanded against the new logical-line boundaries afterward. Exact selected yank
text remains retained by the copy controller.

Snapshot readers must be stopped before resize. Each map describes one old/new
layout pair; its buffers survive subsequent resizes, but applying it to coordinates
from another layout is invalid. Normal maps are released as soon as translation
finishes. Searches and quick select are rerun rather than translating every match.
Loaded scrollback pickers retain their immutable document, query, results, and
selection on resize, resetting preview copy state to allow a new Rust layout.
Unfinished native captures are cancelled and the picker closes. Candidate native
positions remain in their capture layout. Positional actions derive a logical
line and UTF-8 byte offset from the retained document and resolve both endpoints
with one current-snapshot scan. Picker positions do not participate in the pane's map.

Scrollback previews use a Rust-owned compact styled document. NFM wraps its
logical lines at the preview width and retains row boundaries for copy mode.
There is no preview terminal or native preview reflow map. The old
`ReflowPins.zig` optimization and `SnapshotPreviewLayout.zig` are removed;
upstream pin processing is unchanged. Only the small normal terminal/viewport
pin set remains during pane reflow.

For 70,000 old rows, offsets take 280,004 bytes. 210,000 segments take 6,720,000
bytes, excluding allocator capacity and the small owner object. Segment count is
not capped by row count, and the builder's allocation capacity can exceed used
length. This storage is temporary; it is not another retained snapshot terminal.

Ghostty still determines pane wrapping, style/grapheme copying, trimming, and layout.
The recorder observes that work rather than implementing a Rust reflow algorithm.
Additional segments are necessary for collapsed padding and wide-cell spacers.
Normal upstream behavior at width one can discard wide characters; a map cannot
preserve text that the terminal's own reflow removes.
