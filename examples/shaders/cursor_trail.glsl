// Fading trail between the previous and current cursor positions, plus a
// soft glow around the cursor while the window is focused.
// Works with the default shader_animation = "cursor".
float rectSdf(vec2 p, vec4 r) {
    vec2 c = vec2(r.x + r.z * 0.5, r.y - r.w * 0.5);
    vec2 d = abs(p - c) - r.zw * 0.5;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float segmentSdf(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 base = texture(iChannel0, uv);
    float t = clamp((iTime - iTimeCursorChange) / 0.3, 0.0, 1.0);
    vec2 cur = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5, iCurrentCursor.y - iCurrentCursor.w * 0.5);
    vec2 prev = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5, iPreviousCursor.y - iPreviousCursor.w * 0.5);
    vec2 tail = mix(prev, cur, t);
    float width = iCurrentCursor.w * 0.35;
    float d = segmentSdf(fragCoord, tail, cur) - width;
    float trail = (1.0 - smoothstep(0.0, 2.0, d)) * (1.0 - t);
    float glow = (1.0 - smoothstep(0.0, 6.0, rectSdf(fragCoord, iCurrentCursor))) * 0.25;
    vec3 col = mix(base.rgb, iCurrentCursorColor.rgb, max(trail * 0.8, glow * float(iFocus)));
    fragColor = vec4(col, base.a);
}
