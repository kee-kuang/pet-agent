import Testing
@testable import SandboxPhysics

@Suite("FallingSandPhase 相变")
struct FallingSandPhaseTests {
    /// 单 cell 网格 + 恒定温度，跑 N 帧相变，返回最终 species。
    func runPhase(_ s: FallingSandSpecies, temp: Float, frames: Int, seed: UInt64) -> FallingSandSpecies {
        var g = FallingSandGrid(width: 1, height: 1)
        g.set(0, 0, FallingSandCell.make(s, ra: 100))
        let temps = [Float](repeating: temp, count: 1)
        var rng = FallingSandRandom(seed: seed)
        for _ in 0..<frames {
            FallingSandPhase.apply(&g, temperatures: temps, dt: 1.0 / 30.0, rng: &rng)
        }
        return FallingSandCell.species(g.at(0, 0))
    }

    @Test("暖温雪 → 水（高于融点、低于蒸发阈，融而不沸）")
    func warmSnowMelts() {
        #expect(runPhase(.snow, temp: 0.7, frames: 300, seed: 1) == .water)
    }

    @Test("低温水 → 冰")
    func coldWaterFreezes() {
        #expect(runPhase(.water, temp: 0.1, frames: 300, seed: 1) == .ice)
    }

    @Test("极高温水 → 蒸汽")
    func boilingWaterEvaporates() {
        #expect(runPhase(.water, temp: 0.95, frames: 300, seed: 1) == .steam)
    }

    @Test("暖温冰 → 水（高于融点、低于蒸发阈，融而不沸）")
    func warmIceMelts() {
        #expect(runPhase(.ice, temp: 0.7, frames: 300, seed: 1) == .water)
    }

    @Test("凉爽蒸汽 → 水（凝结，温度在冰点与凝结阈之间，凝而不冻）")
    func coolSteamCondenses() {
        #expect(runPhase(.steam, temp: 0.45, frames: 300, seed: 1) == .water)
    }

    @Test("中性温度雪不融化成水（可缓慢升华→empty，但绝不→water）")
    func neutralSnowDoesNotMelt() {
        // 中性温度（< 融点）：雪不该融成水；升华→empty 是允许的稳态消除。
        #expect(runPhase(.snow, temp: 0.45, frames: 300, seed: 1) != .water)
    }

    @Test("冷天雪缓慢升华 → empty（连续降雪稳态消除）")
    func coldSnowSublimates() {
        // 冷天无融化，升华是唯一移除路径：足够多帧后雪 → empty。
        #expect(runPhase(.snow, temp: 0.2, frames: 2000, seed: 1) == .empty)
    }
}
