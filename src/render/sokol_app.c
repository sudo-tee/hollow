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
