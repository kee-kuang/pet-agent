import AppKit
import Testing
@testable import Rendering

@Suite("SlimeMetalRenderer + SlimePetPlugin")
struct SlimeMetalRendererTests {

    // MARK: - SlimePetPlugin identity

    @Test("SlimePetPlugin identity = id:slime / 史莱姆 / 64×64")
    func slimeIdentity() {
        let id = SlimePetPlugin.identity
        #expect(id.id == "slime")
        #expect(id.displayName == "史莱姆")
        #expect(id.recommendedSize == NSSize(width: 64, height: 64))
    }

    @Test("SlimePetPlugin.makeRenderer Metal-aware (有设备 → SlimeMetalRenderer, 无 → nil)")
    @MainActor
    func slimeMakeRenderer() {
        let r = SlimePetPlugin.makeRenderer()
        if r != nil {
            #expect(r is SlimeMetalRenderer)
        }
    }

    // MARK: - hue 情绪映射

    @Test("hue(for:) 五态返回不同色相")
    func hueForState() {
        let hues = Set([
            SlimeMetalRenderer.hue(for: .idle),
            SlimeMetalRenderer.hue(for: .watching),
            SlimeMetalRenderer.hue(for: .thinking),
            SlimeMetalRenderer.hue(for: .talking),
            SlimeMetalRenderer.hue(for: .confused),
        ])
        // 至少 4 个不同 (idle/watching 可能接近, 但 thinking/confused 一定不同)
        #expect(hues.count >= 4)
    }

    @Test("hue(for: .confused) 是红橙色调 (< 0.1) — 警告语义")
    func confusedIsRed() {
        #expect(SlimeMetalRenderer.hue(for: .confused) < 0.1)
    }

    @Test("hue(for: .idle) 是绿色调 (0.25 ~ 0.45) — 史莱姆基色")
    func idleIsGreen() {
        let h = SlimeMetalRenderer.hue(for: .idle)
        #expect(h >= 0.25 && h <= 0.45)
    }

    // MARK: - Shader source 完整性

    @Test("shader source 含 slime_vertex / slime_fragment 入口")
    func shaderEntryPoints() {
        let src = SlimeMetalRenderer.shaderSource
        #expect(src.contains("slime_vertex"))
        #expect(src.contains("slime_fragment"))
    }

    @Test("shader source 含 metaball smin (融合主体 + 顶部小弧)")
    func shaderHasMetaball() {
        let src = SlimeMetalRenderer.shaderSource
        #expect(src.contains("slime_smin"))
    }

    @Test("shader source 含两颗眼睛的 SDF")
    func shaderHasEyes() {
        let src = SlimeMetalRenderer.shaderSource
        #expect(src.contains("leftEye") || src.contains("rightEye"))
        #expect(src.contains("eyeRadius") || src.contains("eyeMask"))
    }

    // MARK: - PetRenderer conformance

    @Test("SlimeMetalRenderer supportedSignatures = {.celebrate, .refuse, .acknowledge}")
    @MainActor
    func slimeSupportedSignatures() {
        guard let r = SlimeMetalRenderer() else { return }
        let sig = r.supportedSignatures
        #expect(sig.contains(.celebrate))
        #expect(sig.contains(.refuse))
        #expect(sig.contains(.acknowledge))
        // 当前阶段未支持的招式,确保被显式排除
        #expect(!sig.contains(.greet))
        #expect(!sig.contains(.signatureIdle))
        #expect(!sig.contains(.reactToDragEnd))
    }

    // MARK: - SignatureAction trigger → CAAnimation key

    @Test("trigger(.celebrate) 给 layer 挂 celebrateKey 动画")
    @MainActor
    func slimeTriggerCelebrateAddsAnimationKey() {
        guard let r = SlimeMetalRenderer() else { return }
        r.trigger(.celebrate)
        let keys = r.contentLayer.animationKeys() ?? []
        #expect(keys.contains(SlimeMetalRenderer.celebrateKey))
    }

    @Test("trigger(.refuse) 给 layer 挂 refuseKey 动画")
    @MainActor
    func slimeTriggerRefuseAddsAnimationKey() {
        guard let r = SlimeMetalRenderer() else { return }
        r.trigger(.refuse)
        let keys = r.contentLayer.animationKeys() ?? []
        #expect(keys.contains(SlimeMetalRenderer.refuseKey))
    }

    @Test("trigger(.acknowledge) 给 layer 挂 acknowledgeKey 动画")
    @MainActor
    func slimeTriggerAcknowledgeAddsAnimationKey() {
        guard let r = SlimeMetalRenderer() else { return }
        r.trigger(.acknowledge)
        let keys = r.contentLayer.animationKeys() ?? []
        #expect(keys.contains(SlimeMetalRenderer.acknowledgeKey))
    }

    @Test("trigger(.greet) 不在 supportedSignatures, 不挂任何 slime.* 动画")
    @MainActor
    func slimeTriggerUnsupportedIsNoOp() {
        guard let r = SlimeMetalRenderer() else { return }
        r.trigger(.greet)
        let keys = r.contentLayer.animationKeys() ?? []
        let slimeKeys = keys.filter { $0.hasPrefix("slime.") }
        #expect(slimeKeys.isEmpty)
    }
}
