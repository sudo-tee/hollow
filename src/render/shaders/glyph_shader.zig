/// Glyph shader — gamma-correct grayscale text rendering.
///
/// Implements Ghostty's perceptual luminance-based alpha correction
/// (USE_LINEAR_CORRECTION) in both GLSL (Linux / OpenGL GLCORE) and HLSL
/// (Windows / D3D11).
///
/// Vertex layout (interleaved, stride = 20 bytes):
///   offset  0 — f32x2  position  (screen-space pixels, Y-down)
///   offset  8 — f32x2  texcoord  (normalised 0..1 atlas UVs)
///   offset 16 — u8x4   fg_rgba   (sRGB, non-premultiplied)
///   (bg_rgba passed as uniform for simplicity — one uniform per draw call)
///
/// Uniforms (vs_params, 80 bytes, std140):
///   float4x4 mvp        (orthographic projection, row-major)
///   float2   atlas_size (ATLAS_W, ATLAS_H — for UV → pixel conversion if needed)
///   uint     use_linear_correction  (0 = off, 1 = on)
///
/// The fragment shader:
///   1. Samples the grayscale atlas at the glyph pixel → float alpha a ∈ [0,1].
///   2. If use_linear_correction:
///      • Linearises fg and bg luminances (sRGB → linear).
///      • Blends in linear light: blend_l = linearise(unlinearise(fg_l)*a + unlinearise(bg_l)*(1−a))
///      • Remaps a so that a linear-light blend produces the same luminance as the
///        above perceptual blend.  This is the exact algorithm from Ghostty/Kitty.
///   3. Outputs premultiplied alpha: vec4(fg_rgb * a, a).
///
/// The result is composited onto the render-target (or swapchain) with the
/// standard premultiplied-alpha blend equation:
///   out = src + dst * (1 − src_a)
///
const builtin = @import("builtin");

// ─────────────────────────────────────────────────────────────────────────────
// GLSL — OpenGL GLCORE (Linux, version 330 core for broad compatibility)
// ─────────────────────────────────────────────────────────────────────────────

pub const glsl_vs: [:0]const u8 =
    \\#version 330 core
    \\
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec2 in_uv;
    \\layout(location = 2) in vec4 in_fg_rgba;
    \\
    \\out vec2 v_uv;
    \\out vec4 v_fg;
    \\
    \\layout(std140) uniform vs_params {
    \\    mat4  mvp;
    \\    vec2  atlas_size;
    \\    uint  use_linear_correction;
    \\    uint  _pad;
    \\};
    \\
    \\void main() {
    \\    gl_Position = mvp * vec4(in_pos, 0.0, 1.0);
    \\    v_uv = in_uv;
    \\    // Pass fg colour as-is (sRGB, straight alpha).
    \\    // All linearization is done in the fragment shader.
    \\    v_fg = in_fg_rgba;
    \\}
;

pub const glsl_fs: [:0]const u8 =
    \\#version 330 core
    \\
    \\in  vec2 v_uv;
    \\in  vec4 v_fg;   // sRGB, straight alpha
    \\
    \\out vec4 out_color;
    \\
    \\uniform sampler2D atlas;
    \\
    \\layout(std140) uniform fs_params {
    \\    vec4  bg_linear;            // linear-space background colour (premultiplied)
    \\    uint  use_linear_correction;
    \\    uint  _pad0;
    \\    uint  _pad1;
    \\    uint  _pad2;
    \\};
    \\
    \\// Rec.709 luminance from linear RGB.
    \\float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
    \\
    \\// IEC 61966-2-1 sRGB ↔ linear, scalars.
    \\float linearize(float v) {
    \\    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    \\}
    \\float unlinearize(float v) {
    \\    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
    \\}
    \\
    \\void main() {
    \\    // Coverage from atlas (FreeType grayscale, perceptually linear).
    \\    float a = texture(atlas, v_uv).r;
    \\    if (a == 0.0) discard;
    \\
    \\    // fg is sRGB straight-alpha from vertex.
    \\    vec3 fg_srgb = v_fg.rgb;
    \\
    \\    if (use_linear_correction != 0u) {
    \\        // Perceptual alpha remap (Ghostty USE_LINEAR_CORRECTION).
    \\        vec3 bg_lin  = (bg_linear.a > 0.0) ? bg_linear.rgb / bg_linear.a : vec3(0.0);
    \\        vec3 bg_srgb = vec3(unlinearize(bg_lin.r),
    \\                            unlinearize(bg_lin.g),
    \\                            unlinearize(bg_lin.b));
    \\        float fg_l = luminance(vec3(linearize(fg_srgb.r),
    \\                                    linearize(fg_srgb.g),
    \\                                    linearize(fg_srgb.b)));
    \\        float bg_l = luminance(vec3(linearize(bg_srgb.r),
    \\                                    linearize(bg_srgb.g),
    \\                                    linearize(bg_srgb.b)));
    \\        if (abs(fg_l - bg_l) > 0.001) {
    \\            float fg_l_srgb  = unlinearize(fg_l);
    \\            float bg_l_srgb  = unlinearize(bg_l);
    \\            float blend_srgb = fg_l_srgb * a + bg_l_srgb * (1.0 - a);
    \\            float blend_l    = linearize(blend_srgb);
    \\            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
    \\        }
    \\    }
    \\
    \\    // Output sRGB-premultiplied into the RGBA8 render target.
    \\    // The RT is plain RGBA8 (not RGBA8_SRGB), so the display pipeline
    \\    // treats stored values as sRGB — we must store sRGB, not linear.
    \\    out_color = vec4(fg_srgb * a, a);
    \\}
;

// ─────────────────────────────────────────────────────────────────────────────
// HLSL — Direct3D 11 (Windows)
// ─────────────────────────────────────────────────────────────────────────────

pub const hlsl_vs: [:0]const u8 =
    \\cbuffer vs_params : register(b0) {
    \\    float4x4 mvp;
    \\    float2 atlas_size;
    \\    uint   use_linear_correction;
    \\    uint   _pad;
    \\};
    \\
    \\struct VSIn {
    \\    float2 pos     : TEXCOORD0;
    \\    float2 uv      : TEXCOORD1;
    \\    float4 fg_rgba : TEXCOORD2;
    \\};
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv  : TEXCOORD0;
    \\    float4 fg  : TEXCOORD1;   // sRGB, straight alpha (NOT pre-linearized)
    \\};
    \\
    \\VSOut main(VSIn In) {
    \\    VSOut Out;
    \\    Out.pos = mul(mvp, float4(In.pos, 0.0f, 1.0f));
    \\    Out.uv  = In.uv;
    \\    // Pass fg colour as-is (sRGB, straight alpha).
    \\    // All linearization is done in the fragment shader.
    \\    Out.fg = In.fg_rgba;
    \\    return Out;
    \\}
;

pub const hlsl_fs: [:0]const u8 =
    \\Texture2D    atlas   : register(t0);
    \\SamplerState atlas_s : register(s0);
    \\
    \\cbuffer fs_params : register(b1) {
    \\    float4 bg_linear;             // linear-space background colour (premultiplied)
    \\    uint   use_linear_correction;
    \\    uint   _pad0;
    \\    uint   _pad1;
    \\    uint   _pad2;
    \\};
    \\
    \\struct PSIn {
    \\    float4 pos : SV_Position;
    \\    float2 uv  : TEXCOORD0;
    \\    float4 fg  : TEXCOORD1;   // sRGB, straight alpha (UBYTE4N normalized)
    \\};
    \\
    \\float luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }
    \\
    \\float linearize(float v) {
    \\    return (v <= 0.04045f) ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f);
    \\}
    \\float unlinearize(float v) {
    \\    return (v <= 0.0031308f) ? v * 12.92f : pow(v, 1.0f / 2.4f) * 1.055f - 0.055f;
    \\}
    \\
    \\float4 main(PSIn In) : SV_Target0 {
    \\    // Coverage from atlas (FreeType grayscale, 0..1).
    \\    float a = atlas.Sample(atlas_s, In.uv).r;
    \\    if (a == 0.0f) discard;
    \\
    \\    // fg is sRGB straight-alpha from vertex (UBYTE4N normalised 0..1).
    \\    float3 fg_srgb = In.fg.rgb;
    \\
    \\    if (use_linear_correction != 0u) {
    \\        // Ghostty-style perceptual alpha remap.
    \\        // Simulate blending in sRGB space (perceptual), then solve for the
    \\        // alpha that achieves the same luminance in linear-light blending.
    \\        float3 bg_lin  = (bg_linear.a > 0.0f) ? bg_linear.rgb / bg_linear.a
    \\                                               : float3(0.0f, 0.0f, 0.0f);
    \\        float3 bg_srgb = float3(unlinearize(bg_lin.r),
    \\                                unlinearize(bg_lin.g),
    \\                                unlinearize(bg_lin.b));
    \\        float fg_l = luminance(float3(linearize(fg_srgb.r),
    \\                                      linearize(fg_srgb.g),
    \\                                      linearize(fg_srgb.b)));
    \\        float bg_l = luminance(float3(linearize(bg_srgb.r),
    \\                                      linearize(bg_srgb.g),
    \\                                      linearize(bg_srgb.b)));
    \\        if (abs(fg_l - bg_l) > 0.001f) {
    \\            float blend_srgb = unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0f - a);
    \\            float blend_l    = linearize(blend_srgb);
    \\            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0f, 1.0f);
    \\        }
    \\    }
    \\
    \\    // Output sRGB-premultiplied into the RGBA8 render target.
    \\    // The RT is plain RGBA8 (not RGBA8_SRGB), so the display pipeline
    \\    // treats stored values as sRGB — we must store sRGB, not linear.
    \\    return float4(fg_srgb * a, a);
    \\}
;

/// Select the correct vertex/fragment source strings for the current backend.
/// Returns .{ vs, fs } where both are null-terminated.
pub const Backend = enum { glsl, hlsl };

pub fn backendSources(backend: Backend) struct { vs: [:0]const u8, fs: [:0]const u8 } {
    return switch (backend) {
        .glsl => .{ .vs = glsl_vs, .fs = glsl_fs },
        .hlsl => .{ .vs = hlsl_vs, .fs = hlsl_fs },
    };
}

/// Comptime-select based on the build target OS.
pub const native_backend: Backend = if (builtin.target.os.tag == .windows) .hlsl else .glsl;
