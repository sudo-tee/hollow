// Slow aurora bands over the terminal background colour.
// Use as `background.shader`; it animates on its own.
const float speed = 0.05;
const float strength = 0.18;

float wave(vec2 uv, float offset) {
    float y = 0.5 + 0.18 * sin(uv.x * 3.0 + iTime * speed * 6.0 + offset)
                  + 0.08 * sin(uv.x * 7.0 - iTime * speed * 4.0 + offset * 2.0);
    return exp(-abs(uv.y - y) * 9.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 col = iBackgroundColor;
    col += strength * wave(uv, 0.0) * vec3(0.20, 0.85, 0.60);
    col += strength * wave(uv, 2.1) * vec3(0.35, 0.40, 0.95);
    col += strength * 0.6 * wave(uv, 4.3) * vec3(0.80, 0.30, 0.70);
    fragColor = vec4(col, 1.0);
}
