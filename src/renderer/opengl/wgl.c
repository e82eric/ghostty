#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>
#include <stdlib.h>

typedef struct { HWND window; HDC dc; HGLRC context; } GhosttyWGL;
typedef HGLRC (WINAPI *CreateContextAttribs)(HDC, HGLRC, const int *);
typedef BOOL (WINAPI *SwapInterval)(int);

void *ghostty_wgl_proc(const char *name) {
    PROC proc = wglGetProcAddress(name);
    if (!proc || proc == (PROC)1 || proc == (PROC)2 ||
        proc == (PROC)3 || proc == (PROC)-1)
        proc = GetProcAddress(GetModuleHandleW(L"opengl32.dll"), name);
    return (void *)proc;
}

void *ghostty_wgl_create(void *window) {
    GhosttyWGL *gl = calloc(1, sizeof(*gl));
    if (!gl) return NULL;
    gl->window = window;
    gl->dc = GetDC(gl->window);
    if (!gl->dc) goto fail;
    PIXELFORMATDESCRIPTOR format = {
        .nSize = sizeof(format), .nVersion = 1,
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA, .cColorBits = 32, .cAlphaBits = 8,
        .iLayerType = PFD_MAIN_PLANE,
    };
    int index = ChoosePixelFormat(gl->dc, &format);
    if (!index || !SetPixelFormat(gl->dc, index, &format)) goto fail;
    HGLRC bootstrap = wglCreateContext(gl->dc);
    if (!bootstrap) goto fail;
    if (!wglMakeCurrent(gl->dc, bootstrap)) {
        wglDeleteContext(bootstrap);
        goto fail;
    }
    CreateContextAttribs create = (CreateContextAttribs)ghostty_wgl_proc("wglCreateContextAttribsARB");
    const int attributes[] = { 0x2091, 4, 0x2092, 3, 0x9126, 1, 0 };
    if (create) gl->context = create(gl->dc, NULL, attributes);
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(bootstrap);
    if (!gl->context) goto fail;
    return gl;
fail:
    if (gl->dc) ReleaseDC(gl->window, gl->dc);
    free(gl);
    return NULL;
}

int ghostty_wgl_enter(void *ptr, int vsync) {
    GhosttyWGL *gl = ptr;
    if (!wglMakeCurrent(gl->dc, gl->context)) return 0;
    SwapInterval interval = (SwapInterval)ghostty_wgl_proc("wglSwapIntervalEXT");
    if (interval) interval(vsync);
    return 1;
}
void ghostty_wgl_leave(void) { wglMakeCurrent(NULL, NULL); }
int ghostty_wgl_swap(void *ptr) { return SwapBuffers(((GhosttyWGL *)ptr)->dc); }
void ghostty_wgl_destroy(void *ptr) {
    GhosttyWGL *gl = ptr;
    wglDeleteContext(gl->context);
    ReleaseDC(gl->window, gl->dc);
    free(gl);
}
