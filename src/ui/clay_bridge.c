#define CLAY_IMPLEMENTATION
#include "clay_bridge.h"
#include <stdlib.h>

struct HollowClay {
    Clay_Context *context;
    void *memory;
    float cell_w, cell_h;
    bool failed;
    HollowClayFrame frame;
    float width, height;
};

static void on_error(Clay_ErrorData error) {
    ((HollowClay *)error.userData)->failed = true;
}

static Clay_Dimensions measure(Clay_StringSlice text, Clay_TextElementConfig *config, void *data) {
    (void)config;
    HollowClay *surface = data;
    int codepoints = 0;
    for (int i = 0; i < text.length; ++i)
        if (((unsigned char)text.chars[i] & 0xc0) != 0x80) ++codepoints;
    return (Clay_Dimensions){ codepoints * surface->cell_w, surface->cell_h };
}

HollowClay *hollow_clay_create(void) {
    HollowClay *surface = calloc(1, sizeof(*surface));
    if (!surface) return NULL;
    Clay_Context *previous = Clay_GetCurrentContext();
    Clay_SetCurrentContext(NULL);
    // Also accommodates the optional inspector without growing arenas at runtime.
    Clay_SetMaxElementCount(2048);
    Clay_SetMaxMeasureTextCacheWordCount(4096);
    uint32_t size = Clay_MinMemorySize();
    surface->memory = malloc(size);
    if (!surface->memory) { Clay_SetCurrentContext(previous); free(surface); return NULL; }
    surface->context = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, surface->memory),
        (Clay_Dimensions){1, 1}, (Clay_ErrorHandler){on_error, surface});
    Clay_SetMeasureTextFunction(measure, surface);
    return surface;
}

void hollow_clay_destroy(HollowClay *surface) {
    if (!surface) return;
    if (Clay_GetCurrentContext() == surface->context) Clay_SetCurrentContext(NULL);
    free(surface->memory);
    free(surface);
}

static Clay_SizingAxis sizing(float value) {
    if (value < 0) return CLAY_SIZING_GROW(0);
    if (value > 0) return CLAY_SIZING_FIXED(value);
    return CLAY_SIZING_FIT(0);
}

static float min_size(float value, float max) { return value < max ? value : max; }

static Clay_ElementId node_id(HollowClayNode *node, int index) {
    return node->id.length ? Clay_GetElementId(node->id) : CLAY_IDI("hollow.layout", index);
}

static void declare_node(HollowClayNode *nodes, int count, int *cursor, int depth, HollowClay *surface) {
    if (*cursor >= count || depth > 32) { surface->failed = true; return; }
    int index = (*cursor)++;
    HollowClayNode *node = &nodes[index];
    Clay_ElementId id = node_id(node, index);
    if (node->kind == 2) {
        CLAY_TEXT(node->text, { .textColor = node->fg, .fontId = node->bold ? 1 : 0,
            .fontSize = (uint16_t)surface->cell_h, .lineHeight = (uint16_t)surface->cell_h });
        return;
    }
    Clay_Color bg = node->bg;
    if (node->hover_bg.a && Clay_PointerOver(id)) bg = node->hover_bg;
    Clay_Sizing sizes = { sizing(node->width), sizing(node->height) };
    if (index == 0 && surface->frame.enabled) {
        float max_w = surface->width - surface->frame.margin.left - surface->frame.margin.right;
        float max_h = surface->height - surface->frame.margin.top - surface->frame.margin.bottom;
        if (max_w < 1) max_w = 1;
        if (max_h < 1) max_h = 1;
        sizes.width = surface->frame.width > 0 ? CLAY_SIZING_FIXED(min_size(surface->frame.width, max_w)) : CLAY_SIZING_FIT(0, max_w);
        sizes.height = surface->frame.height > 0 ? CLAY_SIZING_FIXED(min_size(surface->frame.height, max_h)) : CLAY_SIZING_FIT(0, max_h);
    }
    CLAY(id, {
        .layout = { .sizing = sizes,
            .padding = node->padding, .childGap = node->gap,
            .layoutDirection = node->kind == 1 ? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM },
        .backgroundColor = bg, .cornerRadius = CLAY_CORNER_RADIUS(node->radius),
        .border = { .color = node->border, .width = CLAY_BORDER_ALL(node->border_size) },
        .clip = { .horizontal = index == 0 && surface->frame.enabled,
            .vertical = node->scroll || (index == 0 && surface->frame.enabled),
            .childOffset = node->scroll ? Clay_GetScrollOffset() : (Clay_Vector2){0, 0} },
        .custom = { .customData = node->kind == 3 ? node : NULL },
    }) {
        for (int i = 0; i < node->children && !surface->failed; ++i)
            declare_node(nodes, count, cursor, depth + 1, surface);
    }
}

Clay_RenderCommandArray hollow_clay_layout(HollowClay *surface, HollowClayNode *nodes, int count,
    float width, float height, float cell_w, float cell_h, float mouse_x, float mouse_y,
    float scroll_y, float delta_time) {
    Clay_SetCurrentContext(surface->context);
    surface->failed = false;
    if (surface->cell_w != cell_w || surface->cell_h != cell_h) Clay_ResetMeasureTextCache();
    surface->cell_w = cell_w;
    surface->cell_h = cell_h;
    surface->width = width;
    surface->height = height;
    Clay_SetLayoutDimensions((Clay_Dimensions){width, height});
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, scroll_y}, delta_time);
    Clay_BeginLayout();
    int cursor = 0;
    if (surface->frame.enabled) {
        CLAY(CLAY_ID("hollow.layout.host"), {
            .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
                .padding = surface->frame.margin,
                .childAlignment = {
                    surface->frame.align_x == 0 ? CLAY_ALIGN_X_LEFT : (surface->frame.align_x == 2 ? CLAY_ALIGN_X_RIGHT : CLAY_ALIGN_X_CENTER),
                    surface->frame.align_y == 0 ? CLAY_ALIGN_Y_TOP : (surface->frame.align_y == 2 ? CLAY_ALIGN_Y_BOTTOM : CLAY_ALIGN_Y_CENTER) },
                .layoutDirection = CLAY_TOP_TO_BOTTOM },
            .clip = { .horizontal = true, .vertical = true },
        }) {
            if (count > 0) declare_node(nodes, count, &cursor, 0, surface);
        }
    } else if (count > 0) declare_node(nodes, count, &cursor, 0, surface);
    if (cursor != count) surface->failed = true;
    Clay_RenderCommandArray commands = Clay_EndLayout(delta_time);
    // Refresh overlaps against this layout, not last frame's geometry.
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, false);
    return commands;
}

bool hollow_clay_failed(HollowClay *surface) { return surface->failed; }

void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame) { surface->frame = frame; }

Clay_ElementData hollow_clay_bounds(HollowClay *surface, HollowClayNode *nodes, int index) {
    Clay_SetCurrentContext(surface->context);
    return Clay_GetElementData(node_id(&nodes[index], index));
}

int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y) {
    Clay_SetCurrentContext(surface->context);
    Clay_SetPointerState((Clay_Vector2){x, y}, false);
    for (int i = count - 1; i >= 0; --i)
        if (nodes[i].clickable && Clay_PointerOver(node_id(&nodes[i], i))) return i;
    return -1;
}
