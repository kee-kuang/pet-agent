import Testing
import Metal
@testable import SandboxPhysics

/// GPU 完整 step（移动 + 相变）的集成 + 视觉自评。dump PNG 供人/Claude 看，
/// 对照 CPU 版 `/tmp/fallingsand_snow.png` 形态。
@Suite("FallingSandGPU 完整 step 视觉")
struct FallingSandGPUVisualTests {
    @Test("GPU 降雪 200 帧 → 底部积雪 + dump PNG")
    func gpuSnowfallDump() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 80, h = 60
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.uploadTemperatures([Float](repeating: 0.2, count: w * h))   // 低温：雪不融
        for f in 0..<200 {
            if f < 130 { gpu.spawnTopRow(.snow, fillRatio: 0.15) }
            gpu.step(dt: 1.0 / 30.0)
        }
        let cells = gpu.readback()
        var grid = FallingSandGrid(width: w, height: h)
        grid.cells = cells
        FallingSandPNG.dump(grid, to: "/tmp/fallingsand_gpu_snow.png")
        // 底部有积雪
        var bottomSnow = 0
        for x in 0..<w where FallingSandCell.species(grid.at(x, 0)) == .snow { bottomSnow += 1 }
        #expect(bottomSnow > 0)
    }
}
