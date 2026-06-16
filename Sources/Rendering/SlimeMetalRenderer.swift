import AppKit
import Metal
import QuartzCore

// MARK: - SlimeMetalRenderer
//
// 史莱姆/水滴形象 —— `MetalPetRenderer` 第二个子类。共享样板全在基类；本类只提供：
//   - shader 源（两圆 metaball 水滴 SDF + 两颗黑眼 + rim 果冻边）
//   - 情绪态 → 色相直切（不走 ease，史莱姆简化）
//   - 3 个招牌动作（celebrate 缩放反弹 / refuse 横向颤抖 / acknowledge opacity 短暗）
//
// 招牌动作叠在 hosting view 的 CALayer 上（CAKeyframeAnimation），不改 shader，
// 跟 PetChatAnimator.triggerJump 同源。

@MainActor
public final class SlimeMetalRenderer: MetalPetRenderer {

    // MARK: - 子类 pipeline 标识

    public override nonisolated class var shaderSource: String { metalSource }
    public override nonisolated class var vertexFunctionName: String { "slime_vertex" }
    public override nonisolated class var fragmentFunctionName: String { "slime_fragment" }

    // MARK: - 招牌动作

    public override var supportedSignatures: Set<SignatureAction> {
        [.celebrate, .refuse, .acknowledge]
    }

    public static let celebrateKey   = "slime.celebrate"
    public static let refuseKey      = "slime.refuse"
    public static let acknowledgeKey = "slime.acknowledge"

    // MARK: - 状态

    private var currentState: PetEmotionState = .idle

    // MARK: - Init

    public init?(device candidate: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: candidate)
        startRenderLoop()
    }

    // MARK: - PetRenderer 覆写

    public override func updateForState(_ state: PetEmotionState) {
        currentState = state
    }

    public override func trigger(_ signature: SignatureAction) {
        let layer = contentLayer
        switch signature {
        case .celebrate:   applyCelebrate(on: layer)
        case .refuse:      applyRefuse(on: layer)
        case .acknowledge: applyAcknowledge(on: layer)
        case .greet, .signatureIdle, .reactToDragEnd:
            break  // 未支持 —— 跟 supportedSignatures 集合一致
        }
    }

    // MARK: - 每帧编码（基类 hook）

    public override func encodeFrame(
        encoder: MTLRenderCommandEncoder,
        elapsed: Float,
        dt: Float,
        aspect: Float,
        breathScale: Float
    ) {
        var uniforms = SlimeShaderUniforms(
            colorHue: Self.hue(for: currentState),
            time: elapsed,
            aspectRatio: aspect,
            breathScale: breathScale
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SlimeShaderUniforms>.stride, index: 0)
    }

    // MARK: - 招牌动作动画

    private func applyCelebrate(on layer: CALayer) {
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, SlimeAnimTok.celebratePeak, 1.0]
        anim.keyTimes = [0, 0.4, 1]
        anim.duration = SlimeAnimTok.celebrateDuration
        anim.timingFunction = SlimeAnimTok.easeInOut
        layer.add(anim, forKey: Self.celebrateKey)
    }

    private func applyRefuse(on layer: CALayer) {
        let a = SlimeAnimTok.refuseShakeAmplitude
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, a, -a, a, -a, 0]
        anim.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        anim.duration = SlimeAnimTok.refuseDuration
        anim.timingFunction = SlimeAnimTok.easeInOut
        anim.isAdditive = true
        layer.add(anim, forKey: Self.refuseKey)
    }

    private func applyAcknowledge(on layer: CALayer) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1.0, SlimeAnimTok.acknowledgeAlphaLow, 1.0]
        anim.keyTimes = [0, 0.5, 1]
        anim.duration = SlimeAnimTok.acknowledgeDuration
        anim.timingFunction = SlimeAnimTok.easeInOut
        layer.add(anim, forKey: Self.acknowledgeKey)
    }

    // MARK: - 情绪 → 色相

    /// 史莱姆偏冷绿调：idle 海绿、thinking 偏蓝、confused 红橙警告。
    /// nonisolated 纯函数，允许测试非 main actor 调。
    public nonisolated static func hue(for state: PetEmotionState) -> Float {
        switch state {
        case .idle:     return 0.33
        case .watching: return 0.38
        case .thinking: return 0.55
        case .talking:  return 0.30
        case .confused: return 0.05
        }
    }

    // MARK: - Shader source（内联 MSL）

    private nonisolated static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct SlimeUniforms {
        float colorHue;
        float time;
        float aspectRatio;
        float breathScale;
    };

    struct SlimeVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex SlimeVertexOut slime_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2(
            (vid == 1) ? 2.0 : 0.0,
            (vid == 2) ? 2.0 : 0.0
        );
        SlimeVertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    static inline float3 slime_hsv_to_rgb(float3 c) {
        float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    static inline float slime_smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    fragment float4 slime_fragment(
        SlimeVertexOut in [[stage_in]],
        constant SlimeUniforms& u [[buffer(0)]]
    ) {
        float2 p = (in.uv - float2(0.5)) * 2.0;
        p.x *= max(u.aspectRatio, 0.0001);

        float baseRadius = 0.70 * u.breathScale;

        float2 body_center = float2(0.0, 0.08);
        float body_dist = length(p - body_center) - baseRadius;

        float2 top_center = float2(0.0, -0.45);
        float top_radius = 0.32 * u.breathScale;
        float top_dist = length(p - top_center) - top_radius;

        float d = slime_smin(body_dist, top_dist, 0.18);

        float body = 1.0 - smoothstep(-0.02, 0.02, d);
        if (body <= 0.001) {
            return float4(0.0);
        }

        float verticalLight = 1.0 - smoothstep(-0.5, 0.5, p.y);
        float h = u.colorHue;
        float s = 0.62;
        float v = mix(0.55, 0.95, verticalLight);
        float3 baseRgb = slime_hsv_to_rgb(float3(h, s, v));

        float2 spec = p - float2(-0.18, -0.32);
        float specT = 1.0 - smoothstep(0.0, 0.18, length(spec));
        float3 rgb = baseRgb + float3(specT * 0.45);

        float2 leftEye = float2(-0.22, 0.06);
        float2 rightEye = float2(0.22, 0.06);
        float eyeRadius = 0.075;
        float leftEyeMask = 1.0 - smoothstep(eyeRadius - 0.015, eyeRadius, length(p - leftEye));
        float rightEyeMask = 1.0 - smoothstep(eyeRadius - 0.015, eyeRadius, length(p - rightEye));
        float eyeMask = max(leftEyeMask, rightEyeMask);
        rgb = mix(rgb, float3(0.06, 0.06, 0.10), eyeMask);

        float rimT = smoothstep(-0.05, 0.0, d);
        rgb = mix(rgb, rgb * 0.65, rimT * 0.5);

        float alpha = body;
        return float4(rgb * alpha, alpha);
    }
    """
}

// MARK: - SlimeAnimTok

/// SignatureAction CALayer 动画的 timing/amplitude token。不复用 Shell 的 AnimTok
/// （Rendering 不能 import Shell），inline 一份，数值刻度跟 AnimTok 同量级保持节奏一致。
private enum SlimeAnimTok {
    static let celebrateDuration: TimeInterval = 0.4
    static let celebratePeak: CGFloat = 1.15
    static let refuseShakeAmplitude: CGFloat = 6
    static let refuseDuration: TimeInterval = 0.5
    static let acknowledgeDuration: TimeInterval = 0.18
    static let acknowledgeAlphaLow: CGFloat = 0.55
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
}

// MARK: - GPU layout struct

/// 4 × float32 = 16 bytes，跟 MSL `SlimeUniforms` 字节布局严格一致。
struct SlimeShaderUniforms {
    var colorHue: Float
    var time: Float
    var aspectRatio: Float
    var breathScale: Float
}

// MARK: - SlimePetPlugin

/// 第二个内置 pet 形象插件。注册到 `PetPluginRegistry.shared`，UserDefaults["pet.plugin.id"]
/// 写 "slime" 启动时切换到史莱姆。
public enum SlimePetPlugin: PetPlugin {
    public static let identity = PetIdentity(
        id: "slime",
        displayName: "史莱姆",
        recommendedSize: NSSize(width: 64, height: 64)
    )

    @MainActor
    public static func makeRenderer() -> PetRenderer? {
        SlimeMetalRenderer()
    }
}
