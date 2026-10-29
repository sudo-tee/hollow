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

// Clay's update removes retired records with swapback while advancing its
// cursor, leaving some swapped records behind. Bounded list windows can replace
// every column each frame; prune absent IDs before that update so stale records
// never exhaust the pinned library's fixed 100-record scroll array.
static void prune_scroll_containers(HollowClay *surface, HollowClayNode *nodes, int count) {
    uint32_t ids[512];
    int length = 0;
    for (int i = 0; i < count && length < 512; ++i)
        if (nodes[i].scroll || nodes[i].scroll_x) ids[length++] = node_id(&nodes[i], i).id;
    Clay__ScrollContainerDataInternalArray *records = &surface->context->scrollContainerDatas;
    for (int i = 0; i < records->length;) {
        bool present = false;
        for (int j = 0; j < length; ++j)
            if (records->internalArray[i].elementId == ids[j]) { present = true; break; }
        if (present) ++i;
        else Clay__ScrollContainerDataInternalArray_RemoveSwapback(records, i);
    }
}

static void declare_node(HollowClayNode *nodes, int count, int *cursor, int depth, HollowClay *surface) {
    if (*cursor >= count || depth > 32) { surface->failed = true; return; }
    int index = (*cursor)++;
    HollowClayNode *node = &nodes[index];
    Clay_ElementId id = node_id(node, index);
    if (node->kind == 2) {
        CLAY_TEXT(node->text, { .textColor = node->fg, .fontId = node->bold ? 1 : 0,
            .fontSize = (uint16_t)surface->cell_h, .lineHeight = (uint16_t)surface->cell_h,
            .wrapMode = (Clay_TextElementConfigWrapMode)node->wrap });
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
        .userData = node,
        .layout = { .sizing = sizes,
            .padding = node->padding, .childGap = node->gap,
            .childAlignment = { .y = node->align_y == 1 ? CLAY_ALIGN_Y_CENTER : (node->align_y == 2 ? CLAY_ALIGN_Y_BOTTOM : CLAY_ALIGN_Y_TOP) },
            .layoutDirection = node->kind == 1 ? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM },
        .backgroundColor = bg, .cornerRadius = CLAY_CORNER_RADIUS(node->radius),
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
        Clay_ElementId id = node_id(node, i);
        Clay_ScrollContainerData scroll = Clay_GetScrollContainerData(id);
        Clay_ElementData view = Clay_GetElementData(id);
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
    prune_scroll_containers(surface, nodes, count);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, scroll_y}, delta_time);
    Clay_RenderCommandArray commands = build_layout(surface, nodes, count, delta_time);
    // Resolve caret visibility using actual Clay bounds, not Lua character-budget math.
    // A second pass applies changed offsets before painting the same frame.
    if (!surface->failed && reveal_targets(nodes, count)) commands = build_layout(surface, nodes, count, 0);
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

Clay_ElementData hollow_clay_visible_bounds(HollowClay *surface, HollowClayNode *nodes, int count, int index) {
    if (index < 0 || index >= count) return (Clay_ElementData){0};
    Clay_ElementData result = hollow_clay_bounds(surface, nodes, index);
    if (!result.found) return result;
    intersect_bounds(&result.boundingBox, (Clay_BoundingBox){0, 0, surface->width, surface->height}, true, true);
    // Recover the target's ancestors from preorder child counts. Sibling clips
    // must not affect each other, and a framed panel is paint-clipped on both axes.
    int ancestors[33], remaining[33], depth = 0;
    for (int i = 0; i <= index; ++i) {
        while (depth > 0 && remaining[depth - 1] == 0) --depth;
        if (i == index) break;
        if (depth > 0) --remaining[depth - 1];
        if (nodes[i].children > 0) {
            if (depth >= 33) return (Clay_ElementData){0};
            ancestors[depth] = i;
            remaining[depth++] = nodes[i].children;
        }
    }
    for (int d = 0; d < depth; ++d) {
        int i = ancestors[d];
        bool panel = i == 0 && surface->frame.enabled;
        if (!panel && !nodes[i].scroll && !nodes[i].scroll_x) continue;
        Clay_ElementData parent = hollow_clay_bounds(surface, nodes, i);
        if (parent.found) intersect_bounds(&result.boundingBox, parent.boundingBox,
            panel || nodes[i].scroll_x, panel || nodes[i].scroll);
    }
    result.found = result.boundingBox.width > 0 && result.boundingBox.height > 0;
    return result;
}

int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y) {
    Clay_SetCurrentContext(surface->context);
    Clay_SetPointerState((Clay_Vector2){x, y}, false);
    for (int i = count - 1; i >= 0; --i) {
        if (!nodes[i].clickable || !Clay_PointerOver(node_id(&nodes[i], i))) continue;
        Clay_ElementData visible = hollow_clay_visible_bounds(surface, nodes, count, i);
        Clay_BoundingBox b = visible.boundingBox;
        if (visible.found && x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height) return i;
    }
    return -1;
}
