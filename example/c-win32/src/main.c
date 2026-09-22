#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <ghostty.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WM_GHOSTTY_WAKE (WM_APP + 1)
#define WM_GHOSTTY_SEARCH_OPEN (WM_APP + 2)
#define WM_GHOSTTY_SEARCH_CLOSE (WM_APP + 3)
#define WM_GHOSTTY_SEARCH_TOTAL (WM_APP + 4)
#define WM_GHOSTTY_SEARCH_SELECTED (WM_APP + 5)
#define ID_SEARCH_EDIT 1001
#define ID_SEARCH_PREVIOUS 1002
#define ID_SEARCH_NEXT 1003
#define ID_SEARCH_CLOSE 1004
static HWND window;
static ghostty_app_t app;
static ghostty_surface_t surface;
static WCHAR high_surrogate;
static HWND search_background;
static HWND search_edit;
static HWND search_count;
static HWND search_previous;
static HWND search_next;
static HWND search_close;
static WNDPROC search_edit_procedure;
static HFONT search_font;
static BOOL search_visible;
static intptr_t search_total = -1;
static intptr_t search_selected = -1;

static void binding_action(const char *value) {
    if (surface) ghostty_surface_binding_action(surface, value, strlen(value));
}

static void post_search_open(const char *needle) {
    size_t len = needle ? strlen(needle) : 0;
    char *copy = malloc(len + 1);
    if (!copy) return;
    if (len) memcpy(copy, needle, len);
    copy[len] = 0;
    if (!PostMessageW(window, WM_GHOSTTY_SEARCH_OPEN, 0, (LPARAM)copy)) free(copy);
}

static void wake(void *data) {
    (void)data;
    PostMessageW(window, WM_GHOSTTY_WAKE, 0, 0);
}
static bool action(ghostty_app_t a, ghostty_target_s target, ghostty_action_s value) {
    (void)a;
    if (target.tag != GHOSTTY_TARGET_SURFACE) return false;
    switch (value.tag) {
    case GHOSTTY_ACTION_START_SEARCH:
        post_search_open(value.action.start_search.needle);
        return true;
    case GHOSTTY_ACTION_END_SEARCH:
        PostMessageW(window, WM_GHOSTTY_SEARCH_CLOSE, 0, 0);
        return true;
    case GHOSTTY_ACTION_SEARCH_TOTAL:
        PostMessageW(window, WM_GHOSTTY_SEARCH_TOTAL, 0,
            (LPARAM)value.action.search_total.total);
        return true;
    case GHOSTTY_ACTION_SEARCH_SELECTED:
        PostMessageW(window, WM_GHOSTTY_SEARCH_SELECTED, 0,
            (LPARAM)value.action.search_selected.selected);
        return true;
    default:
        return false;
    }
}
static ghostty_clipboard_read_result_e read_clipboard(void *data,
        ghostty_clipboard_e kind, void *state, const char *const *types,
        size_t count, bool confirm) {
    (void)data; (void)kind; (void)state; (void)types; (void)count; (void)confirm;
    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
}
static void confirm_clipboard(void *data, const ghostty_clipboard_confirm_s *value,
        void *state, ghostty_clipboard_request_e request) {
    (void)data; (void)value; (void)state; (void)request;
}
static void write_clipboard(void *data, ghostty_clipboard_e kind,
        const ghostty_clipboard_content_s *value, size_t count, bool confirm) {
    (void)data; (void)kind; (void)value; (void)count; (void)confirm;
}
static void close_surface(void *data, bool alive) {
    (void)data; (void)alive;
    PostMessageW(window, WM_CLOSE, 0, 0);
}
static ghostty_input_mods_e modifiers(void) {
    unsigned mods = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) mods |= GHOSTTY_MODS_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) mods |= GHOSTTY_MODS_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) mods |= GHOSTTY_MODS_ALT;
    return (ghostty_input_mods_e)mods;
}

static void update_search_count(void) {
    WCHAR text[32];
    if (search_total <= 0) {
        wcscpy_s(text, 32, L"0/0");
    } else {
        intptr_t selected = search_selected >= 0 ? search_selected + 1 : 0;
        _snwprintf_s(text, 32, _TRUNCATE, L"%lld/%lld",
            (long long)selected, (long long)search_total);
    }
    SetWindowTextW(search_count, text);
}

static void set_search_font(UINT dpi) {
    HFONT font = CreateFontW(-MulDiv(9, (int)dpi, 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return;
    HWND controls[] = { search_edit, search_count, search_previous, search_next, search_close };
    for (size_t i = 0; i < sizeof(controls) / sizeof(controls[0]); i++)
        SendMessageW(controls[i], WM_SETFONT, (WPARAM)font, TRUE);
    if (search_font) DeleteObject(search_font);
    search_font = font;
}

static void layout_search(HWND hwnd) {
    if (!search_background) return;
    RECT client;
    GetClientRect(hwnd, &client);
    UINT dpi = GetDpiForWindow(hwnd);
    int margin = MulDiv(12, dpi, 96);
    int padding = MulDiv(6, dpi, 96);
    int height = MulDiv(36, dpi, 96);
    int control_height = height - padding * 2;
    int button_width = MulDiv(30, dpi, 96);
    int count_width = MulDiv(58, dpi, 96);
    int edit_width = MulDiv(220, dpi, 96);
    int fixed_width = padding * 6 + count_width + button_width * 3;
    int available = client.right - client.left - margin * 2 - fixed_width;
    if (edit_width > available) edit_width = available;
    if (edit_width < MulDiv(60, dpi, 96)) edit_width = MulDiv(60, dpi, 96);
    int width = edit_width + fixed_width;
    int x = client.right - margin - width;
    if (x < margin) x = margin;
    int y = margin;

    MoveWindow(search_background, x, y, width, height, TRUE);
    int child_x = x + padding;
    int child_y = y + padding;
    MoveWindow(search_edit, child_x, child_y, edit_width, control_height, TRUE);
    child_x += edit_width + padding;
    MoveWindow(search_count, child_x, child_y, count_width, control_height, TRUE);
    child_x += count_width + padding;
    MoveWindow(search_previous, child_x, child_y, button_width, control_height, TRUE);
    child_x += button_width;
    MoveWindow(search_next, child_x, child_y, button_width, control_height, TRUE);
    child_x += button_width + padding;
    MoveWindow(search_close, child_x, child_y, button_width, control_height, TRUE);
}

static void send_search_query(void) {
    int wide_len = GetWindowTextLengthW(search_edit);
    WCHAR *wide = malloc(((size_t)wide_len + 1) * sizeof(*wide));
    if (!wide) return;
    GetWindowTextW(search_edit, wide, wide_len + 1);
    int utf8_len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, wide_len, NULL, 0, NULL, NULL);
    if (wide_len > 0 && utf8_len == 0) { free(wide); return; }
    const char prefix[] = "search:";
    size_t action_len = sizeof(prefix) - 1 + (size_t)utf8_len;
    char *value = malloc(action_len + 1);
    if (!value) { free(wide); return; }
    memcpy(value, prefix, sizeof(prefix) - 1);
    if (utf8_len > 0 && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            wide, wide_len, value + sizeof(prefix) - 1, utf8_len,
            NULL, NULL) == 0) {
        free(value);
        free(wide);
        return;
    }
    value[action_len] = 0;
    if (surface) ghostty_surface_binding_action(surface, value, action_len);
    free(value);
    free(wide);
}

static void show_search(const char *needle) {
    search_visible = FALSE;
    int wide_len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        needle, -1, NULL, 0);
    WCHAR *wide = wide_len > 0 ? malloc((size_t)wide_len * sizeof(*wide)) : NULL;
    if (wide && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            needle, -1, wide, wide_len) > 0)
        SetWindowTextW(search_edit, wide);
    else
        SetWindowTextW(search_edit, L"");
    free(wide);

    search_total = -1;
    search_selected = -1;
    update_search_count();
    search_visible = TRUE;
    ShowWindow(search_background, SW_SHOWNA);
    ShowWindow(search_edit, SW_SHOWNA);
    ShowWindow(search_count, SW_SHOWNA);
    ShowWindow(search_previous, SW_SHOWNA);
    ShowWindow(search_next, SW_SHOWNA);
    ShowWindow(search_close, SW_SHOWNA);
    layout_search(window);
    send_search_query();
    SetFocus(search_edit);
    SendMessageW(search_edit, EM_SETSEL, 0, -1);
}

static void hide_search(void) {
    search_visible = FALSE;
    ShowWindow(search_edit, SW_HIDE);
    ShowWindow(search_count, SW_HIDE);
    ShowWindow(search_previous, SW_HIDE);
    ShowWindow(search_next, SW_HIDE);
    ShowWindow(search_close, SW_HIDE);
    ShowWindow(search_background, SW_HIDE);
    if (GetFocus() != window) SetFocus(window);
}

static LRESULT CALLBACK search_edit_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_KEYDOWN) {
        if (wp == VK_RETURN) {
            binding_action((GetKeyState(VK_SHIFT) & 0x8000) ?
                "navigate_search:previous" : "navigate_search:next");
            return 0;
        }
        if (wp == VK_ESCAPE) {
            binding_action("end_search");
            return 0;
        }
    } else if (msg == WM_CHAR && (wp == VK_RETURN || wp == VK_ESCAPE)) {
        return 0;
    }
    return CallWindowProcW(search_edit_procedure, hwnd, msg, wp, lp);
}

static BOOL create_search_controls(HWND hwnd, HINSTANCE instance) {
    search_background = CreateWindowExW(0, L"STATIC", L"",
        WS_CHILD | SS_ETCHEDFRAME, 0, 0, 0, 0, hwnd, NULL, instance, NULL);
    search_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
        WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, hwnd,
        (HMENU)(INT_PTR)ID_SEARCH_EDIT, instance, NULL);
    search_count = CreateWindowExW(0, L"STATIC", L"0/0",
        WS_CHILD | SS_CENTER | SS_CENTERIMAGE, 0, 0, 0, 0, hwnd, NULL, instance, NULL);
    search_previous = CreateWindowExW(0, L"BUTTON", L"\x2191",
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd,
        (HMENU)(INT_PTR)ID_SEARCH_PREVIOUS, instance, NULL);
    search_next = CreateWindowExW(0, L"BUTTON", L"\x2193",
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd,
        (HMENU)(INT_PTR)ID_SEARCH_NEXT, instance, NULL);
    search_close = CreateWindowExW(0, L"BUTTON", L"\x00d7",
        WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd,
        (HMENU)(INT_PTR)ID_SEARCH_CLOSE, instance, NULL);
    if (!search_background || !search_edit || !search_count || !search_previous ||
            !search_next || !search_close)
        return FALSE;
    search_edit_procedure = (WNDPROC)SetWindowLongPtrW(search_edit, GWLP_WNDPROC,
        (LONG_PTR)search_edit_proc);
    if (!search_edit_procedure) return FALSE;
    set_search_font(GetDpiForWindow(hwnd));
    layout_search(hwnd);
    return TRUE;
}

static LRESULT CALLBACK procedure(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GHOSTTY_WAKE:
        if (app) ghostty_app_tick(app);
        return 0;
    case WM_GHOSTTY_SEARCH_OPEN: {
        char *needle = (char *)lp;
        show_search(needle ? needle : "");
        free(needle);
        return 0;
    }
    case WM_GHOSTTY_SEARCH_CLOSE:
        hide_search();
        return 0;
    case WM_GHOSTTY_SEARCH_TOTAL:
        search_total = (intptr_t)lp;
        update_search_count();
        return 0;
    case WM_GHOSTTY_SEARCH_SELECTED:
        search_selected = (intptr_t)lp;
        update_search_count();
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_SEARCH_EDIT:
            if (HIWORD(wp) == EN_CHANGE && search_visible) send_search_query();
            return 0;
        case ID_SEARCH_PREVIOUS:
            if (HIWORD(wp) == BN_CLICKED) {
                binding_action("navigate_search:previous");
                SetFocus(search_edit);
            }
            return 0;
        case ID_SEARCH_NEXT:
            if (HIWORD(wp) == BN_CLICKED) {
                binding_action("navigate_search:next");
                SetFocus(search_edit);
            }
            return 0;
        case ID_SEARCH_CLOSE:
            if (HIWORD(wp) == BN_CLICKED) binding_action("end_search");
            return 0;
        }
        break;
    case WM_SIZE:
        layout_search(hwnd);
        if (surface) {
            ghostty_surface_set_occlusion(surface, wp != SIZE_MINIMIZED);
            if (wp != SIZE_MINIMIZED)
                ghostty_surface_set_size(surface, LOWORD(lp), HIWORD(lp));
        }
        return 0;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
        if (surface) ghostty_surface_set_focus(surface, msg == WM_SETFOCUS);
        return 0;
    case WM_DPICHANGED: {
        set_search_font(HIWORD(wp));
        if (surface) {
            double scale = (double)HIWORD(wp) / 96.0;
            ghostty_surface_set_content_scale(surface, scale, scale);
        }
        RECT *rect = (RECT *)lp;
        SetWindowPos(hwnd, NULL, rect->left, rect->top,
            rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
    case WM_KEYUP: case WM_SYSKEYUP:
        if (surface) {
            bool release = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            ghostty_input_key_s key = {0};
            key.action = release ? GHOSTTY_ACTION_RELEASE :
                ((lp & (1 << 30)) ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS);
            key.mods = modifiers();
            key.unshifted_codepoint = MapVirtualKeyW((UINT)wp, MAPVK_VK_TO_CHAR) & 0x7fffffff;
            if (key.unshifted_codepoint >= 'A' && key.unshifted_codepoint <= 'Z')
                key.unshifted_codepoint += 'a' - 'A';
            key.keycode = (lp >> 16) & 255;
            if (lp & (1 << 24)) key.keycode |= 0xe000;
            BYTE keyboard[256];
            WCHAR chars[8];
            char utf8[32];
            if (!release && GetKeyboardState(keyboard)) {
                int count = ToUnicodeEx((UINT)wp, (UINT)((lp >> 16) & 255),
                    keyboard, chars, 8, 0, GetKeyboardLayout(0));
                if (count > 0 && chars[0] >= 32 && chars[0] != 127) {
                    int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                        chars, count, utf8, sizeof(utf8) - 1, NULL, NULL);
                    if (len > 0) { utf8[len] = 0; key.text = utf8; }
                }
            }
            ghostty_surface_key(surface, key);
        }
        return 0;
    case WM_CHAR: case WM_SYSCHAR:
        if (surface) {
            // Control keys are encoded by ghostty_surface_key above.
            if (wp < 32 || wp == 127) return 0;
            WCHAR chars[2] = { (WCHAR)wp, 0 };
            int count = 1;
            if (IS_HIGH_SURROGATE(chars[0])) { high_surrogate = chars[0]; return 0; }
            if (IS_LOW_SURROGATE(chars[0])) {
                if (!high_surrogate) return 0;
                chars[1] = chars[0]; chars[0] = high_surrogate; count = 2;
            }
            high_surrogate = 0;
            char utf8[8];
            int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                chars, count, utf8, sizeof(utf8), NULL, NULL);
            if (len > 0) {
                utf8[len] = 0;
                ghostty_input_key_s key = {0};
                key.action = GHOSTTY_ACTION_PRESS;
                key.mods = modifiers();
                key.text = utf8;
                ghostty_surface_key(surface, key);
            }
        }
        return 0;
    case WM_MOUSEMOVE:
        if (surface) ghostty_surface_mouse_pos(surface, GET_X_LPARAM(lp), GET_Y_LPARAM(lp), modifiers());
        return 0;
    case WM_LBUTTONDOWN: case WM_LBUTTONUP:
        if (msg == WM_LBUTTONDOWN) SetCapture(hwnd); else ReleaseCapture();
        if (surface) ghostty_surface_mouse_button(surface,
            msg == WM_LBUTTONDOWN ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT, modifiers());
        return 0;
    case WM_MOUSEWHEEL:
        if (surface) ghostty_surface_mouse_scroll(surface, 0,
            (double)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA, 0);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        BeginPaint(hwnd, &paint);
        EndPaint(hwnd, &paint);
        if (surface) ghostty_surface_refresh(surface);
        return 0;
    }
    case WM_CLOSE:
        // Join renderer/PTY threads before destroying the HWND and its DC.
        if (surface) { ghostty_surface_free(surface); surface = NULL; }
        if (app) { ghostty_app_free(app); app = NULL; }
        DestroyWindow(hwnd);
        if (search_font) { DeleteObject(search_font); search_font = NULL; }
        return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
int main(int argc, char **argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (!GetEnvironmentVariableW(L"GHOSTTY_LOG", NULL, 0))
        SetEnvironmentVariableW(L"GHOSTTY_LOG", L"stderr");
    if (ghostty_init(argc, argv) != 0) { fprintf(stderr, "ghostty_init failed\n"); return 1; }
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = procedure;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(NULL, IDC_IBEAM);
    wc.lpszClassName = L"GhosttyWin32Sample";
    if (!RegisterClassW(&wc)) { fprintf(stderr, "RegisterClass failed: %lu\n", GetLastError()); return 1; }
    window = CreateWindowExW(0, wc.lpszClassName, L"Ghostty — Win32 OpenGL sample",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 700,
        NULL, NULL, instance, NULL);
    if (!window) { fprintf(stderr, "CreateWindow failed: %lu\n", GetLastError()); return 1; }
    if (!create_search_controls(window, instance)) {
        fprintf(stderr, "Creating search controls failed: %lu\n", GetLastError());
        DestroyWindow(window);
        return 1;
    }
    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_default_files(config);
    ghostty_config_load_cli_args(config);
    ghostty_config_load_recursive_files(config);
    ghostty_config_finalize(config);
    ghostty_runtime_config_s runtime = {
        .wakeup_cb = wake, .action_cb = action,
        .read_clipboard_cb = read_clipboard, .confirm_read_clipboard_cb = confirm_clipboard,
        .write_clipboard_cb = write_clipboard, .close_surface_cb = close_surface,
    };
    app = ghostty_app_new(&runtime, config);
    ghostty_config_free(config);
    if (!app) goto fail;
    ghostty_surface_config_s options = ghostty_surface_config_new();
    options.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    options.platform.windows.hwnd = window;
    options.scale_factor = (double)GetDpiForWindow(window) / 96.0;
    surface = ghostty_surface_new(app, &options);
    if (!surface) goto fail;
    RECT rect;
    GetClientRect(window, &rect);
    ghostty_surface_set_size(surface, rect.right, rect.bottom);
    ShowWindow(window, SW_SHOW);
    ghostty_surface_set_occlusion(surface, true);
    ghostty_surface_set_focus(surface, true);
    MSG msg;
    int result;
    while ((result = GetMessageW(&msg, NULL, 0, 0)) > 0) {
        // ToUnicodeEx supplies text with each key event. TranslateMessage
        // would also enqueue WM_CHAR and insert the same text twice.
        // The native search edit does need WM_CHAR, so translate only its
        // messages and keep terminal input on the direct Ghostty path.
        if (search_visible && msg.message == WM_KEYDOWN &&
                msg.wParam == VK_ESCAPE && IsChild(window, msg.hwnd)) {
            binding_action("end_search");
            continue;
        }
        if (msg.hwnd == search_edit) TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return result < 0 ? 1 : 0;
fail:
    fprintf(stderr, "Ghostty initialization failed; see diagnostics above. OpenGL 4.3 is required.\n");
    SendMessageW(window, WM_CLOSE, 0, 0);
    return 1;
}
