import Testing
@testable import SandboxPhysics

@Suite("FallingSandSimulation 编排")
struct FallingSandSimulationTests {
    @Test("spawnTopRow 在顶行铺元素")
    func spawnFillsTopRow() {
        var sim = FallingSandSimulation(width: 10, height: 10, seed: 1)
        sim.spawnTopRow(.snow, fillRatio: 1.0)
        var count = 0
        for x in 0..<10 where FallingSandCell.species(sim.grid.at(x, 9)) == .snow { count += 1 }
        #expect(count == 10)
    }

    @Test("step 让顶部雪下落（占用数守恒，无温度场时）")
    func stepMovesSnowDown() {
        var sim = FallingSandSimulation(width: 6, height: 12, seed: 7)
        sim.spawnTopRow(.snow, fillRatio: 1.0)
        let before = sim.grid.occupiedCount()
        for _ in 0..<5 { sim.step(dt: 1.0 / 30.0, temperatures: nil) }
        #expect(sim.grid.occupiedCount() == before)
        // 顶行应已空出（雪落下去了）
        var topCount = 0
        for x in 0..<6 where !FallingSandCell.isEmpty(sim.grid.at(x, 11)) { topCount += 1 }
        #expect(topCount < before)
    }

    @Test("连续降雪 + 升华 → 稳态，不填满屏幕")
    func continuousSnowfallReachesSteadyState() {
        let w = 40, h = 50
        let cap = w * h
        var sim = FallingSandSimulation(width: w, height: h, seed: 1)
        let cold = [Float](repeating: 0.2, count: cap)   // 冷：不融化，升华是唯一消除
        var lateCounts: [Int] = []
        for f in 0..<2000 {
            sim.spawnTopRow(.snow, fillRatio: 0.02)
            sim.step(dt: 1.0 / 30.0, temperatures: cold)
            if f >= 1500 && f % 100 == 0 { lateCounts.append(sim.grid.occupiedCount()) }
        }
        // 稳态：远不填满（无升华会一路涨到接近 cap）
        #expect(sim.grid.occupiedCount() < cap * 2 / 5)
        // 后段稳定：最大与最小采样差不超过 grid 的 15%（不是单调暴涨）
        if let lo = lateCounts.min(), let hi = lateCounts.max() {
            #expect(hi - lo < cap / 7)
        }
    }

    /// 稳态深度 occupied 数（spawn 固定速率跑到稳态后多帧均值）。
    private func steadyOccupied(fillRatio: Float, w: Int, h: Int, seed: UInt64) -> Double {
        var sim = FallingSandSimulation(width: w, height: h, seed: seed)
        let cold = [Float](repeating: 0.2, count: w * h)
        var samples: [Int] = []
        for f in 0..<2400 {
            sim.spawnTopRow(.snow, fillRatio: fillRatio)
            sim.step(dt: 1.0 / 30.0, temperatures: cold)
            if f >= 1800 && f % 100 == 0 { samples.append(sim.grid.occupiedCount()) }
        }
        return Double(samples.reduce(0, +)) / Double(samples.count)
    }

    @Test("深度负反馈：spawn 速率不敏感（4× spawn → 深度涨远小于 4×，自限）")
    func accumulationIsSpawnRateInsensitive() {
        let w = 48, h = 64
        let lo = steadyOccupied(fillRatio: 0.02, w: w, h: h, seed: 1)
        let hi = steadyOccupied(fillRatio: 0.08, w: w, h: h, seed: 1)   // 4× spawn
        // 自限：4× spawn 深度涨 < 3×（负反馈），绝非线性 4×（旧固定速率会发散）。
        #expect(hi < lo * 3.0)
        // 都不填满
        #expect(hi < Double(w * h) * 0.6)
        // 高 spawn 确实更深（机制活着，非饱和到顶）
        #expect(hi > lo)
    }

    @Test("H₂O 循环：底部一摊水，全局高温 → 出现蒸汽")
    func waterEvaporatesUnderHeat() {
        var sim = FallingSandSimulation(width: 8, height: 8, seed: 3)
        for x in 0..<8 { sim.setCell(x, 0, FallingSandCell.make(.water, ra: 100)) }
        let hot = [Float](repeating: 0.95, count: 64)
        var sawSteam = false
        for _ in 0..<200 {
            sim.step(dt: 1.0 / 30.0, temperatures: hot)
            if sim.grid.cells.contains(where: { FallingSandCell.species($0) == .steam }) {
                sawSteam = true; break
            }
        }
        #expect(sawSteam)
    }
}

@Suite("FallingSandSimulation 视觉自评")
struct FallingSandVisualTests {
    @Test("降雪 200 帧 dump PNG（人工/Claude 视觉验收堆积坡形）")
    func snowfallDump() {
        var sim = FallingSandSimulation(width: 80, height: 60, seed: 42)
        let cold = [Float](repeating: 0.2, count: 80 * 60)   // 低温：雪不融
        // 前 130 帧持续降雪，后 70 帧停 spawn 让雪落到底 + 堆积塌坡
        for f in 0..<200 {
            if f < 130 { sim.spawnTopRow(.snow, fillRatio: 0.15) }
            sim.step(dt: 1.0 / 30.0, temperatures: cold)
        }
        FallingSandPNG.dump(sim.grid, to: "/tmp/fallingsand_snow.png")
        // 断言：底部有积雪（视觉细节靠人工/Claude 看 PNG）
        var bottomSnow = 0
        for x in 0..<80 where FallingSandCell.species(sim.grid.at(x, 0)) == .snow { bottomSnow += 1 }
        #expect(bottomSnow > 0)
    }
}
