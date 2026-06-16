import Metal
import simd

/// 飞行雪粒子渲染：instanced quad billboard，每粒子一个软圆，半径 = particle.size。
/// 浮点位置 → 平滑移动；per-particle size → 大小不一雪花。研究警告 macOS point_size
/// 可能上限=1，故用 quad（每实例 6 顶点 2 三角）稳妥；Snowfall 实际用了 point_size
/// 但 quad 更可控。
///
/// 坐标：粒子 position 是 cell 坐标（x∈[0,gridW], y∈[0,gridH], y 上）→ NDC。
public final class FallingSandParticleRenderPipeline {
    private let pipelineState: MTLRenderPipelineState

    struct Uniforms {
        var gridWidth: Float
        var gridHeight: Float
    }

    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct SnowParticle {
    float2 position;
    float2 velocity;
    float size;
    uint seed;
    uint alive;
    uint kind;   // 0 = 雪, 1 = 雨
};

struct PRUniforms { float grid_width; float grid_height; };

struct PRVary {
    float4 position [[position]];
    float2 uv;       // quad 局部 [-1,1]
    float  bright;   // per-particle 亮度抖动
    float  kindf;    // 0 = 雪, 1 = 主雨, 2 = splash 水花
};

vertex PRVary fs_particle_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device SnowParticle* particles [[buffer(0)]],
    constant PRUniforms& u               [[buffer(1)]]
) {
    SnowParticle p = particles[iid];
    PRVary out;
    if (p.alive == 0u) {                       // dead → 退化到屏外
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.bright = 0.0;
        out.kindf = 0.0;
        return out;
    }
    // 6 顶点两三角组成 quad，局部角 [-1,1]
    float2 corners[6] = {
        float2(-1,-1), float2(1,-1), float2(-1,1),
        float2(1,-1),  float2(1,1),  float2(-1,1)
    };
    float2 c = corners[vid];
    bool isMainRain = (p.kind == 1u);
    bool isSplash   = (p.kind == 2u);
    // size 是「半径」cell 数，扩一点让软边不被裁。
    float r = max(p.size, 0.6) * 1.3;

    float2 cellPos;
    if (isMainRain) {
        // 主雨 = 沿 velocity 定向的细长 streak（随风斜 → quad 跟着倾斜）。
        float2 vel = p.velocity;
        float speed = length(vel);
        float2 tangent = speed < 1e-3 ? float2(0.0, -1.0) : vel / speed;
        float2 normal  = float2(-tangent.y, tangent.x);
        float halfLen = r * 2.6;   // 沿运动方向拉长（motion-blur 拖影）
        float halfWid = r * 0.5;   // 垂直方向收紧
        cellPos = p.position + tangent * (halfLen * c.y) + normal * (halfWid * c.x);
    } else if (isSplash) {
        // splash 水花 = 小蓝圆点（贴地扩散的水珠）。
        float sr = r * 0.85;
        cellPos = p.position + c * float2(sr, sr);
    } else {
        // 雪 = 软白圆。
        cellPos = p.position + c * float2(r, r);
    }
    float2 ndc = float2(cellPos.x / u.grid_width * 2.0 - 1.0,
                        cellPos.y / u.grid_height * 2.0 - 1.0);
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = c;
    // seed → 亮度抖动 0.88..1.0
    out.bright = 0.88 + float(p.seed & 0xFFu) / 255.0 * 0.12;
    out.kindf = float(p.kind);
    return out;
}

fragment float4 fs_particle_fragment(PRVary in [[stage_in]]) {
    bool isMainRain = (in.kindf > 0.5 && in.kindf < 1.5);
    bool isSplash   = (in.kindf > 1.5);
    float a;
    if (isMainRain) {
        // 主雨：定向 streak（横向收紧、纵向缓出软端；uv.x=宽、uv.y=长）
        a = smoothstep(1.0, 0.25, abs(in.uv.x)) * smoothstep(1.0, 0.75, abs(in.uv.y));
    } else {
        // 雪 / splash 水花：软圆（splash 边缘略硬一点更像水珠）
        a = smoothstep(1.0, isSplash ? 0.45 : 0.35, length(in.uv));
    }
    if (a <= 0.001) discard_fragment();
    float3 snowCol = float3(0.95, 0.96, 0.99);
    float3 rainCol = float3(0.58, 0.74, 0.96);   // 淡蓝
    bool isRainLike = isMainRain || isSplash;
    float3 col = (isRainLike ? rainCol : snowCol) * in.bright;
    float alpha;
    if (isSplash)        { alpha = a * 0.6; }    // 水花最透（小水珠）
    else if (isMainRain) { alpha = a * 0.7; }    // 雨较透
    else                 { alpha = a; }          // 雪实
    return float4(col, alpha);
}
"""

    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard
            let library = try? device.makeLibrary(source: Self.source, options: nil),
            let vfn = library.makeFunction(name: "fs_particle_vertex"),
            let ffn = library.makeFunction(name: "fs_particle_fragment")
        else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let att = desc.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        att.isBlendingEnabled = true
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipelineState = state
    }

    /// 把粒子层画进 encoder（调用方管 render pass）。instanceCount = 粒子容量。
    public func encode(
        into encoder: MTLRenderCommandEncoder,
        particleBuffer: MTLBuffer,
        instanceCount: Int,
        gridWidth: Int,
        gridHeight: Int
    ) {
        var u = Uniforms(gridWidth: Float(gridWidth), gridHeight: Float(gridHeight))
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
    }
}
