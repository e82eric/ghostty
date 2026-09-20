#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <ghostty.h>
#include <stdio.h>

#define WM_GHOSTTY_WAKE (WM_APP + 1)
static HWND window;
static ghostty_app_t app;
static ghostty_surface_t surface;
static WCHAR high_surrogate;

static void wake(void *data) {
    (void)data;
    PostMessageW(window, WM_GHOSTTY_WAKE, 0, 0);
}
static bool action(ghostty_app_t a, ghostty_target_s target, ghostty_action_s value) {
    (void)a; (void)target; (void)value;
    return false;
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
static LRESULT CALLBACK procedure(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GHOSTTY_WAKE:
        if (app) ghostty_app_tick(app);
        return 0;
    case WM_SIZE:
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
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 700,
        NULL, NULL, instance, NULL);
    if (!window) { fprintf(stderr, "CreateWindow failed: %lu\n", GetLastError()); return 1; }
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
        DispatchMessageW(&msg);
    }
    return result < 0 ? 1 : 0;
fail:
    fprintf(stderr, "Ghostty initialization failed; see diagnostics above. OpenGL 4.3 is required.\n");
    SendMessageW(window, WM_CLOSE, 0, 0);
    return 1;
}
