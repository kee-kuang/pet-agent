/// Falling-sand 像素渲染 MSL。fullscreen 三角 vertex（无 vertex buffer，用
/// vertex_id 生成）+ fragment 读 cell buffer → species 基色 + ra 亮度抖动，
/// nearest 像素感。颜色值必须对齐 `FallingSandPalette`（Swift 端真值源）。
///
/// 坐标：uv.y=0 = 屏幕底 = cell y=0（world 底行）。empty cell 输出全透明。
enum FallingSandRenderKernels {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct FSRenderUniforms {
    uint grid_width;
    uint grid_height;
    float wetness;   // 0..1 积水洼湿亮 sheen（下雨时→1，停雨回落到基线）
};

struct FSVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex FSVaryings fs_fullscreen_vertex(uint vid [[vertex_id]]) {
    // 覆盖全屏的大三角（3 顶点）
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = pos[vid];
    FSVaryings out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * 0.5 + 0.5;   // [0,1]，uv.y=0 在底
    return out;
}

fragment float4 fs_pixel_fragment(
    FSVaryings in                  [[stage_in]],
    const device uint* cells       [[buffer(0)]],
    constant FSRenderUniforms& u   [[buffer(1)]]
) {
    int cx = int(in.uv.x * float(u.grid_width));
    int cy = int(in.uv.y * float(u.grid_height));
    if (cx < 0 || cy < 0 || cx >= int(u.grid_width) || cy >= int(u.grid_height)) {
        return float4(0.0);
    }
    uint p = cells[uint(cy) * u.grid_width + uint(cx)];
    uint sp = p & 0xFFu;
    uint ra = (p >> 8) & 0xFFu;

    if (sp == 0u) return float4(0.0, 0.0, 0.0, 0.0);   // empty

    float4 base;
    if      (sp == 1u) base = float4(0.30, 0.30, 0.34, 1.0);    // wall
    else if (sp == 2u) base = float4(0.95, 0.96, 0.99, 1.0);    // snow
    else if (sp == 3u) base = float4(0.26, 0.52, 0.92, 0.92);   // water
    else if (sp == 4u) base = float4(0.72, 0.85, 0.95, 1.0);    // ice
    else               base = float4(0.85, 0.88, 0.92, 0.45);   // steam

    if (sp == 3u) {   // 湿亮 sheen（同 soft fragment）
        base.rgb = mix(base.rgb, float3(0.40, 0.66, 1.0), clamp(u.wetness, 0.0, 1.0) * 0.6);
    }
    float jitter = 0.94 + (float(ra) / 255.0) * 0.12;   // 对齐 FallingSandPalette.shaded
    return float4(base.rgb * jitter, base.a);
}

// species → 基色（soft fragment 复用）。empty 返回 a=0。
inline float4 fs_base_color(uint sp) {
    if (sp == 0u) return float4(0.0);
    if (sp == 1u) return float4(0.30, 0.30, 0.34, 1.0);    // wall
    if (sp == 2u) return float4(0.95, 0.96, 0.99, 1.0);    // snow
    if (sp == 3u) return float4(0.26, 0.52, 0.92, 0.92);   // water
    if (sp == 4u) return float4(0.72, 0.85, 0.95, 1.0);    // ice
    return float4(0.85, 0.88, 0.92, 0.45);                 // steam
}

// 柔和渲染：每输出像素采样 cell 的 5×5 邻域，按到 sub-cell 点的距离做高斯加权，
// 软化硬像素方块成柔边雪 + 软 alpha。落雪→软发光小点，雪堆→连续柔面。
fragment float4 fs_soft_fragment(
    FSVaryings in                  [[stage_in]],
    const device uint* cells       [[buffer(0)]],
    constant FSRenderUniforms& u   [[buffer(1)]]
) {
    float cfx = in.uv.x * float(u.grid_width);
    float cfy = in.uv.y * float(u.grid_height);
    int ccx = int(cfx);
    int ccy = int(cfy);

    // Splat 累加：每个占用 cell 按自己的 rb（尺寸种子）画一个高斯软团，rb 大 →
    // sigma 大 → 软团大 → 大小不一的雪花。单 cell = 一片雪花（不靠 clump）。
    float3 colorAccum = float3(0.0);
    float alphaAccum = 0.0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int sx = ccx + dx;
            int sy = ccy + dy;
            if (sx < 0 || sy < 0 || sx >= int(u.grid_width) || sy >= int(u.grid_height)) continue;
            uint p = cells[uint(sy) * u.grid_width + uint(sx)];
            uint sp = p & 0xFFu;
            if (sp == 0u) continue;
            uint ra = (p >> 8) & 0xFFu;
            uint rb = (p >> 16) & 0xFFu;
            float cxC = float(sx) + 0.5;
            float cyC = float(sy) + 0.5;
            float d2 = (cfx - cxC) * (cfx - cxC) + (cfy - cyC) * (cfy - cyC);
            // 每片雪花尺寸：rb 大 → flakeSigma 大 → 软团大（0.30 .. ~2.2）
            float flakeSigma = 0.30 + (float(rb) / 255.0) * 1.9;
            float w = exp(-d2 / flakeSigma);
            float4 base = fs_base_color(sp);
            if (sp == 3u) {
                // 湿亮 sheen：积水真实是湿的 → 朝更亮的湿蓝提亮（非假水痕）。
                // 下雨 wetness→1 时最亮，停雨回落到基线仍保留一点光泽。
                float3 wetCol = float3(0.40, 0.66, 1.0);
                base.rgb = mix(base.rgb, wetCol, clamp(u.wetness, 0.0, 1.0) * 0.6);
            }
            float jitter = 0.94 + (float(ra) / 255.0) * 0.12;
            float contrib = base.a * w;
            colorAccum += base.rgb * jitter * contrib;
            alphaAccum += contrib;
        }
    }
    if (alphaAccum < 0.0001) return float4(0.0);
    float3 col = colorAccum / alphaAccum;
    float a = min(alphaAccum, 1.0);   // 累加 alpha 封顶（孤立雪花软、雪堆实）
    return float4(col, a);
}
"""
}
