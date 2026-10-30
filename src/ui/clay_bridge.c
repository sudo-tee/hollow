#define CLAY_IMPLEMENTATION
#include "clay_bridge.h"
#include <stdlib.h>

struct HollowClay {
    Clay_Context *context;
    void *memory;
    int32_t elements;
    float cell_w, cell_h;
    bool failed, debug, debug_closed, pointer_down;
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

// Plain layouts stay small; Clay's inspector adds several elements per
// inspected element, so the context is rebuilt larger the first time it opens.
#define HOLLOW_CLAY_ELEMENTS 2048
#define HOLLOW_CLAY_DEBUG_ELEMENTS 16384

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
    surface->elements = elements;
    surface->context = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
        (Clay_Dimensions){1, 1}, (Clay_ErrorHandler){on_error, surface});
    Clay_SetMeasureTextFunction(measure, surface);
    Clay_SetCurrentContext(previous);
    return true;
}

// False when the larger inspector context cannot be allocated.
static bool ensure_debug_capacity(HollowClay *surface) {
    return surface->elements >= HOLLOW_CLAY_DEBUG_ELEMENTS || init_context(surface, HOLLOW_CLAY_DEBUG_ELEMENTS);
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
    if (surface->debug && !ensure_debug_capacity(surface)) surface->debug = false;
    Clay_SetCurrentContext(surface->context);
    hash_ids(nodes, count);
    Clay_SetDebugModeEnabled(surface->debug);
    Clay_SetLayoutDimensions((Clay_Dimensions){width, height});
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, surface->debug && surface->pointer_down);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, scroll_y}, delta_time);
    Clay_RenderCommandArray commands = build_layout(surface, nodes, count, delta_time);
    // Resolve caret visibility using actual Clay bounds, not Lua character-budget math.
    // A second pass applies changed offsets before painting the same frame.
    if (!surface->failed && reveal_targets(nodes, count)) commands = build_layout(surface, nodes, count, 0);
    // Refresh overlaps against this layout, not last frame's geometry.
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, surface->debug && surface->pointer_down);
    // The inspector's close button is a hover handler run by Clay_SetPointerState
    // with the previous press state, so it can only be observed here.
    surface->debug_closed = surface->debug && !Clay_IsDebugModeEnabled();
    if (surface->debug_closed) surface->debug = false;
    if (!surface->failed) record_bounds(surface, nodes, count);
    return commands;
}

bool hollow_clay_failed(HollowClay *surface) { return surface->failed; }

Clay_String hollow_clay_error(HollowClay *surface) { return surface->error; }

void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame) { surface->frame = frame; }

void hollow_clay_set_debug(HollowClay *surface, bool enabled) { surface->debug = enabled; }

void hollow_clay_set_pointer_down(HollowClay *surface, bool down) { surface->pointer_down = down; }

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

#define HOLLOW_CLAY_DEBUG_DEPTH 32
#define HOLLOW_CLAY_DEBUG_EPSILON 0.5f

static bool debug_near(float a, float b) { return a - b < HOLLOW_CLAY_DEBUG_EPSILON && b - a < HOLLOW_CLAY_DEBUG_EPSILON; }

// Exclusive preorder subtree ends; false for malformed child counts or depth.
static bool debug_subtree_ends(const HollowClayDebugRect *rects, int count, int *ends) {
    int stack[HOLLOW_CLAY_DEBUG_DEPTH + 1], remaining[HOLLOW_CLAY_DEBUG_DEPTH + 1], depth = 0;
    for (int i = 0; i < count; ++i) {
        while (depth > 0 && remaining[depth - 1] == 0) ends[stack[--depth]] = i;
        if (i > 0 && depth == 0) return false; // A single root is required.
        if (depth > 0) --remaining[depth - 1];
        if (rects[i].children < 0) return false;
        if (rects[i].children == 0) { ends[i] = i + 1; continue; }
        if (depth > HOLLOW_CLAY_DEBUG_DEPTH) return false;
        stack[depth] = i;
        remaining[depth++] = rects[i].children;
    }
    while (depth > 0) {
        if (remaining[depth - 1] != 0) return false;
        ends[stack[--depth]] = count;
    }
    return true;
}

// 1 row, 2 column, 0 when the in-flow children do not tile along one axis.
static int debug_axis(const HollowClayDebugRect *rects, const int *ends, int parent) {
    const HollowClayDebugRect *p = &rects[parent];
    int axes = 3, flow = 0;
    float row_cursor = p->x, column_cursor = p->y;
    const HollowClayDebugRect *first = NULL;
    for (int i = parent + 1; i < ends[parent]; i = ends[i]) {
        const HollowClayDebugRect *child = &rects[i];
        if (child->floating) continue;
        if (!first) first = child;
        ++flow;
        if (!debug_near(child->y, first->y) || !debug_near(child->height, first->height) || child->x < row_cursor - HOLLOW_CLAY_DEBUG_EPSILON) axes &= ~1;
        if (!debug_near(child->x, first->x) || !debug_near(child->width, first->width) || child->y < column_cursor - HOLLOW_CLAY_DEBUG_EPSILON) axes &= ~2;
        row_cursor = child->x + child->width;
        column_cursor = child->y + child->height;
    }
    if (flow == 0) return 2;
    // Children must also start inside the parent; padding cannot be negative.
    if (first->y < p->y - HOLLOW_CLAY_DEBUG_EPSILON) axes &= ~1;
    if (first->x < p->x - HOLLOW_CLAY_DEBUG_EPSILON) axes &= ~2;
    return (axes & 1) ? 1 : ((axes & 2) ? 2 : 0);
}

// Tags mirrored elements so their render commands can be dropped; only the
// inspector panel and its highlight are painted.
static char debug_mirror_tag;

static Clay_ElementId debug_id(const HollowClayDebugRect *rect) {
    return rect->id.length ? Clay_GetElementIdWithIndex(rect->id, rect->index) : CLAY_IDI("hollow.debug", rect->index);
}

static void declare_debug_rect(HollowClayDebugRect *rects, const int *ends, int index, Clay_FloatingElementConfig floating, HollowClay *surface) {
    HollowClayDebugRect *rect = &rects[index];
    int axis = debug_axis(rects, ends, index);
    Clay_Padding padding = rect->padding;
    float cursor = axis == 1 ? rect->x : rect->y;
    if (axis) {
        for (int i = index + 1; i < ends[index]; i = ends[i]) {
            if (rects[i].floating) continue;
            padding.left = (uint16_t)(rects[i].x - rect->x + 0.5f);
            padding.top = (uint16_t)(rects[i].y - rect->y + 0.5f);
            cursor = axis == 1 ? rects[i].x : rects[i].y;
            break;
        }
    }
    uint16_t border = rect->border_width;
    CLAY(debug_id(rect), {
        .layout = { .sizing = { CLAY_SIZING_FIXED(rect->width), CLAY_SIZING_FIXED(rect->height) },
            .padding = padding,
            .layoutDirection = axis == 1 ? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM },
        .backgroundColor = rect->background,
        .cornerRadius = CLAY_CORNER_RADIUS(rect->corner_radius),
        .border = { .color = rect->border_color, .width = { border, border, border, border, 0 } },
        .floating = floating,
        .userData = &debug_mirror_tag,
    }) {
        if (rect->children == 0 && rect->detail.length) {
            CLAY_TEXT(rect->detail, { .textColor = rect->text_color, .fontId = rect->font_id,
                .fontSize = (uint16_t)surface->cell_h, .lineHeight = (uint16_t)surface->cell_h,
                .wrapMode = CLAY_TEXT_WRAP_NONE, .userData = &debug_mirror_tag });
        }
        for (int i = index + 1; i < ends[index]; i = ends[i]) {
            HollowClayDebugRect *child = &rects[i];
            if (child->floating || !axis) continue;
            float start = axis == 1 ? child->x : child->y;
            if (start - cursor >= HOLLOW_CLAY_DEBUG_EPSILON) {
                float gap = start - cursor;
                CLAY(CLAY_IDI("gap", (uint32_t)i), { .layout = { .sizing = {
                    axis == 1 ? CLAY_SIZING_FIXED(gap) : CLAY_SIZING_FIXED(0),
                    axis == 1 ? CLAY_SIZING_FIXED(0) : CLAY_SIZING_FIXED(gap) } } }) {}
            }
            declare_debug_rect(rects, ends, i, (Clay_FloatingElementConfig){0}, surface);
            cursor = start + (axis == 1 ? child->width : child->height);
        }
        for (int i = index + 1; i < ends[index]; i = ends[i]) {
            HollowClayDebugRect *child = &rects[i];
            if (!child->floating && axis) continue;
            declare_debug_rect(rects, ends, i, (Clay_FloatingElementConfig){
                .offset = { child->x - rect->x, child->y - rect->y },
                .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
                .attachTo = CLAY_ATTACH_TO_PARENT,
            }, surface);
        }
    }
}

Clay_RenderCommandArray hollow_clay_debug_layout(HollowClay *surface, HollowClayDebugRect *rects, int count,
    float width, float height, float cell_w, float cell_h, float mouse_x, float mouse_y, bool mouse_down,
    float scroll_y, float delta_time) {
    static int ends[HOLLOW_CLAY_MAX_NODES];
    Clay_SetCurrentContext(surface->context);
    surface->failed = false;
    surface->error = (Clay_String){0};
    surface->debug_closed = false;
    if (count <= 0 || count > HOLLOW_CLAY_MAX_NODES || !debug_subtree_ends(rects, count, ends)) {
        surface->failed = true;
        surface->error = CLAY_STRING("Invalid debug geometry tree.");
        return (Clay_RenderCommandArray){0};
    }
    if (!ensure_debug_capacity(surface)) {
        surface->failed = true;
        surface->error = CLAY_STRING("Out of memory for the Clay inspector.");
        return (Clay_RenderCommandArray){0};
    }
    Clay_SetCurrentContext(surface->context);
    if (surface->cell_w != cell_w || surface->cell_h != cell_h) Clay_ResetMeasureTextCache();
    surface->cell_w = cell_w;
    surface->cell_h = cell_h;
    surface->width = width;
    surface->height = height;
    Clay_SetDebugModeEnabled(true);
    Clay_SetLayoutDimensions((Clay_Dimensions){width, height});
    Clay_SetPointerState((Clay_Vector2){mouse_x, mouse_y}, mouse_down);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, scroll_y}, delta_time);
    Clay_BeginLayout();
    Clay_FloatingElementConfig root = {0};
    if (rects[0].x != 0 || rects[0].y != 0)
        root = (Clay_FloatingElementConfig){ .offset = { rects[0].x, rects[0].y },
            .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH, .attachTo = CLAY_ATTACH_TO_ROOT };
    declare_debug_rect(rects, ends, 0, root, surface);
    Clay_RenderCommandArray commands = Clay_EndLayout(delta_time);
    int32_t kept = 0;
    for (int32_t i = 0; i < commands.length; ++i) {
        if (commands.internalArray[i].userData == &debug_mirror_tag) continue;
        commands.internalArray[kept++] = commands.internalArray[i];
    }
    commands.length = kept;
    surface->debug_closed = !Clay_IsDebugModeEnabled();
    return commands;
}

bool hollow_clay_debug_closed(HollowClay *surface) { return surface->debug_closed; }
