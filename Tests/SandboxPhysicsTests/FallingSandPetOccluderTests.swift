import Testing
import Metal
@testable import SandboxPhysics

/// pet 第二 occluder（雪堆 pet 身上）离屏确定性验收。
/// FS overlay 截图抓不到（见 memory petagent-overlay-not-screencapturable），
/// 故用离屏 grid readback 断言物理：雪堆在 pet 轮廓顶上、pet 内部被清、Y 朝向正确。
@Suite("FallingSandGPU pet occluder")
struct FallingSandPetOccluderTests {

    /// 确定性物理：雪概率门全开、升华关、低温不融 → 雪只受 occluder 影响。
    private func makeEngine(_ w: Int, _ h: Int) throws -> FallingSandGPUEngine {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gpu = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        gpu.uploadTemperatures([Float](repeating: 0.2, count: w * h))   // 冷：不融
        gpu.tuning.snowFallProbability = 1.0                            // 每帧必落（确定性）
        gpu.tuning.snowSublimatePerSec = 0                              // 关升华（隔离 occluder）
        gpu.tuning.snowDepthSublimateCoeff = 0
        return gpu
    }

    private func snowCount(_ cells: [UInt32], w: Int, xRange: Range<Int>, yRange: Range<Int>) -> Int {
        var n = 0
        for y in yRange where y >= 0 && y < cells.count / w {
            for x in xRange where x >= 0 && x < w {
                if FallingSandCell.species(cells[y * w + x]) == .snow { n += 1 }
            }
        }
        return n
    }

    /// pet mask：顶半不透明（row 0..topRows-1=255），底半透明（0）。row 0 = sprite 顶部
    /// （CGImage 行序）。验证 Y 翻转：顶半应映射到 world 高 y（occluder 在 pet 上半）。
    private func halfOpaqueMask(w: Int, h: Int, topRows: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: w * h)
        for my in 0..<topRows {
            for mx in 0..<w { mask[my * w + mx] = 255 }
        }
        return mask
    }

    @Test("雪堆在 pet 轮廓顶上 + pet 内部被清 + Y 翻转正确")
    func snowPilesOnPetTop() throws {
        let w = 24, h = 40
        let gpu = try makeEngine(w, h)
        // pet mask 8×12，顶 6 行不透明。origin (8,10)。kernel 翻转：
        //   opaque my∈[0,6) → world y = 10 + (12-1-my) = 21..16 → occluder x∈[8,16), y∈[16,21]
        //   透明 my∈[6,12) → world y 15..10 → 不遮挡
        let maskW = 8, maskH = 12
        gpu.uploadPetMask(halfOpaqueMask(w: maskW, h: maskH, topRows: 6),
                          originCellX: 8, originCellY: 10, w: maskW, h: maskH)
        // 在 pet 列上方撒两排雪（x∈[8,16)），让它落下堆积。
        var cells = [UInt32](repeating: 0, count: w * h)
        for y in 34..<36 {
            for x in 8..<16 { cells[y * w + x] = FallingSandCell.make(.snow, ra: 100) }
        }
        gpu.upload(cells)
        for _ in 0..<120 { gpu.step(dt: 1.0 / 60.0) }
        let after = gpu.readback()

        // 1. 雪堆在 occluder 顶上（world y≥22，刚好压在最高遮挡行 y=21 之上）。
        #expect(snowCount(after, w: w, xRange: 8..<16, yRange: 22..<28) > 0)
        // 2. pet 内部（occluder cell y∈[16,21]）每帧被清 → 无雪。
        #expect(snowCount(after, w: w, xRange: 8..<16, yRange: 16..<21) == 0)
        // 3. Y 翻转正确：若翻转反了，occluder 会落在 world y 10..15，雪会停在 y16
        //    而 y≥22 为空。上面两条已隐含证明雪停在 pet 上半（高 y）= 翻转正确。
    }

    @Test("关闭 occluder → 雪穿过 pet 占位落到地面（对照组）")
    func disabledOccluderLetsSnowFall() throws {
        let w = 24, h = 40
        let gpu = try makeEngine(w, h)
        let maskW = 8, maskH = 12
        gpu.uploadPetMask(halfOpaqueMask(w: maskW, h: maskH, topRows: 6),
                          originCellX: 8, originCellY: 10, w: maskW, h: maskH)
        gpu.disablePetOccluder()   // 上传后立即关 → step 跳过 fs_rasterize_pet
        var cells = [UInt32](repeating: 0, count: w * h)
        for y in 34..<36 {
            for x in 8..<16 { cells[y * w + x] = FallingSandCell.make(.snow, ra: 100) }
        }
        gpu.upload(cells)
        for _ in 0..<160 { gpu.step(dt: 1.0 / 60.0) }
        let after = gpu.readback()
        // 雪落到地面（y∈[0,4)），没在 pet 占位高度凭空堆住。
        #expect(snowCount(after, w: w, xRange: 8..<16, yRange: 0..<4) > 0)
        #expect(snowCount(after, w: w, xRange: 8..<16, yRange: 22..<28) == 0)
    }

    @Test("uploadPetMask 防御：mask 过小 / 尺寸非法 → 不崩、occluder 关")
    func uploadPetMaskGuards() throws {
        let w = 16, h = 16
        let gpu = try makeEngine(w, h)
        gpu.uploadPetMask([UInt8](repeating: 255, count: 4), originCellX: 0, originCellY: 0, w: 8, h: 8) // mask 太小
        gpu.uploadPetMask([], originCellX: 0, originCellY: 0, w: 0, h: 0)                                 // 空
        // 不崩即通过；step 不应因关掉的 occluder 出错。
        gpu.step(dt: 1.0 / 60.0)
    }
}
