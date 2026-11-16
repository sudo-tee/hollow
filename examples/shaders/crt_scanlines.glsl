// Subtle CRT look: horizontal scanlines and a slight RGB fringe.
// Static, so it needs no shader_animation.
const float scanline_period = 3.0; // pixels
const float scanline_strength = 0.08;
const float fringe = 0.6; // pixels

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 px = 1.0 / iResolution.xy;
    vec2 uv = fragCoord * px;
    vec4 base = texture(iChannel0, uv);
    vec3 col = vec3(
        texture(iChannel0, uv + vec2(fringe * px.x, 0.0)).r,
        base.g,
        texture(iChannel0, uv - vec2(fringe * px.x, 0.0)).b
    );
    float wave = 0.5 + 0.5 * cos(6.2831853 * fragCoord.y / scanline_period);
    // Boost the bright part of the line so the average brightness is kept.
    col *= 1.0 - scanline_strength * wave + scanline_strength * 0.5;
    fragColor = vec4(col, base.a);
}
