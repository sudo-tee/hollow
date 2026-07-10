#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_log.h"
#include "sokol_glue.h"
#include "util/sokol_gl.h"
#include "util/sokol_debugtext.h"
#include "fontstash.h"
#include "util/sokol_fontstash.h"

void hollow_linux_set_window_decorated(bool decorated);
void hollow_linux_begin_window_drag(void);
bool hollow_linux_begin_window_resize(int direction);
void hollow_linux_update_window_resize(void);
void hollow_linux_end_window_resize(void);
