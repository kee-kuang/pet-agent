import Testing
import Metal
@testable import SandboxPhysics

/// 诊断「底部雪堆不起来、往右滑、无摩擦」：怀疑夏季真实气温(ambient≈0.83)>meltThreshold(0.50)
/// → 雪落地即融成水 → 水无 angle of repose、横向漫流 = 无摩擦平铺滑动。
/// 对比 ambient=0.83(夏) vs 0.20(冷)：热的应几乎全是 water，冷的应全是 snow 且堆积。
@Suite("FallingSand 融化诊断")
struct FallingSandMeltDiagnosticTests {
    private func runAndCount(ambient: Float, frames: Int) throws -> (snow: Int, water: Int, maxPileHeight: Int) {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 200, gh = 120
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: gw, height: gh))
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 8192))
        engine.uploadTemperatures([Float](repeating: ambient, count: gw * gh))
        let dt: Float = 1.0 / 60.0
        for _ in 0..<frames {
            particles.emitTop(count: 8)
            particles.integrate(dt: dt)
            particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding, columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)
            engine.step(dt: dt)
        }
        let cells = engine.readback()
        var snow = 0, water = 0, maxH = 0
        for x in 0..<gw {
            var colH = 0
            for y in 0..<gh {
                let sp = FallingSandCell.species(cells[y * gw + x])
                if sp == .snow { snow += 1; colH = y + 1 }
                else if sp == .water { water += 1; colH = y + 1 }
            }
            maxH = max(maxH, colH)
        }
        return (snow, water, maxH)
    }

    @Test("夏季气温雪即融成水（根因复现）：ambient 0.83 vs 0.20")
    func summerTempMeltsSnow() throws {
        let hot = try runAndCount(ambient: 0.83, frames: 1200)    // ~30°C 夏季
        let cold = try runAndCount(ambient: 0.20, frames: 1200)   // ~ -8°C 冬季
        print("\n=== ambient=0.83(夏,~30°C) snow=\(hot.snow) water=\(hot.water) 最高堆=\(hot.maxPileHeight) ===")
        print("=== ambient=0.20(冷,~-8°C) snow=\(cold.snow) water=\(cold.water) 最高堆=\(cold.maxPileHeight) ===\n")
        // 冷：几乎全 snow，无 water。热：大量 water（融化），snow 极少。
        #expect(cold.snow > cold.water * 5)        // 冷态以雪为主
        #expect(hot.water > hot.snow)              // 热态以水为主（融化证实）
    }
}
