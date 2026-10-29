#ifndef HOLLOW_CLAY_BRIDGE_H
#define HOLLOW_CLAY_BRIDGE_H
#include "../../third_party/clay/clay.h"

// A bounded preorder tree. Width/height: -1 = grow, 0 = fit, positive = pixels.
typedef struct HollowClayNode {
    Clay_String id, text, label;
    int children;
    int kind; // 0 column, 1 row, 2 text, 3 custom progress
    float width, height;
    Clay_Padding padding;
    uint16_t gap;
    Clay_Color fg, bg, border, hover_bg;
    float radius;
    uint16_t border_size;
    bool bold, scroll, clickable;
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
Clay_RenderCommandArray hollow_clay_layout(HollowClay *surface,
    HollowClayNode *nodes, int count, float width, float height,
    float cell_w, float cell_h, float mouse_x, float mouse_y,
    float scroll_y, float delta_time);
bool hollow_clay_failed(HollowClay *surface);
int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y);
void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame);
Clay_ElementData hollow_clay_bounds(HollowClay *surface, HollowClayNode *nodes, int index);
#endif
