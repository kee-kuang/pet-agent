import Testing
import Metal
@testable import SandboxPhysics

/// 雨 = 一等公民 water 物理：雨粒子（kind=1）落地沉积成 FS water cell → FS 水漫流
/// 成水洼；温度耦合自然成立——温和天保持液态、冷天冻成冰。
@Suite("FallingSand 雨->水")
struct FallingSandRainTests {
    private func run(ambient: Float, frames: Int) throws -> (snow: Int, water: Int, ice: Int, steam: Int) {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 160, gh = 120
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: gw, height: gh))
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 8192))
        engine.uploadTemperatures([Float](repeating: ambient, count: gw * gh))
        let dt: Float = 1.0 / 60.0
        for _ in 0..<frames {
            particles.emitTop(count: 10, kind: 1)   // 雨
            particles.integrate(dt: dt)
            particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding, columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)
            engine.step(dt: dt)
        }
        let cells = engine.readback()
        var snow = 0, water = 0, ice = 0, steam = 0
        for c in cells {
            switch FallingSandCell.species(c) {
            case .snow: snow += 1
            case .water: water += 1
            case .ice: ice += 1
            case .steam: steam += 1
            default: break
            }
        }
        return (snow, water, ice, steam)
    }

    @Test("温和天（ambient 0.53 约= 强制 rainy 12C）：雨沉积成水、保持液态成水洼")
    func rainFormsLiquidPuddlesInMildWeather() throws {
        let r = try run(ambient: 0.53, frames: 600)   // 0.42 < 0.53 < 0.85 -> 不冻不蒸
        #expect(r.water > 200)        // 大量水洼
        #expect(r.snow == 0)          // 雨不是雪
        #expect(r.water > r.ice * 3)  // 以液态为主
    }

    @Test("冷天（ambient 0.20）：雨落地结冰（温度耦合）")
    func rainFreezesToIceInColdWeather() throws {
        let r = try run(ambient: 0.20, frames: 600)   // < freezeThreshold 0.42 -> water->ice
        #expect(r.ice > 100)          // 结冰
        #expect(r.ice > r.water)      // 以冰为主
    }
}
