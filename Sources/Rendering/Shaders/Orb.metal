// Orb.metal — reference MSL for the pet Orb fragment shader.
//
// NOTE: this file is NOT compiled by the Swift Package — the project's
// existing pattern (see PileCompositeShaderSource / MetalSnowRenderPipeline)
// keeps all MSL inline as Swift `static let` strings so a single source-of-
// truth lives in Sources/Rendering/OrbShaderSource.swift. This .metal copy
// exists purely for IDE syntax highlighting and quick visual review.
//
// If you edit this file, MUST also update OrbShaderSource.source — they are
// kept byte-identical (modulo this header).
//
// Pipeline summary:
//   - Vertex stage: 3-vertex fullscreen triangle, no vertex buffer.
//   - Fragment stage: SDF circle + Fresnel rim + two layers of cosine
//     flow + squash-along-Y deformation + HSV→RGB tint.
//   - Output: premultiplied straight alpha, 4 corners are alpha=0
//     (transparent so the orb is a circle on an otherwise empty pet window).
//
// Budget: ≤ 0.3 ms / frame at 64 px viewport on Apple Silicon.

#include <metal_stdlib>
using namespace metal;

struct OrbUniforms {
    float colorHue;
    float flowSpeed;
    float vortexIntensity;
    float squashY;
    float time;
    float aspectRatio;
    float breathScale;
};

struct OrbVertexOut {
    float4 position [[position]];
    float2 uv;
};

// 3-vertex fullscreen triangle covers the viewport with no vertex buffer.
// uv is in [0,1] after dividing the [-1,3] x [-1,3] cover triangle.
vertex OrbVertexOut orb_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2(
        (vid == 1) ? 2.0 : 0.0,
        (vid == 2) ? 2.0 : 0.0
    );
    OrbVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// HSV -> RGB (Hue in [0,1]).
static inline float3 orb_hsv_to_rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 orb_fragment(
    OrbVertexOut in [[stage_in]],
    constant OrbUniforms& u [[buffer(0)]]
) {
    // uv in [0,1]^2. Centre on (0.5, 0.5), recenter to [-1,1] for SDF math.
    float2 p = (in.uv - float2(0.5)) * 2.0;
    // Aspect correction so the orb stays circular in any viewport.
    p.x *= max(u.aspectRatio, 0.0001);
    // Squash along Y — talking pulse compresses vertical.
    p.y /= max(u.squashY, 0.001);

    // SDF circle, radius 0.85 of half-viewport to leave a margin for rim.
    // LifeSigns 体积呼吸:radius 受 breathScale 调制 (~1.0 ± 3%, 1.4s 周期).
    float r = length(p);
    float radius = 0.85 * u.breathScale;
    // Smooth body fade — full opacity inside, fade-out across ~0.05 unit.
    float body = 1.0 - smoothstep(radius - 0.06, radius, r);
    if (body <= 0.001) {
        // Transparent corners.
        return float4(0.0);
    }

    // Two layers of cosine flow producing slow metaball-like internal motion.
    // Phase advances with time*flowSpeed; spatial frequency tweaked so the
    // pattern reads at 48-72px.
    float t = u.time * u.flowSpeed;
    float flow1 = cos(p.x * 3.1 + t * 1.7) * cos(p.y * 2.4 - t * 1.3);
    float flow2 = cos(p.x * 5.7 - t * 2.1 + 1.2) * cos(p.y * 4.6 + t * 1.9);
    float flow = flow1 + flow2 * u.vortexIntensity;
    // Normalise approximately into [0,1] (flow ranges ~[-1-vortex, 1+vortex]).
    float maxAbs = 1.0 + max(u.vortexIntensity, 0.0);
    float flowN = clamp((flow / max(maxAbs, 0.0001)) * 0.5 + 0.5, 0.0, 1.0);

    // Hue is the main color, with brightness modulated by the flow field.
    // Saturation kept moderate so we get a "translucent gel" feel.
    float h = u.colorHue;
    float s = 0.55;
    float v = mix(0.62, 0.92, flowN);
    float3 baseRgb = orb_hsv_to_rgb(float3(h, s, v));

    // Fresnel rim: brighter near the edge of the disc. ndc-style normal
    // length acts as a proxy for view-angle factor on a unit hemisphere.
    float rimT = smoothstep(radius * 0.78, radius, r);
    // Soft white highlight (oklch 98% 0 0 ≈ near-white sRGB).
    float3 rimColor = float3(0.98);
    float3 rgb = mix(baseRgb, rimColor, rimT * 0.85);

    // Specular hot-spot offset to upper-left for a glassy look.
    float2 spec = p - float2(-0.35, -0.45);
    float specD = length(spec);
    float specT = 1.0 - smoothstep(0.0, 0.30, specD);
    rgb += rimColor * specT * 0.35;

    // Alpha drops slightly at rim so the orb feels glassy, not opaque.
    float alpha = body * mix(0.85, 1.0, 1.0 - rimT * 0.4);

    // Pre-multiplied output to match standard CALayer blending.
    return float4(rgb * alpha, alpha);
}
