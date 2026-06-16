import Testing
import Metal
@testable import SandboxPhysics

/// 回归守护「屏幕底部雪不断右滑」：settled CA 雪堆**不允许**有方向性横漂。
/// 诊断结论：CA 移动每帧翻转 leftFirst → settled 堆严格对称（任何窗口布局、
/// 风开关下，跑满 60s 质心都稳在中心 ±2 cell）。可见的横向运动只来自飞行粒子
/// 的风（`fsp_wind_at`），settled 雪不动。本测试钉死「settled 不漂」这条不变量。
@Suite("FallingSand 右滑回归")
struct FallingSandDriftDiagnosticTests {
    /// 居中对称窗口 + 风开：settled 雪堆质心必须接近中心（无方向漂）。
    @Test("settled 堆无方向漂：居中窗口 + wind=1.5，质心稳在中心")
    func settledSnowDoesNotDrift() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 200, gh = 120
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: gw, height: gh))
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 8192))
        engine.uploadTemperatures([Float](repeating: 0.2, count: gw * gh))   // 冷：不融
        particles.windX = 1.5
        engine.uploadRects([FSRect(x: 60, y: 50, w: 80, h: 40)])   // 居中悬浮窗（左右对称）
        let dt: Float = 1.0 / 60.0
        func comX() -> Double {
            let cells = engine.readback()
            var sumX = 0.0, n = 0
            for y in 0..<gh {
                for x in 0..<gw where FallingSandCell.species(cells[y * gw + x]) == .snow { sumX += Double(x); n += 1 }
            }
            return n > 0 ? sumX / Double(n) : Double(gw) / 2
        }
        for _ in 0..<1800 {   // 30s
            particles.emitTop(count: 8)
            particles.integrate(dt: dt)
            particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding, columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)
            engine.step(dt: dt)
        }
        // 中心 100，对称窗口 + 翻转 leftFirst → 无方向漂。> 8 cell 即回归。
        #expect(abs(comX() - 100.0) < 8)
    }
}
