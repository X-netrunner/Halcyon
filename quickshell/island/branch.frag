#version 440
// One tree-view branch (cubic bezier, anti-aliased) drawn entirely on the GPU: no path tessellation on the CPU.
// Compiled to branch.frag.qsb by shell.qml (`qsb --qt6`), only when it is missing or older than this file.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 color;      // premultiplied by Qt
    vec2 p0;         // control points, in pixels inside the item
    vec2 p1;
    vec2 p2;
    vec2 p3;
    vec2 dim;        // item size in pixels
    float lw;        // line width in pixels
};

void main() {
    vec2 pos = qt_TexCoord0 * dim;
    float best = 1.0e9;
    vec2 prev = p0;
    for (int i = 1; i <= 24; i++) {
        float t = float(i) / 24.0;
        float u = 1.0 - t;
        vec2 cur = u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
        vec2 ab = cur - prev;
        vec2 ap = pos - prev;
        float h = clamp(dot(ap, ab) / max(dot(ab, ab), 1.0e-6), 0.0, 1.0);
        best = min(best, length(ap - ab * h));
        prev = cur;
    }
    float half_w = lw * 0.5;
    float cov = 1.0 - smoothstep(half_w - 0.6, half_w + 0.6, best);
    fragColor = color * (cov * qt_Opacity);
}
