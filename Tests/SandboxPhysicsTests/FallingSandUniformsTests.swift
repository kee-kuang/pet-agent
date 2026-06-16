import Testing
@testable import SandboxPhysics

@Suite("FallingSandUniforms 布局")
struct FallingSandUniformsTests {
    @Test("27 个 4 字节标量 → stride 108，无 padding")
    func strideIs108() {
        // 22 原字段 + pet occluder 5 字段（petOriginX/Y:Int32 + petMaskW/H + petEnabled）
        // = 27 字段 × 4 字节，全 4 字节对齐 → MSL 端同布局（stride 闸防漂移）。
        #expect(MemoryLayout<FallingSandUniforms>.stride == 108)
        #expect(MemoryLayout<FallingSandUniforms>.size == 108)
        #expect(MemoryLayout<FallingSandUniforms>.alignment == 4)
    }

    @Test("默认值取自 FallingSandRules")
    func defaultsFromRules() {
        let u = FallingSandUniforms(gridWidth: 10, gridHeight: 10)
        #expect(u.snowFallProbability == FallingSandRules.snowFallProbability)
        #expect(u.meltThreshold == FallingSandRules.meltThreshold)
        #expect(u.steamLifetimeFrames == UInt32(FallingSandRules.steamLifetimeFrames))
        #expect(u.leftFirst == 1)
        #expect(u.passKind == 0)
    }
}
