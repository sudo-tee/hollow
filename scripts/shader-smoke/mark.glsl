void mainImage(out vec4 color, in vec2 pixel) {
    vec2 uv = pixel / iResolution.xy;
    color = texture(iChannel0, uv);
    float y = uv.y;
#if HOLLOW_Y_DOWN
    y = 1.0 - y;
#endif
    if (uv.x < 0.04 && y > 0.5)
        color.rgb = vec3(color.a, 0.0, 0.0);
}
