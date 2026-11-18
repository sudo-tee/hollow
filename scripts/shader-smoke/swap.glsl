void mainImage(out vec4 color, in vec2 pixel) {
    color = texture(iChannel0, pixel / iResolution.xy).bgra;
}
