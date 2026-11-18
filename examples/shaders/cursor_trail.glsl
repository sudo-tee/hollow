// Fading trail between the previous and current cursor positions, plus a
// soft glow around the cursor while the window is focused.
// Works with the default shader_animation = "cursor".
vec2 cursorCenter(vec4 r) {
    return r.xy + r.zw * vec2(0.5, -0.5);
}

float rectSdf(vec2 p, vec4 r) {
    vec2 c = cursorCenter(r);
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
    fragColor = base;
    if (iFocus == 0 || iCursorVisible == 0) return;
    float t = clamp((iTime - iTimeCursorChange) / max(iCursorTrailDecay, 0.001), 0.0, 1.0);
    vec2 cur = cursorCenter(iCurrentCursor);
    vec2 prev = cursorCenter(iPreviousCursor);
    vec2 tail = mix(prev, cur, t);
    float width = iCurrentCursor.w * 0.35;
    float d = segmentSdf(fragCoord, tail, cur) - width;
    float trail = 0.0;
    if (iCursorTrailDecay > 0.0 && iPreviousCursor.z > 0.0 &&
        distance(prev, cur) > 0.0 && distance(prev, cur) >= iCursorTrailMinDistance)
        trail = (1.0 - smoothstep(0.0, 2.0, d)) * (1.0 - t);
    float glow = (1.0 - smoothstep(0.0, 6.0, rectSdf(fragCoord, iCurrentCursor))) * 0.25;
    vec3 col = mix(base.rgb, iCurrentCursorColor.rgb, glow);
    col = mix(col, iCursorTrailColor, trail * 0.8);
    fragColor = vec4(col, base.a);
}
