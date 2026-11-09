// Fork-owned embedding API for hosts such as nterm.
//
// Declarations the fork adds on top of upstream's ghostty.h live here so
// upstream merges don't conflict with them. Only changes that must extend
// an upstream type (the wgpu platform enum value and union member) stay in
// ghostty.h. Hosts include this header instead of ghostty.h.
#ifndef GHOSTTY_HOST_H
#define GHOSTTY_HOST_H

#include "ghostty.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__clang__)
  #pragma clang assume_nonnull begin
#endif

//-------------------------------------------------------------------
// Types

// A finished frame. texture is a handle from the embedder's dispatch table
// (an exported frame texture); the embedder owns it and releases it there.
typedef struct {
  uintptr_t texture;
  uint32_t width;
  uint32_t height;
} ghostty_gpu_frame_s;

// For key "theme", returns the selected light/dark theme name. Borrowed until
// the config is changed or freed; bytes are not necessarily NUL-terminated.
typedef struct { const char *GHOSTTY_NULL_UNSPECIFIED ptr; uintptr_t len; } ghostty_config_theme_name_s;

// Owned copy of the primary regular or bold SFNT font. Free with the paired function.
// Unsupported font formats/backends return false without allocating.
typedef struct {
  uint32_t tag; // OpenType tag, e.g. 0x77676874 (wght).
  float value;
} ghostty_font_variation_s;
typedef struct {
  uint8_t* GHOSTTY_NULLABLE data;
  size_t len;
  uint32_t face_index;
  uint32_t variation_count;
  ghostty_font_variation_s variations[32]; // Active design coordinates.
} ghostty_font_data_s;

//-------------------------------------------------------------------
// Published API

GHOSTTY_API int ghostty_init_utf8(uintptr_t, char* GHOSTTY_NONNULL* GHOSTTY_NONNULL);
// Borrowed, thread-local error name for the last failed native operation,
// including init/config creation/loading/finalization/app creation/surface
// creation and synchronous embedded operations, or NULL on success. Copy it
// before starting another such operation. NULL/false results with no error
// can represent normal absence or boundaries. Recoverable config diagnostics
// are available separately through ghostty_config_get_diagnostic.
GHOSTTY_API const char* GHOSTTY_NULLABLE ghostty_last_error(void);
GHOSTTY_API void ghostty_clear_error(void);

// Replace explicit terminal colors with a theme before finalization.
// Other settings are preserved; diagnostics are read after finalize.
GHOSTTY_API bool ghostty_config_set_theme(ghostty_config_t, const char*);
// NULL family and zero size preserve the existing setting. Before finalize.
GHOSTTY_API bool ghostty_config_set_font(ghostty_config_t, const char* GHOSTTY_NULLABLE, float);
// Callback paths are borrowed for the duration of each invocation, user directory first.
GHOSTTY_API bool ghostty_config_theme_directories(void* GHOSTTY_NULLABLE, void (*)(void* GHOSTTY_NULLABLE, const char*));

// Takes ownership of the newest frame rendered for a wgpu embedder. Returns
// false when no new frame is available.
GHOSTTY_API bool ghostty_surface_take_gpu_frame(ghostty_surface_t,
                                                ghostty_gpu_frame_s*);
GHOSTTY_API bool ghostty_surface_read_font(ghostty_surface_t, bool bold, ghostty_font_data_s*);
GHOSTTY_API void ghostty_font_data_free(ghostty_font_data_s*);
GHOSTTY_API uint64_t ghostty_surface_shell_pid(ghostty_surface_t);
/* Original shell creation FILETIME on Windows; zero when unavailable. */
GHOSTTY_API uint64_t ghostty_surface_shell_creation_time(ghostty_surface_t);

// Sends a key using a USB HID usage code instead of a platform-native
// scancode. This is useful for cross-platform embedders such as winit.
// The optional translated text belongs to the key event; use NULL for keys
// without text. A zero USB code can carry text without a physical key.
GHOSTTY_API bool ghostty_surface_key_usb(ghostty_surface_t,
                                           ghostty_input_action_e,
                                           ghostty_input_mods_e,
                                           uint32_t,
                                           uint32_t,
                                           const char* GHOSTTY_NULLABLE);

//-------------------------------------------------------------------
// Frozen snapshots

/** Begin independently owned frozen snapshot presentation. Live output continues
 * updating its own terminal without changing the captured contents. */
GHOSTTY_API bool ghostty_surface_snapshot_begin(ghostty_surface_t,
                                                   uint64_t* generation);

/** End frozen snapshot presentation and reveal the newest live state. */
GHOSTTY_API bool ghostty_surface_snapshot_end(ghostty_surface_t,
                                                 uint64_t generation);

/** A sequential view of frozen snapshot text and its byte-to-cell positions.
 * Use each cursor from one thread at a time. The returned pointers remain
 * valid until the next cursor call. Close the cursor before destroying its
 * surface. The next operation returns 1 for a chunk, 0 at end of text,
 * and -1 for a stale snapshot or formatting error.
 */
typedef struct ghostty_snapshot_text_cursor_s* ghostty_snapshot_text_cursor_t;
typedef struct {
    uint16_t x;
    uint32_t y;
} ghostty_snapshot_text_point_s;
typedef struct {
    const char* GHOSTTY_NULLABLE text;
    const ghostty_snapshot_text_point_s* GHOSTTY_NULLABLE points;
    uintptr_t len;
    uint64_t row_base;
    uint16_t start_y;
} ghostty_snapshot_text_chunk_s;
GHOSTTY_API ghostty_snapshot_text_cursor_t ghostty_surface_snapshot_text_cursor_new(
    ghostty_surface_t, uint64_t generation);
GHOSTTY_API void ghostty_surface_snapshot_text_cursor_free(ghostty_snapshot_text_cursor_t);
GHOSTTY_API bool ghostty_surface_snapshot_text_cursor_reset(ghostty_snapshot_text_cursor_t);
GHOSTTY_API int ghostty_surface_snapshot_text_cursor_next(
    ghostty_snapshot_text_cursor_t, ghostty_snapshot_text_chunk_s*);

/** Resolved style runs over source columns [start,end). UINT32_MAX colors
 * use preview defaults. Flags: bold=1 italic=2 strike=4 inverse=8 invisible=16
 * faint=32. */
typedef struct {
    uint32_t start, end, foreground, background, underline_color;
    uint8_t flags, underline;
    uint16_t reserved;
} ghostty_snapshot_style_run_s;

/** One physical row of the frozen snapshot, in screen coordinates. Each UTF-8
 * byte has a matching cell column; a blank row may have zero bytes. widths has
 * cell_count entries: 2 for a wide character, 0 for the cell it covers, and 1
 * otherwise. style_runs is NULL unless styles were requested. All buffers are
 * owned by the caller until ghostty_surface_snapshot_row_free.
 */
typedef struct {
    const char* GHOSTTY_NULLABLE text;
    const uint32_t* GHOSTTY_NULLABLE columns;
    uintptr_t len;
    const uint8_t* GHOSTTY_NULLABLE widths;
    uint32_t cell_count;
    const ghostty_snapshot_style_run_s* GHOSTTY_NULLABLE style_runs;
    uintptr_t style_run_count;
    bool wraps_to_next;
    /* OSC 133 prompt state: 0 none, 1 primary prompt, 2 continuation. */
    uint8_t semantic_prompt;
    /* First cell column marked as input by OSC 133, or UINT32_MAX. */
    uint32_t input_column;
} ghostty_snapshot_row_s;
GHOSTTY_API bool ghostty_surface_snapshot_row(
    ghostty_surface_t, uint64_t generation, uint64_t row, bool styles,
    ghostty_snapshot_row_s*);
GHOSTTY_API void ghostty_surface_snapshot_row_free(ghostty_snapshot_row_s*);

/** The live terminal cursor. column is its cell column. row is relative to the
 * visible viewport and only meaningful when in_viewport is true. When line is
 * requested, text holds the cursor's physical row and cursor_byte its offset;
 * free it with ghostty_surface_live_cursor_free. */
typedef struct {
    const char* GHOSTTY_NULLABLE text;
    uintptr_t len;
    uintptr_t cursor_byte;
    uint32_t column;
    uint32_t row;
    bool in_viewport;
} ghostty_live_cursor_s;
GHOSTTY_API bool ghostty_surface_live_cursor(
    ghostty_surface_t, bool line, ghostty_live_cursor_s*);
GHOSTTY_API void ghostty_surface_live_cursor_free(ghostty_live_cursor_s*);

typedef struct { uint32_t x; uint64_t y; } ghostty_snapshot_cell_s;
/** Stable logical line and UTF-8 byte offset in plain snapshot text. */
typedef struct { uint64_t line, byte; } ghostty_snapshot_logical_position_s;
typedef struct { ghostty_snapshot_logical_position_s start, end; } ghostty_snapshot_logical_range_s;
typedef struct { ghostty_snapshot_cell_s start, end; } ghostty_snapshot_resolved_range_s;
GHOSTTY_API bool ghostty_surface_snapshot_logical_position(ghostty_surface_t, uint64_t, ghostty_snapshot_cell_s, ghostty_snapshot_logical_position_s*);
GHOSTTY_API bool ghostty_surface_snapshot_resolve_logical_range(ghostty_surface_t, uint64_t, ghostty_snapshot_logical_range_s, ghostty_snapshot_resolved_range_s*);
/** Reflow the frozen snapshot to the surface size. Stop snapshot readers
 * first, pass every retained cell (translated in place), then republish
 * decorations. On failure the cells are unchanged. */
GHOSTTY_API bool ghostty_surface_snapshot_resize(
    ghostty_surface_t, uint64_t generation, ghostty_snapshot_cell_s* GHOSTTY_NULLABLE cells, size_t count);
typedef struct {
    ghostty_snapshot_cell_s cursor;
    uint64_t viewport_top;
    uint64_t total_rows;
    uint32_t viewport_rows;
    uint32_t columns;
} ghostty_snapshot_view_s;
/** Snapshot insertion cursor, viewport, and dimensions in the current layout.
 * Rust translates retained positions during coordinated resize. Recreate text
 * cursors and rebuild source payloads after reflow before using them again. */
GHOSTTY_API bool ghostty_surface_snapshot_view(
    ghostty_surface_t, uint64_t generation, ghostty_snapshot_view_s*);
typedef struct {
    ghostty_snapshot_cell_s start;
    ghostty_snapshot_cell_s end; /* inclusive */
} ghostty_snapshot_cell_range_s;
typedef struct {
    const char* GHOSTTY_NULLABLE text;
    uintptr_t len;
} ghostty_snapshot_selection_text_s;
/** Extract an inclusive cell range from the frozen snapshot. `rectangle`
 * selects the same columns on each physical row. `trim` removes
 * trailing spaces on each line. Free the result with
 * ghostty_surface_snapshot_selection_text_free. */
GHOSTTY_API bool ghostty_surface_snapshot_selection_text(
    ghostty_surface_t, uint64_t generation,
    ghostty_snapshot_cell_range_s range, bool trim, bool rectangle,
    ghostty_snapshot_selection_text_s* result);
GHOSTTY_API void ghostty_surface_snapshot_selection_text_free(
    ghostty_snapshot_selection_text_s* result);
/** RGB values are 0xRRGGBB. Flags bit 0 enables foreground; bit 1 enables background.
 * On a decoration layer, bit 3 marks it as the single-cell caret; custom
 * cursor shaders track that cell while the terminal cursor is hidden.
 * On a decoration layer, bit 4 swaps the original foreground and background
 * for cells whose background differs from the terminal default. */
typedef struct {
    uint32_t foreground_rgb;
    uint32_t background_rgb;
    uint32_t flags;
} ghostty_snapshot_decoration_style_s;
typedef struct {
    const ghostty_snapshot_cell_range_s* GHOSTTY_NULLABLE ranges;
    uintptr_t range_count;
    ghostty_snapshot_decoration_style_s style;
} ghostty_snapshot_decoration_layer_s;
/** Render-only single-cell text override. codepoint is printable ASCII for
 * this initial API; underlying snapshot text is never changed. Style flags
 * use the same foreground/background semantics as range decorations. Colors
 * not overridden by style use the original cell colors, excluding range
 * decorations. Style flag bit 2 enables a single underline in the replacement
 * foreground color. bold applies only to this replacement glyph.
 * Overrides must be nonoverlapping and are clipped to the viewport. */
typedef struct {
    ghostty_snapshot_cell_s cell;
    uint32_t codepoint;
    ghostty_snapshot_decoration_style_s style;
    bool bold;
} ghostty_snapshot_cell_text_s;
typedef struct {
    const ghostty_snapshot_cell_s* GHOSTTY_NULLABLE reveal;
    uint32_t padding_rows;
    const uint64_t* GHOSTTY_NULLABLE top_row;
} ghostty_snapshot_viewport_options_s;
/** Replace all snapshot decorations. Earlier layers take priority. Ranges in each
 * layer are nonoverlapping and ordered newest first in frozen screen coordinates.
 * viewport may be NULL to preserve the viewport. top_row, when non-NULL, sets
 * the absolute viewport top and takes priority over reveal. Otherwise reveal
 * scrolls its cell into view with padding_rows above and below. Padding reduces
 * for short viewports; all positioning clamps to available history. Scrolling
 * and preparing decorations happen under the same snapshot lock. Pointers are
 * borrowed only for this call. The live terminal and its cursor are unchanged.
 */
GHOSTTY_API bool ghostty_surface_snapshot_apply_decorations(
    ghostty_surface_t, uint64_t generation,
    const ghostty_snapshot_decoration_layer_s* GHOSTTY_NULLABLE, uintptr_t layer_count,
    const ghostty_snapshot_cell_text_s* GHOSTTY_NULLABLE, uintptr_t text_count,
    const ghostty_snapshot_viewport_options_s* GHOSTTY_NULLABLE viewport);

#if defined(__clang__)
  #pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_HOST_H */
