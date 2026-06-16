import Testing
import Metal
@testable import SandboxPhysics

/// GPU atomic 认领移动 vs CPU 参考的逐格对拍。只比**确定性移动**（gravity
/// forced + flow，无相变、无雪概率门）—— 这部分两侧均无 RNG，必须逐格一致。
/// 相变/概率门用位置哈希 RNG（与 CPU 顺序流分歧），在别处测不变量。
@Suite("FallingSandGPU 对拍")
struct FallingSandGPUParityTests {
    /// 用同一个确定性 RNG 撒初始元素，返回 cell 数组（CPU/GPU 共用）。
    private func makeInitial(width: Int, height: Int, seed: UInt64,
                             species: FallingSandSpecies, region: Range<Int>) -> [UInt32] {
        var rng = FallingSandRandom(seed: seed)
        var cells = [UInt32](repeating: 0, count: width * height)
        for y in region {
            for x in 0..<width where rng.bool() {
                cells[y * width + x] = FallingSandCell.make(species, ra: UInt8(rng.int(256)))
            }
        }
        return cells
    }

    private func loadCPU(_ initial: [UInt32], width: Int, height: Int) -> FallingSandSimulation {
        var cpu = FallingSandSimulation(width: width, height: height, seed: 1)
        for i in 0..<initial.count { cpu.setCell(i % width, i / width, initial[i]) }
        return cpu
    }

    @Test("确定性下落多帧 GPU==CPU 逐格")
    func deterministicFallMatches() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 16
        let initial = makeInitial(width: w, height: h, seed: 7, species: .snow, region: (h / 2)..<h)
        var cpu = loadCPU(initial, width: w, height: h)
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(initial)
        for _ in 0..<24 {
            cpu.stepMovementOnly()
            gpu.stepMovementOnly()
        }
        #expect(gpu.readback() == cpu.grid.cells)
    }

    @Test("一柱雪塌坡 GPU==CPU 逐格")
    func columnCollapseMatches() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 21, h = 16
        var initial = [UInt32](repeating: 0, count: w * h)
        for y in 0..<10 { initial[y * w + 10] = FallingSandCell.make(.snow, ra: 100) }
        var cpu = loadCPU(initial, width: w, height: h)
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(initial)
        for _ in 0..<40 {
            cpu.stepMovementOnly()
            gpu.stepMovementOnly()
        }
        #expect(gpu.readback() == cpu.grid.cells)
    }

    @Test("水柱漫流找平 GPU==CPU 逐格")
    func waterFlowMatches() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 17, h = 12
        var initial = [UInt32](repeating: 0, count: w * h)
        for y in 0..<4 { initial[y * w + 8] = FallingSandCell.make(.water, ra: 80) }
        var cpu = loadCPU(initial, width: w, height: h)
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(initial)
        for _ in 0..<40 {
            cpu.stepMovementOnly()
            gpu.stepMovementOnly()
        }
        #expect(gpu.readback() == cpu.grid.cells)
    }

    @Test("蒸汽上升 GPU==CPU 逐格")
    func steamRiseMatches() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 16
        let initial = makeInitial(width: w, height: h, seed: 13, species: .steam, region: 0..<(h / 2))
        var cpu = loadCPU(initial, width: w, height: h)
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(initial)
        for _ in 0..<24 {
            cpu.stepMovementOnly()
            gpu.stepMovementOnly()
        }
        #expect(gpu.readback() == cpu.grid.cells)
    }
}
