#version 440
// The Halcyon sky's soft light (LiveSky.qml): the theme background, the accent glow around the middle and the darker corners,
// worked out in full precision on the GPU and dithered (about one colour step of noise), so the faint gradients have no bands.
// The same shader paints the mark's halo (no background, no corners). The still stars come in as `stars` and go on top.
// Compiled to sky.frag.qsb by shell.qml (`qsb --qt6`), only when it is missing or older than this file.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 bg;         // opaque colours (alpha is given apart, so premultiplying cannot touch them)
    vec4 c1;
    vec4 c2;
    float bgA;       // 0 = no background (the halo)
    float a0;        // the glow: c1 at a0 in the middle, c2 at aMid at `mid`, c2 at 0 at the edge
    float aMid;
    float mid;
    vec2 center;     // in pixels inside the item
    float radius;
    float vigIn;     // the corners: from vigIn to vigOut (pixels from the centre) they go to black at vigA
    float vigOut;
    float vigA;
    float useStars;  // 1 = put `stars` on top
    vec2 dim;        // item size in pixels
};
layout(binding = 1) uniform sampler2D stars;

// premultiplied source-over
vec4 over(vec4 s, vec4 d) { return s + d * (1.0 - s.a); }

// two unrelated noises per pixel: interleaved gradient noise and the classic sine hash
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
float sh(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void main() {
    vec2 pos = qt_TexCoord0 * dim;
    vec4 col = vec4(bg.rgb * bgA, bgA);

    // the glow, interpolated like a canvas gradient (straight colours), then laid over
    float t = clamp(length(pos - center) / max(radius, 1.0), 0.0, 1.0);
    vec4 g = t < mid ? mix(vec4(c1.rgb, a0), vec4(c2.rgb, aMid), t / max(mid, 1.0e-4))
                     : mix(vec4(c2.rgb, aMid), vec4(c2.rgb, 0.0), (t - mid) / max(1.0 - mid, 1.0e-4));
    col = over(vec4(g.rgb * g.a, g.a), col);

    // the corners: a smooth curve rather than a straight ramp, so its start leaves no visible ring
    float v = smoothstep(vigIn, vigOut, length(pos - center)) * vigA;
    col = over(vec4(0.0, 0.0, 0.0, v), col);

    if (useStars > 0.5) col = over(texture(stars, qt_TexCoord0), col);

    // triangular noise of about one 8-bit step (two hashes of the pixel), so neighbouring pixels round to different
    // steps and the bands melt into an even grain too fine to see
    vec2 px = floor(pos);
    float n = (ign(px) + sh(px) - 1.0) / 255.0;
    if (bgA > 0.5) {
        col.rgb += n;
    } else if (col.a > 0.002) {
        // the halo is see-through: its alpha bands too, so the noise goes on all four (premultiplied: colour never above alpha)
        col += vec4(n);
        col.a = clamp(col.a, 0.0, 1.0);
        col.rgb = clamp(col.rgb, 0.0, col.a);
    }
    fragColor = clamp(col, 0.0, 1.0) * qt_Opacity;
}
