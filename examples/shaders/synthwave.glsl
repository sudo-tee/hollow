// Synthwave sunset: striped sun, glowing horizon and a scrolling grid.
// Use as `background.shader`.
const float horizon = 0.38;   // horizon height, 0..1 from the bottom
const float grid_speed = 0.6; // grid lines per second
const float strength = 0.45;  // mix with the background colour

#ifndef HOLLOW_Y_DOWN
#define HOLLOW_Y_DOWN 0
#endif

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
#if HOLLOW_Y_DOWN
    uv.y = 1.0 - uv.y; // y grows upwards
#endif
    float aspect = iResolution.x / iResolution.y;
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - horizon);
    float sky_mask = step(0.0, p.y);

    // Sky fades from magenta at the horizon to deep purple.
    vec3 sky = mix(vec3(0.85, 0.25, 0.55), vec3(0.07, 0.02, 0.16), smoothstep(0.0, 0.55, p.y));

    // Sun with gaps that widen towards its bottom edge.
    float r = 0.22;
    vec2 sc = p - vec2(0.0, 0.15);
    float d = length(sc);
    vec3 sun_color = mix(vec3(1.0, 0.2, 0.5), vec3(1.0, 0.85, 0.3), clamp(sc.y / r * 0.5 + 0.5, 0.0, 1.0));
    float gap = step(0.0, -sc.y) * step(fract(-sc.y * 22.0), -sc.y / r * 0.7);
    float sun = (1.0 - smoothstep(r - 0.003, r, d)) * (1.0 - gap);
    sky = mix(sky, sun_color, sun);
    sky += vec3(1.0, 0.3, 0.6) * 0.25 * exp(-max(d - r, 0.0) * 10.0) * (1.0 - sun);

    // Perspective grid scrolling towards the viewer.
    float depth = 1.0 / max(-p.y, 0.003);
    vec2 g = vec2(p.x * depth * 2.5, depth + iTime * grid_speed);
    vec2 dist = abs(fract(g - 0.5) - 0.5) / max(fwidth(g), vec2(1e-4));
    float line = 1.0 - clamp(min(dist.x, dist.y) - 0.5, 0.0, 1.0);
    float fade = smoothstep(0.0, 0.12, -p.y);
    vec3 ground = mix(vec3(0.04, 0.0, 0.09), vec3(0.95, 0.25, 0.95), line * fade);

    vec3 col = mix(ground, sky, sky_mask);
    col += vec3(1.0, 0.35, 0.75) * 0.6 * exp(-abs(p.y) * 45.0);
    fragColor = vec4(mix(iBackgroundColor, col, strength), 1.0);
}
