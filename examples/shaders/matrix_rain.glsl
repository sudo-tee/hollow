// Matrix-style digital rain. Use as `background.shader`.
const float cell_size = 16.0; // glyph cell, pixels
const float speed = 7.0;      // cells per second
const float trail = 22.0;     // trail length, cells
const float strength = 0.55;  // brightness over the background colour
const vec3 rain_color = vec3(0.15, 1.0, 0.35);
const vec3 head_color = vec3(0.8, 1.0, 0.85);

#ifndef HOLLOW_Y_DOWN
#define HOLLOW_Y_DOWN 0
#endif

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Random 3x5 dot glyph that changes shape now and then.
float glyph(vec2 cell, vec2 f) {
    vec2 inner = (f - 0.15) / 0.7;
    if (any(lessThan(inner, vec2(0.0))) || any(greaterThan(inner, vec2(1.0)))) return 0.0;
    float shape = floor(iTime * (0.3 + 2.0 * hash(cell + 3.1)));
    vec2 bit = floor(inner * vec2(3.0, 5.0));
    return step(0.45, hash(cell * 1.7 + bit * 13.3 + shape));
}

// Brightness of one falling drop at row `y`; 1 at the head, fading behind.
float drop(float column, float y, float seed) {
    float rows = iResolution.y / cell_size;
    float period = rows + trail * 2.0;
    float rate = speed * (0.5 + hash(vec2(column, seed)));
    float head = floor(mod(iTime * rate + hash(vec2(seed, column)) * period, period));
    float behind = head - y;
    return behind < 0.0 || behind >= trail ? 0.0 : 1.0 - behind / trail;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 p = fragCoord;
#if HOLLOW_Y_DOWN == 0
    p.y = iResolution.y - p.y; // rows count down from the top
#endif
    vec2 cell = floor(p / cell_size);
    vec2 f = fract(p / cell_size);

    float lit = max(drop(cell.x, cell.y, 1.0), drop(cell.x, cell.y, 2.0));
    vec3 col = rain_color * lit * lit;
    col = mix(col, head_color, step(0.999, lit));
    fragColor = vec4(iBackgroundColor + col * glyph(cell, f) * strength, 1.0);
}
