#define CLAY_IMPLEMENTATION
#include "clay_bridge.h"
#include <stdlib.h>

struct HollowClay {
    Clay_Context *context;
    void *memory;
    float cell_w, cell_h;
    bool failed;
    Clay_String error;
    HollowClayFrame frame;
    float width, height;
    // Geometry of the latest layout, indexed like its input nodes.
    int count;
    Clay_ElementData bounds[HOLLOW_CLAY_MAX_NODES];
    Clay_ElementData visible[HOLLOW_CLAY_MAX_NODES];
};

static void on_error(Clay_ErrorData error) {
    HollowClay *surface = error.userData;
    if (!surface->failed) surface->error = error.errorText;
    surface->failed = true;
}

static Clay_Dimensions measure(Clay_StringSlice text, Clay_TextElementConfig *config, void *data) {
    (void)config;
    HollowClay *surface = data;
    int codepoints = 0;
    for (int i = 0; i < text.length; ++i)
        if (((unsigned char)text.chars[i] & 0xc0) != 0x80) ++codepoints;
    return (Clay_Dimensions){ codepoints * surface->cell_w, surface->cell_h };
}

#define HOLLOW_CLAY_ELEMENTS 2048

static bool init_context(HollowClay *surface, int32_t elements) {
    Clay_Context *previous = Clay_GetCurrentContext();
    Clay_SetCurrentContext(NULL);
    Clay_SetMaxElementCount(elements);
    Clay_SetMaxMeasureTextCacheWordCount(elements * 2);
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    if (!memory) { Clay_SetCurrentContext(previous); return false; }
    if (previous == surface->context) previous = NULL;
    free(surface->memory);
    surface->memory = memory;
    surface->context = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
        (Clay_Dimensions){1, 1}, (Clay_ErrorHandler){on_error, surface});
    Clay_SetMeasureTextFunction(measure, surface);
    Clay_SetCurrentContext(previous);
    return true;
}

HollowClay *hollow_clay_create(void) {
    HollowClay *surface = calloc(1, sizeof(*surface));
    if (!surface) return NULL;
    if (!init_context(surface, HOLLOW_CLAY_ELEMENTS)) { free(surface); return NULL; }
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

static void hash_ids(HollowClayNode *nodes, int count) {
    for (int i = 0; i < count; ++i)
        nodes[i].element_id = nodes[i].id.length ? Clay_GetElementId(nodes[i].id) : CLAY_IDI("hollow.layout", i);
}

static void declare_node(HollowClayNode *nodes, int count, int *cursor, int depth, HollowClay *surface) {
    if (*cursor >= count || depth > 32) { surface->failed = true; return; }
    int index = (*cursor)++;
    HollowClayNode *node = &nodes[index];
    if (node->kind == 2) {
        CLAY_TEXT(node->text, { .textColor = node->fg, .fontId = node->bold ? 1 : 0,
            .fontSize = (uint16_t)surface->cell_h, .lineHeight = (uint16_t)surface->cell_h,
            .wrapMode = (Clay_TextElementConfigWrapMode)node->wrap });
        return;
    }
    Clay_Sizing sizes = { sizing(node->width), sizing(node->height) };
    if (index == 0 && surface->frame.enabled) {
        float max_w = surface->width - surface->frame.margin.left - surface->frame.margin.right;
        float max_h = surface->height - surface->frame.margin.top - surface->frame.margin.bottom;
        if (max_w < 1) max_w = 1;
        if (max_h < 1) max_h = 1;
        sizes.width = surface->frame.width > 0 ? CLAY_SIZING_FIXED(min_size(surface->frame.width, max_w)) : CLAY_SIZING_FIT(0, max_w);
        sizes.height = surface->frame.height > 0 ? CLAY_SIZING_FIXED(min_size(surface->frame.height, max_h)) : CLAY_SIZING_FIT(0, max_h);
    }
    // CLAY() opens the element before evaluating its declaration, so
    // Clay_Hovered() refers to this node.
    CLAY(node->element_id, {
        .userData = node,
        .layout = { .sizing = sizes,
            .padding = node->padding, .childGap = node->gap,
            .childAlignment = { .y = node->align_y == 1 ? CLAY_ALIGN_Y_CENTER : (node->align_y == 2 ? CLAY_ALIGN_Y_BOTTOM : CLAY_ALIGN_Y_TOP) },
            .layoutDirection = node->kind == 1 ? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM },
        .backgroundColor = node->hover_bg.a && Clay_Hovered() ? node->hover_bg : node->bg,
        .cornerRadius = CLAY_CORNER_RADIUS(node->radius),
        .border = { .color = node->border, .width = CLAY_BORDER_ALL(node->border_size) },
        // Clay clip flags opt into overflow sizing on that axis. Only scroll
        // viewports use them; the renderer clips framed panels independently.
        .clip = { .horizontal = node->scroll_x,
            .vertical = node->scroll,
            .childOffset = (node->scroll || node->scroll_x) ? Clay_GetScrollOffset() : (Clay_Vector2){0, 0} },
        .custom = { .customData = node->kind == 3 ? node : NULL },
    }) {
        for (int i = 0; i < node->children && !surface->failed; ++i)
            declare_node(nodes, count, cursor, depth + 1, surface);
    }
}

static Clay_RenderCommandArray build_layout(HollowClay *surface, HollowClayNode *nodes, int count, float delta_time) {
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
    return Clay_EndLayout(delta_time);
}

static float reveal_axis(float offset, float start, float size, float view_start, float view_size, float max_scroll, bool align_start) {
    if (view_size <= 0) return offset;
    if (align_start || size > view_size || start < view_start) offset += view_start - start;
    else if (start + size > view_start + view_size) offset -= start + size - view_start - view_size;
    if (max_scroll < 0) max_scroll = 0;
    if (offset < -max_scroll) offset = -max_scroll;
    return offset > 0 ? 0 : offset;
}

static bool reveal_targets(HollowClayNode *nodes, int count) {
    bool changed = false;
    for (int i = 0; i < count; ++i) {
        HollowClayNode *node = &nodes[i];
        if (!node->reveal.length || (!node->scroll && !node->scroll_x)) continue;
        Clay_ScrollContainerData scroll = Clay_GetScrollContainerData(node->element_id);
        Clay_ElementData view = Clay_GetElementData(node->element_id);
        Clay_ElementData target = Clay_GetElementData(Clay_GetElementId(node->reveal));
        if (!scroll.found || !view.found || !target.found) continue;
        Clay_Vector2 before = *scroll.scrollPosition;
        Clay_BoundingBox v = view.boundingBox, t = target.boundingBox;
        if (node->scroll_x) scroll.scrollPosition->x = reveal_axis(before.x, t.x, t.width,
            v.x + node->padding.left, v.width - node->padding.left - node->padding.right,
            scroll.contentDimensions.width - v.width, node->reveal_start);
        if (node->scroll) scroll.scrollPosition->y = reveal_axis(before.y, t.y, t.height,
            v.y + node->padding.top, v.height - node->padding.top - node->padding.bottom,
            scroll.contentDimensions.height - v.height, node->reveal_start);
        if (before.x != scroll.scrollPosition->x || before.y != scroll.scrollPosition->y) changed = true;
    }
    return changed;
}

static void intersect_bounds(Clay_BoundingBox *bounds, Clay_BoundingBox clip, bool horizontal, bool vertical) {
    if (horizontal) {
        float right = min_size(bounds->x + bounds->width, clip.x + clip.width);
        if (bounds->x < clip.x) bounds->x = clip.x;
        bounds->width = right > bounds->x ? right - bounds->x : 0;
    }
    if (vertical) {
        float bottom = min_size(bounds->y + bounds->height, clip.y + clip.height);
        if (bounds->y < clip.y) bounds->y = clip.y;
        bounds->height = bottom > bounds->y ? bottom - bounds->y : 0;
    }
}

// One preorder pass with a clip stack. Sibling clips never affect each other;
// scroll viewports clip their axes and a framed panel is paint-clipped on both.
static void record_bounds(HollowClay *surface, HollowClayNode *nodes, int count) {
    Clay_BoundingBox clips[34];
    int remaining[34], depth = 0;
    Clay_BoundingBox host = { 0, 0, surface->width, surface->height };
    surface->count = 0;
    for (int i = 0; i < count; ++i) {
        while (depth > 0 && remaining[depth - 1] == 0) --depth;
        if (depth > 0) --remaining[depth - 1];
        Clay_BoundingBox clip = depth > 0 ? clips[depth - 1] : host;
        Clay_ElementData element = Clay_GetElementData(nodes[i].element_id);
        Clay_ElementData visible = element;
        if (visible.found) {
            intersect_bounds(&visible.boundingBox, clip, true, true);
            visible.found = visible.boundingBox.width > 0 && visible.boundingBox.height > 0;
        }
        surface->bounds[i] = element;
        surface->visible[i] = visible;
        if (nodes[i].children > 0) {
            if (depth >= 34) { surface->failed = true; return; }
            bool panel = i == 0 && surface->frame.enabled;
            if (element.found && (panel || nodes[i].scroll || nodes[i].scroll_x))
                intersect_bounds(&clip, element.boundingBox, panel || nodes[i].scroll_x, panel || nodes[i].scroll);
            clips[depth] = clip;
            remaining[depth++] = nodes[i].children;
        }
    }
    surface->count = count;
}

Clay_RenderCommandArray hollow_clay_layout(HollowClay *surface, HollowClayNode *nodes, int count,
    float width, float height, float cell_w, float cell_h, float mouse_x, float mouse_y,
    float scroll_y, float delta_time) {
    Clay_SetCurrentContext(surface->context);
    surface->failed = false;
    surface->error = (Clay_String){0};
    surface->count = 0;
    if (count < 0 || count > HOLLOW_CLAY_MAX_NODES) {
        surface->failed = true;
        surface->error = CLAY_STRING("Layout exceeds the supported node count.");
        return (Clay_RenderCommandArray){0};
    }
    if (surface->cell_w != cell_w || surface->cell_h != cell_h) Clay_ResetMeasureTextCache();
    surface->cell_w = cell_w;
    surface->cell_h = cell_h;
    surface->width = width;
    surface->height = height;
    hash_ids(nodes, count);
    Clay_SetLayoutDimensions((Clay_Dimensions){width, height});
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, scroll_y}, delta_time);
    Clay_RenderCommandArray commands = build_layout(surface, nodes, count, delta_time);
    // Resolve caret visibility using actual Clay bounds, not Lua character-budget math.
    // A second pass applies changed offsets before painting the same frame.
    if (!surface->failed && reveal_targets(nodes, count)) commands = build_layout(surface, nodes, count, 0);
    // Refresh overlaps against this layout, not last frame's geometry.
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, false);
    if (!surface->failed) record_bounds(surface, nodes, count);
    return commands;
}

bool hollow_clay_failed(HollowClay *surface) { return surface->failed; }

Clay_String hollow_clay_error(HollowClay *surface) { return surface->error; }

void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame) { surface->frame = frame; }

Clay_ElementData hollow_clay_bounds(HollowClay *surface, HollowClayNode *nodes, int index) {
    (void)nodes;
    if (index < 0 || index >= surface->count) return (Clay_ElementData){0};
    return surface->bounds[index];
}

Clay_ElementData hollow_clay_visible_bounds(HollowClay *surface, HollowClayNode *nodes, int count, int index) {
    (void)nodes;
    if (index < 0 || index >= count || index >= surface->count) return (Clay_ElementData){0};
    return surface->visible[index];
}

// Topmost clickable node under the point. Nodes are painted in preorder and
// visible bounds already include every clipping ancestor.
int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y) {
    if (count > surface->count) count = surface->count;
    for (int i = count - 1; i >= 0; --i) {
        if (!nodes[i].clickable || !surface->visible[i].found) continue;
        Clay_BoundingBox b = surface->visible[i].boundingBox;
        if (x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height) return i;
    }
    return -1;
}

