#if defined(_WIN32)
#define SOKOL_D3D11
#else
#define SOKOL_GLCORE
#endif
#define SOKOL_IMPL
#define SOKOL_NO_ENTRY

#define FONTSTASH_IMPLEMENTATION
#define STB_TRUETYPE_IMPLEMENTATION

#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_log.h"
#include "sokol_glue.h"
#include "util/sokol_gl.h"
#include "util/sokol_debugtext.h"
#include "fontstash.h"
#include "util/sokol_fontstash.h"

#if !defined(_WIN32)
#include <stdint.h>

void hollow_linux_set_window_decorated(bool decorated) {
    typedef struct {
        unsigned long flags;
        unsigned long functions;
        unsigned long decorations;
        long input_mode;
        unsigned long status;
    } MotifWmHints;

    Display* display = (Display*) sapp_x11_get_display();
    Window window = (Window) (uintptr_t) sapp_x11_get_window();
    if (!display || !window) return;

    const Atom hints_atom = XInternAtom(display, "_MOTIF_WM_HINTS", False);
    MotifWmHints hints = { .flags = 2, .decorations = decorated ? 1 : 0 };
    XChangeProperty(display, window, hints_atom, hints_atom, 32, PropModeReplace,
        (unsigned char*) &hints, 5);
    XFlush(display);
}

void hollow_linux_begin_window_drag(void) {
    Display* display = (Display*) sapp_x11_get_display();
    Window window = (Window) (uintptr_t) sapp_x11_get_window();
    if (!display || !window) return;

    Window root, child;
    int root_x, root_y, window_x, window_y;
    unsigned int mask;
    if (!XQueryPointer(display, window, &root, &child, &root_x, &root_y,
        &window_x, &window_y, &mask)) return;

    XEvent event = {0};
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = XInternAtom(display, "_NET_WM_MOVERESIZE", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = root_x;
    event.xclient.data.l[1] = root_y;
    event.xclient.data.l[2] = 8; /* _NET_WM_MOVERESIZE_MOVE */
    event.xclient.data.l[3] = Button1;
    event.xclient.data.l[4] = 1; /* normal application source */
    XSendEvent(display, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
}

static struct {
    Display* display;
    Window window;
    int direction;
    int pointer_x;
    int pointer_y;
    int window_x;
    int window_y;
    unsigned int width;
    unsigned int height;
    bool active;
} hollow_linux_resize;

bool hollow_linux_begin_window_resize(int direction) {
    Display* display = (Display*) sapp_x11_get_display();
    Window window = (Window) (uintptr_t) sapp_x11_get_window();
    if (!display || !window || direction < 0 || direction > 7) return false;

    Window root, child;
    int root_x, root_y, window_x, window_y;
    unsigned int mask;
    if (!XQueryPointer(display, window, &root, &child, &root_x, &root_y,
        &window_x, &window_y, &mask)) return false;

    XWindowAttributes attrs;
    if (!XGetWindowAttributes(display, window, &attrs)) return false;
    int origin_x, origin_y;
    if (!XTranslateCoordinates(display, window, root, 0, 0, &origin_x, &origin_y, &child)) return false;

    hollow_linux_resize = (typeof(hollow_linux_resize)) {
        .display = display,
        .window = window,
        .direction = direction,
        .pointer_x = root_x,
        .pointer_y = root_y,
        .window_x = origin_x,
        .window_y = origin_y,
        .width = (unsigned int) attrs.width,
        .height = (unsigned int) attrs.height,
        .active = true,
    };
    XGrabPointer(display, window, False, PointerMotionMask | ButtonReleaseMask,
        GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
    return true;
}

void hollow_linux_update_window_resize(void) {
    if (!hollow_linux_resize.active) return;

    Window root, child;
    int root_x, root_y, window_x, window_y;
    unsigned int mask;
    if (!XQueryPointer(hollow_linux_resize.display, hollow_linux_resize.window,
        &root, &child, &root_x, &root_y, &window_x, &window_y, &mask)) return;

    const int dx = root_x - hollow_linux_resize.pointer_x;
    const int dy = root_y - hollow_linux_resize.pointer_y;
    int x = hollow_linux_resize.window_x;
    int y = hollow_linux_resize.window_y;
    int width = (int) hollow_linux_resize.width;
    int height = (int) hollow_linux_resize.height;
    const bool west = hollow_linux_resize.direction == 0 || hollow_linux_resize.direction == 6 || hollow_linux_resize.direction == 7;
    const bool east = hollow_linux_resize.direction == 2 || hollow_linux_resize.direction == 3 || hollow_linux_resize.direction == 4;
    const bool north = hollow_linux_resize.direction == 0 || hollow_linux_resize.direction == 1 || hollow_linux_resize.direction == 2;
    const bool south = hollow_linux_resize.direction == 4 || hollow_linux_resize.direction == 5 || hollow_linux_resize.direction == 6;
    const int min_width = 160;
    const int min_height = 100;

    if (west) { x += dx; width -= dx; }
    if (east) width += dx;
    if (north) { y += dy; height -= dy; }
    if (south) height += dy;
    if (width < min_width) { if (west) x -= min_width - width; width = min_width; }
    if (height < min_height) { if (north) y -= min_height - height; height = min_height; }
    XMoveResizeWindow(hollow_linux_resize.display, hollow_linux_resize.window,
        x, y, (unsigned int) width, (unsigned int) height);
    XFlush(hollow_linux_resize.display);
}

void hollow_linux_end_window_resize(void) {
    if (!hollow_linux_resize.active) return;
    XUngrabPointer(hollow_linux_resize.display, CurrentTime);
    XFlush(hollow_linux_resize.display);
    hollow_linux_resize.active = false;
}
#else
void hollow_linux_set_window_decorated(bool decorated) {
    (void) decorated;
}
void hollow_linux_begin_window_drag(void) {}
bool hollow_linux_begin_window_resize(int direction) {
    (void) direction;
    return false;
}
void hollow_linux_update_window_resize(void) {}
void hollow_linux_end_window_resize(void) {}
#endif
