#ifndef HOLLOW_CLAY_BRIDGE_H
#define HOLLOW_CLAY_BRIDGE_H
#include "../../third_party/clay/clay.h"

#define HOLLOW_CLAY_MAX_NODES 512

// A bounded preorder tree. Width/height: -1 = grow, 0 = fit, positive = pixels.
typedef struct HollowClayNode {
    Clay_String id, text, label, reveal;
    Clay_String scrollbar_id;
    Clay_ElementId element_id; // Filled by hollow_clay_layout; callers need not set it.
    int children;
    int kind; // 0 column, 1 row, 2 text, 3 custom progress
    float width, height;
    Clay_Padding padding;
    uint16_t gap;
    Clay_Color fg, bg, border, hover_bg;
    Clay_Color scrollbar_track_color, scrollbar_thumb_color;
    float scrollbar_thumb_ratio, scrollbar_thumb_size;
    float radius;
    uint16_t border_size;
    bool bold, scroll, scroll_x, clickable, reveal_start, list_item, measure, full_bleed_x;
    int wrap; // Clay text wrapping: 0 words, 1 newlines, 2 none.
    int align_y; // Child alignment: 0 start, 1 center, 2 end.
    float value;
} HollowClayNode;

typedef struct HollowClayFrame {
    bool enabled;
    float width, height; // Pixels; zero fits content.
    Clay_Padding margin;
    int align_x, align_y; // 0 start, 1 center, 2 end.
} HollowClayFrame;

typedef struct HollowClay HollowClay;
HollowClay *hollow_clay_create(void);
void hollow_clay_destroy(HollowClay *surface);
// Lays out at most HOLLOW_CLAY_MAX_NODES nodes. Bounds, visible bounds and hit
// testing below report the geometry of the most recent layout call.
Clay_RenderCommandArray hollow_clay_layout(HollowClay *surface,
    HollowClayNode *nodes, int count, float width, float height,
    float cell_w, float cell_h, float mouse_x, float mouse_y,
    float scroll_y, float delta_time);
bool hollow_clay_failed(HollowClay *surface);
// First Clay error reported by the latest layout; empty when none.
Clay_String hollow_clay_error(HollowClay *surface);
int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y);
void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame);
Clay_ElementData hollow_clay_bounds(HollowClay *surface, HollowClayNode *nodes, int index);
Clay_ElementData hollow_clay_visible_bounds(HollowClay *surface, HollowClayNode *nodes, int count, int index);
#endif
