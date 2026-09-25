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

/* Read the completed swapchain pass before present. Pixels are top-down RGBA. */
bool hollow_capture_frame(uint8_t* rgba, int width, int height) {
    if (!rgba || width <= 0 || height <= 0) return false;
#if defined(_WIN32)
    ID3D11Device* device = (ID3D11Device*) sg_d3d11_device();
    ID3D11DeviceContext* context = (ID3D11DeviceContext*) sg_d3d11_device_context();
    sg_swapchain swapchain = sglue_swapchain();
    ID3D11RenderTargetView* view = (ID3D11RenderTargetView*) swapchain.d3d11.render_view;
    if (!device || !context || !view) return false;
    ID3D11Resource* resource = NULL;
    ID3D11Texture2D* staging = NULL;
    view->lpVtbl->GetResource(view, &resource);
    if (!resource) return false;
    D3D11_TEXTURE2D_DESC desc;
    ((ID3D11Texture2D*) resource)->lpVtbl->GetDesc((ID3D11Texture2D*) resource, &desc);
    if (desc.Width != (UINT)width || desc.Height != (UINT)height || desc.SampleDesc.Count != 1) goto fail;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    if (FAILED(device->lpVtbl->CreateTexture2D(device, &desc, NULL, &staging))) goto fail;
    context->lpVtbl->CopyResource(context, (ID3D11Resource*)staging, resource);
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(context->lpVtbl->Map(context, (ID3D11Resource*)staging, 0, D3D11_MAP_READ, 0, &mapped))) goto fail;
    for (int y = 0; y < height; y++) {
        const uint8_t* src = (const uint8_t*)mapped.pData + (size_t)y * mapped.RowPitch;
        uint8_t* dst = rgba + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) {
            dst[x * 4] = src[x * 4 + 2];
            dst[x * 4 + 1] = src[x * 4 + 1];
            dst[x * 4 + 2] = src[x * 4];
            dst[x * 4 + 3] = src[x * 4 + 3];
        }
    }
    context->lpVtbl->Unmap(context, (ID3D11Resource*)staging, 0);
    staging->lpVtbl->Release(staging);
    resource->lpVtbl->Release(resource);
    return true;
fail:
    if (staging) staging->lpVtbl->Release(staging);
    resource->lpVtbl->Release(resource);
    return false;
#else
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    if (glGetError() != GL_NO_ERROR) return false;
    for (int y = 0; y < height / 2; y++) {
        uint8_t* top = rgba + (size_t)y * width * 4;
        uint8_t* bottom = rgba + (size_t)(height - 1 - y) * width * 4;
        for (int i = 0; i < width * 4; i++) {
            uint8_t tmp = top[i]; top[i] = bottom[i]; bottom[i] = tmp;
        }
    }
    return true;
#endif
}

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
