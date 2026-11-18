void mainImage(out vec4 color, in vec2 pixel) {
    float y = pixel.y / iResolution.y;
#if HOLLOW_Y_DOWN
    y = 1.0 - y;
#endif
    color = vec4(y > 0.5 ? vec3(0.7, 0.0, 0.0) : vec3(0.0, 0.0, 0.4), 1.0);
}
