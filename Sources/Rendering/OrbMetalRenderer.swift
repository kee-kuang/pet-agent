import AppKit
import Metal
import QuartzCore

// MARK: - OrbMetalRenderer
//
// 弹力球形象 —— `MetalPetRenderer` 的第一个子类。共享的 CAMetalLayer / CVDisplayLink /
// 30Hz 帧节流 / pipeline / tickAndRender 前后处理全在基类；本类只提供 Orb 专属：
//   - shader 源（单圆 SDF + 余弦流动 + rim + spec + pile 折射）
//   - 缓动 uniforms（情绪态 ease-out 0.25s）
//   - 物理 squash 耦合（updateForVelocity，沿速度拉长、垂直压扁，体积守恒）
//   - pile（雪）接触 mask 纹理绑定（预留；默认 1×1 zero-alpha dummy）
//
// supportedSignatures 用基类默认空集（Orb 无招牌动作，交互反馈走 PetChatAnimator ambient 层）。

@MainActor
public final class OrbMetalRenderer: MetalPetRenderer {

    // MARK: - 子类 pipeline 标识

    public override nonisolated class var shaderSource: String { metalSource }
    public override nonisolated class var vertexFunctionName: String { "orb_vertex" }
    public override nonisolated class var fragmentFunctionName: String { "orb_fragment" }

    // MARK: - Orb 专属状态

    private var currentUniforms = OrbUniforms.target(for: .idle)
    private var targetUniforms = OrbUniforms.target(for: .idle)
    /// 当前情绪态的「静息」目标（updateForState 写），squash override 叠在它上面、速度归零时 ease 回它。
    private var stateBaseUniforms = OrbUniforms.target(for: .idle)

    /// 外部 pile 接触 mask（alpha 通道）。nil 时绑 1×1 zero-alpha dummy，shader 路径恒定无分支。
    private var pileMaskTexture: MTLTexture?
    /// 创建于 init（需 device，故 super.init 后赋值；IUO 在 super.init 前隐式 nil 满足初始化序）。
    private var pileMaskSampler: MTLSamplerState!
    private var pileMaskDummyTexture: MTLTexture!

    // MARK: - Init

    public init?(device candidate: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: candidate)
        // device 由基类设好；创建 Orb 专属设备资源，失败则整体 nil（先于 startRenderLoop）。
        guard
            let sampler = Self.makePileMaskSampler(device: device),
            let dummy = Self.makePileMaskDummyTexture(device: device)
        else { return nil }
        self.pileMaskSampler = sampler
        self.pileMaskDummyTexture = dummy
        startRenderLoop()
    }

    // MARK: - PetRenderer 覆写

    public override func updateForState(_ state: PetEmotionState) {
        let base = OrbUniforms.target(for: state)
        stateBaseUniforms = base
        targetUniforms = base
    }

    /// 物理 squash 耦合 —— 拖动/弹跳速度 → squash 各向异性：沿速度向量拉长、正交轴压缩
    /// （体积守恒）；幅度按 |v| 映射并硬截顶，球永不拍扁。`.zero` 是「释放」信号 → target
    /// 弹回情绪静息基，display-link ease 走曲线。
    public override func updateForVelocity(_ velocity: CGVector) {
        let mag = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
        guard mag > 0.001 else {
            targetUniforms = stateBaseUniforms
            return
        }
        let maxV: Double = 600.0
        let maxIntensity: Float = 0.15
        let clamped = min(mag, maxV)
        let intensity = Float(clamped / maxV) * maxIntensity

        let nx = Float(abs(velocity.dx / mag))
        let ny = Float(abs(velocity.dy / mag))
        let stretchX = 1.0 + intensity * nx
        let squashYAxis = 1.0 - intensity * nx
        let stretchY = 1.0 + intensity * ny
        let squashXAxis = 1.0 - intensity * ny
        let weightX = nx * nx
        let weightY = ny * ny
        let resultX = stretchX * weightX + squashXAxis * weightY
        let resultY = squashYAxis * weightX + stretchY * weightY

        var t = stateBaseUniforms
        t.squashX = resultX
        // 乘上情绪基的 squashY，让 talking burst（0.92）在拖动时仍可见 —— 物理不抹情绪。
        t.squashY = stateBaseUniforms.squashY * resultY
        targetUniforms = t
    }

    // MARK: - 每帧编码（基类 hook）

    public override func encodeFrame(
        encoder: MTLRenderCommandEncoder,
        elapsed: Float,
        dt: Float,
        aspect: Float,
        breathScale: Float
    ) {
        currentUniforms = currentUniforms.eased(toward: targetUniforms, dt: dt)
        var gpuUniforms = OrbShaderUniforms(
            colorHue: currentUniforms.colorHue,
            flowSpeed: currentUniforms.flowSpeed,
            vortexIntensity: currentUniforms.vortexIntensity,
            squashY: currentUniforms.squashY,
            time: elapsed,
            aspectRatio: aspect,
            breathScale: breathScale
        )
        encoder.setFragmentBytes(&gpuUniforms, length: MemoryLayout<OrbShaderUniforms>.stride, index: 0)
        // pile mask：无外部 mask 时绑 1×1 zero-alpha dummy，shader 无需 nil 分支。
        encoder.setFragmentTexture(pileMaskTexture ?? pileMaskDummyTexture, index: 0)
        encoder.setFragmentSamplerState(pileMaskSampler, index: 0)
    }

    // MARK: - Pile mask 绑定

    /// 绑外部 pile 接触 mask（RGBA8/R8，仅采 alpha）。nil 脱离 → 仍绑 dummy，无可见效果。
    public func setPileMaskTexture(_ texture: MTLTexture?) {
        pileMaskTexture = texture
    }

    private static func makePileMaskSampler(device: MTLDevice) -> MTLSamplerState? {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .notMipmapped
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        desc.normalizedCoordinates = true
        return device.makeSamplerState(descriptor: desc)
    }

    private static func makePileMaskDummyTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let zero: [UInt8] = [0, 0, 0, 0]
        zero.withUnsafeBufferPointer { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }

    // MARK: - Shader source（与 Sources/Rendering/Shaders/Orb.metal 字节等价）

    private nonisolated static let metalSource: String = """
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

    static inline float3 orb_hsv_to_rgb(float3 c) {
        float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    fragment float4 orb_fragment(
        OrbVertexOut in [[stage_in]],
        constant OrbUniforms& u [[buffer(0)]],
        texture2d<float, access::sample> pileMask [[texture(0)]],
        sampler maskSampler [[sampler(0)]]
    ) {
        float2 p = (in.uv - float2(0.5)) * 2.0;
        p.x *= max(u.aspectRatio, 0.0001);
        p.y /= max(u.squashY, 0.001);

        float r = length(p);
        float radius = 0.85 * u.breathScale;
        float body = 1.0 - smoothstep(radius - 0.06, radius, r);
        if (body <= 0.001) {
            return float4(0.0);
        }

        float t = u.time * u.flowSpeed;
        float flow1 = cos(p.x * 3.1 + t * 1.7) * cos(p.y * 2.4 - t * 1.3);
        float flow2 = cos(p.x * 5.7 - t * 2.1 + 1.2) * cos(p.y * 4.6 + t * 1.9);
        float flow = flow1 + flow2 * u.vortexIntensity;
        float maxAbs = 1.0 + max(u.vortexIntensity, 0.0);
        float flowN = clamp((flow / max(maxAbs, 0.0001)) * 0.5 + 0.5, 0.0, 1.0);

        float h = u.colorHue;
        float s = 0.55;
        float v = mix(0.62, 0.92, flowN);
        float3 baseRgb = orb_hsv_to_rgb(float3(h, s, v));

        float rimT = smoothstep(radius * 0.78, radius, r);
        float3 rimColor = float3(0.98);
        float3 rgb = mix(baseRgb, rimColor, rimT * 0.85);

        float2 spec = p - float2(-0.35, -0.45);
        float specD = length(spec);
        float specT = 1.0 - smoothstep(0.0, 0.30, specD);
        rgb += rimColor * specT * 0.35;

        float maskValue = pileMask.sample(maskSampler, in.uv).a;
        float3 warm = float3(1.0, 0.92, 0.78);
        rgb = mix(rgb, warm, clamp(maskValue, 0.0, 1.0) * 0.6);

        float alpha = body * mix(0.85, 1.0, 1.0 - rimT * 0.4);
        return float4(rgb * alpha, alpha);
    }
    """

    // MARK: - Test hooks

    public var currentUniformsForTesting: OrbUniforms { currentUniforms }
    public var targetUniformsForTesting: OrbUniforms { targetUniforms }
}

// MARK: - GPU layout struct

/// 跟 MSL `OrbUniforms` 字节布局严格一致（7 × float32 = 28 bytes，4-byte 对齐无 padding）。
struct OrbShaderUniforms {
    var colorHue: Float
    var flowSpeed: Float
    var vortexIntensity: Float
    var squashY: Float
    var time: Float
    var aspectRatio: Float
    /// LifeSigns 体积呼吸 SDF radius 倍率（基类 tickAndRender 用 LifeSignsTokens 正弦算）。
    var breathScale: Float
}
