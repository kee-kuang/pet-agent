import Testing
import Metal
@testable import SandboxPhysics

/// GPU 相变不变量测试。相变用位置哈希 RNG（与 CPU 顺序流分歧），不做逐位对拍，
/// 测「方向正确 + 守恒有界」这类不变量。
@Suite("FallingSandGPU 相变不变量")
struct FallingSandGPUPhaseTests {
    private func filled(_ w: Int, _ h: Int, _ s: FallingSandSpecies) -> [UInt32] {
        [UInt32](repeating: FallingSandCell.make(s, ra: 100), count: w * h)
    }

    private func species(_ cells: [UInt32]) -> [FallingSandSpecies] {
        cells.map { FallingSandCell.species($0) }
    }

    @Test("全局高温：雪 → 出现水/蒸汽")
    func hotSnowMeltsAndEvaporates() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 16
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(filled(w, h, .snow))
        gpu.uploadTemperatures([Float](repeating: 0.95, count: w * h))
        var sawSteam = false
        for _ in 0..<300 {
            gpu.stepPhaseOnly()
            if species(gpu.readback()).contains(.steam) { sawSteam = true; break }
        }
        #expect(sawSteam)
    }

    @Test("全局低温：水 → 出现冰")
    func coldWaterFreezes() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 16
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.upload(filled(w, h, .water))
        gpu.uploadTemperatures([Float](repeating: 0.1, count: w * h))
        var sawIce = false
        for _ in 0..<300 {
            gpu.stepPhaseOnly()
            if species(gpu.readback()).contains(.ice) { sawIce = true; break }
        }
        #expect(sawIce)
    }

    @Test("遮挡清除：窗口矩形盖住的雪被清掉（2D 遮挡）")
    func clearsOccludedSnow() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 20
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.uploadTemperatures([Float](repeating: 0.2, count: w * h))   // 冷：不融，隔离遮挡清除
        // 在 y=2..5 摆一柱雪（列 8）
        var cells = [UInt32](repeating: 0, count: w * h)
        for y in 2..<6 { cells[y * w + 8] = FallingSandCell.make(.snow, ra: 100) }
        gpu.upload(cells)
        // 窗口矩形盖住列 8 的 y∈[0,8)（FSRect x=8,y=0,w=1,h=8）→ y=2..5 的雪在窗口内
        gpu.uploadRects([FSRect(x: 8, y: 0, w: 1, h: 8)])
        gpu.step(dt: 1.0 / 60.0)
        let after = gpu.readback()
        // 列 8 在 y<8（窗口内）的雪应被清掉
        for y in 0..<8 {
            #expect(FallingSandCell.species(after[y * w + 8]) == .empty)
        }
    }

    @Test("2D 遮挡：悬浮窗下方开阔地照常积雪（区别于 1D floor 整列封锁）")
    func snowReachesGroundBelowFloatingWindow() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 16, h = 30
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.uploadTemperatures([Float](repeating: 0.2, count: w * h))
        // 悬浮窗：列 8，y∈[18,24)（高处小面板）。1D floor 会把列 8 整列 y<24 封锁 →
        // 下方地面不能积雪；2D 只封锁矩形内 y18..23，下方 y<18 是开阔地，雪能停。
        gpu.uploadRects([FSRect(x: 8, y: 18, w: 1, h: 6)])
        // 在窗口**下方**（列 8，y=8）放一柱雪 —— 应落到地面 y=0，不被遮挡清除。
        var cells = [UInt32](repeating: 0, count: w * h)
        for y in 8..<12 { cells[y * w + 8] = FallingSandCell.make(.snow, ra: 100) }
        gpu.upload(cells)
        for _ in 0..<60 { gpu.step(dt: 1.0 / 60.0) }
        let after = gpu.readback()
        // 窗口下方的雪落到地面（y=0..5 有雪，没被当成「窗口内」清掉）
        var groundSnow = 0
        for y in 0..<6 where FallingSandCell.species(after[y * w + 8]) == .snow { groundSnow += 1 }
        #expect(groundSnow > 0)
        // 窗口内（y 18..23）无雪
        for y in 18..<24 { #expect(FallingSandCell.species(after[y * w + 8]) == .empty) }
    }

    @Test("相变不凭空造占用：empty 永远不被填")
    func phaseNeverFillsEmpty() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 12, h = 12
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        // 棋盘：一半水一半空
        var cells = [UInt32](repeating: 0, count: w * h)
        for i in 0..<(w * h) where i % 2 == 0 { cells[i] = FallingSandCell.make(.water, ra: 100) }
        let occupiedBefore = cells.filter { !FallingSandCell.isEmpty($0) }.count
        gpu.upload(cells)
        gpu.uploadTemperatures([Float](repeating: 0.95, count: w * h))  // 高温 → 蒸发/消散
        for _ in 0..<100 { gpu.stepPhaseOnly() }
        let after = gpu.readback()
        // 相变只在占用 cell 上转换或消散 → 占用数非增（不会从 empty 造出元素）
        let occupiedAfter = after.filter { !FallingSandCell.isEmpty($0) }.count
        #expect(occupiedAfter <= occupiedBefore)
    }
}
