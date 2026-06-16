import Testing
import Metal
import Foundation
@testable import SandboxPhysics

/// 全屏 2px 网格性能实测：批处理 step（单 command buffer）下，~53 万 cell 的
/// 每帧 step 耗时。判 2px 加密是否撑得住 60fps（<16ms）/ 30fps（<33ms）。
@Suite("FallingSandGPU 性能")
struct FallingSandPerfTests {
    @Test("全屏 2px step 计时（53 万 cell）")
    func fullScreen2pxStepTiming() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        // 1800×1169 点 / 2px ≈ 900×585
        let w = 900, h = 585
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        engine.uploadTemperatures([Float](repeating: 0.2, count: w * h))
        // 预热 + 铺一些雪让 step 有真实负载
        for _ in 0..<60 {
            engine.spawnTopRow(.snow, fillRatio: 0.05)
            engine.step(dt: 1.0 / 30.0)
        }
        let iterations = 60
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            engine.spawnTopRow(.snow, fillRatio: 0.05)
            engine.step(dt: 1.0 / 30.0)
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let perStepMs = elapsedMs / Double(iterations)
        print("[FS-PERF] full-screen 2px (\(w)×\(h)=\(w*h) cells) step avg = \(String(format: "%.2f", perStepMs)) ms")
        // 宽松上限：< 33ms（30fps 可行）。若超 → 2px 太重，需上粒子混合或进一步优化。
        #expect(perStepMs < 33.0)
    }

    @Test("全屏 1px step 计时（210 万 cell）— 决定 H0 去阻塞力度")
    func fullScreen1pxStepTiming() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        // 1800×1169 点 / 1px ≈ 当前 app 生产配置
        let w = 1800, h = 1169
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        engine.uploadTemperatures([Float](repeating: 0.2, count: w * h))
        for _ in 0..<30 {
            engine.spawnTopRow(.snow, fillRatio: 0.012)
            engine.step(dt: 1.0 / 30.0)
        }
        let iterations = 60
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            engine.spawnTopRow(.snow, fillRatio: 0.012)
            engine.step(dt: 1.0 / 30.0)
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let perStepMs = elapsedMs / Double(iterations)
        print("[FS-PERF] full-screen 1px (\(w)×\(h)=\(w*h) cells) step avg = \(String(format: "%.2f", perStepMs)) ms" +
              "  [<8ms=阻塞OK / 8-16ms=临界 / >16ms=H0必做]")
        // 含 CPU waitUntilCompleted 同步阻塞的端到端单帧耗时。判 60fps（<16ms）可行性。
        #expect(perStepMs < 33.0)
    }
}
