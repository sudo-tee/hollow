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
    // Pixel constraints for FIT/GROW. Zero maximum is unbounded; FIXED wins.
    float min_width, max_width, min_height, max_height;
    Clay_Padding padding;
    uint16_t gap;
    Clay_Color fg, bg, border, hover_bg;
    Clay_Color scrollbar_track_color, scrollbar_thumb_color;
    float scrollbar_thumb_ratio, scrollbar_thumb_size;
    float radius;
    uint16_t border_size;
    // When set, replaces border_size entirely (including explicit zero sides).
    Clay_BorderWidth border_width;
    bool border_width_set;
    bool bold, scroll, scroll_x, clickable, reveal_start, list_item, measure, full_bleed_x;
    int wrap; // Clay text wrapping: 0 words, 1 newlines, 2 none.
    int text_align; // Wrapped line alignment: 0 left, 1 center, 2 right.
    int align_y; // Child alignment: 0 start, 1 center, 2 end.
    float value;
} HollowClayNode;

typedef struct HollowClayFrame {
    bool enabled;
    float width, height; // Pixels; zero fits content.
    float max_height; // Pixels; zero unbounded. Caps FIT and explicit frame height.
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
// Updates Clay's pointer position against the latest successful layout and
// returns its last-painted clickable node, or -1. Clay clips/capture apply;
// visible_bounds remains a separate paint/accessibility geometry query.
// Like Clay_SetPointerState, this runs hover callbacks and advances button state.
// Restores the previously current Clay context before returning.
int hollow_clay_hit(HollowClay *surface, HollowClayNode *nodes, int count, float x, float y);
void hollow_clay_frame(HollowClay *surface, HollowClayFrame frame);
void hollow_clay_set_debug(HollowClay *surface, bool enabled);
// Primary button state for the inspector; ignored while debug is off.
void hollow_clay_set_pointer_down(HollowClay *surface, bool down);
Clay_ElementData hollow_clay_bounds(HollowClay *surface, HollowClayNode *nodes, int index);
Clay_ElementData hollow_clay_visible_bounds(HollowClay *surface, HollowClayNode *nodes, int count, int index);

// Externally laid-out geometry mirrored into Clay so its inspector can show it.
// A bounded preorder tree in window pixels. Children that tile their parent
// along one axis become a Clay row/column (gaps become "gap" spacers); others,
// and those marked floating, are attached to their parent at their offset.
//
// Style fields only feed the inspector's element info. A row/column takes its
// left/top padding from where its first child starts and right/bottom from
// `padding`; other rects use `padding` as given.
typedef struct HollowClayDebugRect {
    Clay_String id;     // Inspector label; combined with `index` for the element id.
    uint32_t index;
    Clay_String detail; // Leaf-only, shown as an unpainted text child.
    int children;
    bool floating;
    float x, y, width, height;
    Clay_Color background;   // Alpha 0: none.
    Clay_Color border_color; // Drawn with `border_width` on every side.
    uint16_t border_width;
    float corner_radius;
    Clay_Padding padding;
    Clay_Color text_color;   // Detail text.
    uint16_t font_id;        // Detail text; 1 is bold.
} HollowClayDebugRect;

// Lays out `rects` with Clay's inspector open. Returns commands for the
// inspector panel and its highlight only; mirrored rects are never painted.
Clay_RenderCommandArray hollow_clay_debug_layout(HollowClay *surface,
    HollowClayDebugRect *rects, int count, float width, float height,
    float cell_w, float cell_h, float mouse_x, float mouse_y, bool mouse_down,
    float scroll_y, float delta_time);
// True when the inspector's close button was pressed during the last layout
// (hollow_clay_layout or hollow_clay_debug_layout).
bool hollow_clay_debug_closed(HollowClay *surface);
#endif
