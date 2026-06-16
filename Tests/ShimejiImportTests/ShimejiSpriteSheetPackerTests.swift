import Testing
import CoreGraphics
import Foundation
@testable import ShimejiImport

@Suite("ShimejiSpriteSheetPacker")
struct ShimejiSpriteSheetPackerTests {

    // MARK: - fixtures

    /// 纯色帧（R 通道编码帧号 N → 拼装后按中心像素 R 解出来源帧，验证映射 + Y 摆放）。
    private func solidFrame(r: UInt8, w: Int = 128, h: Int = 128) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: 128.0 / 255, blue: 64.0 / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 左右异色帧（左半 R=leftR，右半 R=rightR）→ 验证左向行水平翻转。
    private func splitFrame(leftR: UInt8, rightR: UInt8, w: Int = 128, h: Int = 128) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(leftR) / 255, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(red: CGFloat(rightR) / 255, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return ctx.makeImage()!
    }

    /// 把 packed sheet 渲进全尺寸 RGBA 缓冲，返回按「图顶左原点」取像素的闭包（与
    /// SpriteSheetPetRenderer 的 cropping 同系：row 0 在顶）。
    private func sampler(for sheet: CGImage) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = sheet.width, h = sheet.height
        let bpr = w * 4
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(sheet, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 闭包必须捕获 ctx 本身(而非裸指针)—— 否则 ctx 释放后 backing buffer 被回收,
        // 指针悬垂 → 读取段错误(SIGSEGV)。在闭包内取 data 让 ctx 随闭包存活。
        return { [ctx] xFromLeft, yFromTop in
            let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: bpr * h)
            let i = yFromTop * bpr + xFromLeft * 4
            return (ptr[i], ptr[i + 1], ptr[i + 2], ptr[i + 3])
        }
    }

    private let fw = ShimejiPetdexLayout.frameWidth   // 192
    private let fh = ShimejiPetdexLayout.frameHeight  // 208

    /// cell (row, col) 中心像素（图顶左原点）。
    private func cellCenter(_ row: Int, _ col: Int) -> (Int, Int) {
        (col * fw + fw / 2, row * fh + fh / 2)
    }

    // MARK: - tests

    @Test("空帧 → 抛 noFrames")
    func emptyThrows() {
        #expect(throws: ShimejiSpriteSheetPacker.PackError.noFrames) {
            _ = try ShimejiSpriteSheetPacker.pack(frames: [:])
        }
    }

    @Test("8×9 尺寸 + 映射表正确摆帧（含 Y 行序与 renderer cropping 一致）")
    func packsMappingAndLayout() throws {
        // 46 帧,R = 帧号(N≤46<256 → 中心 R 可解出来源帧)。
        var frames: [Int: CGImage] = [:]
        for n in 1...ShimejiFrameMapping.standardFrameCount { frames[n] = solidFrame(r: UInt8(n)) }
        let sheet = try ShimejiSpriteSheetPacker.pack(frames: frames)
        #expect(sheet.width == ShimejiPetdexLayout.sheetWidth)    // 8*192=1536
        // 全 46 帧含 shime12-14 → climb 行(row 9)生成 → 10 行 = 10*208=2080。
        #expect(sheet.height == 10 * fh)
        let px = sampler(for: sheet)

        // row 0 idle ← [1]
        let (x0, y0) = cellCenter(0, 0); #expect(px(x0, y0).r == 1)
        // row 1 runningRight ← [1,2,3]
        #expect(px(cellCenter(1, 0).0, cellCenter(1, 0).1).r == 1)
        #expect(px(cellCenter(1, 1).0, cellCenter(1, 1).1).r == 2)
        #expect(px(cellCenter(1, 2).0, cellCenter(1, 2).1).r == 3)
        // row 4 jumping ← [22,4]
        #expect(px(cellCenter(4, 0).0, cellCenter(4, 0).1).r == 22)
        #expect(px(cellCenter(4, 1).0, cellCenter(4, 1).1).r == 4)
        // row 8 review ← [26,15,16,17]（验证 Y 行序正确,row 0 顶 row 9 底）
        #expect(px(cellCenter(8, 0).0, cellCenter(8, 0).1).r == 26)
        #expect(px(cellCenter(8, 3).0, cellCenter(8, 3).1).r == 17)
        // row 9 climbing ← [12,13,14]（攀爬专用行落在图底）
        #expect(px(cellCenter(9, 0).0, cellCenter(9, 0).1).r == 12)
        #expect(px(cellCenter(9, 1).0, cellCenter(9, 1).1).r == 13)
        #expect(px(cellCenter(9, 2).0, cellCenter(9, 2).1).r == 14)
        // 空 cell（row 0 只有 1 帧 → col 1 透明）
        #expect(px(cellCenter(0, 1).0, cellCenter(0, 1).1).a == 0)
    }

    @Test("无 shime12-14 → climb 行省略,sheet 缩回 9 行(不留空透明行)")
    func climbRowOmittedWhenSourceFramesMissing() throws {
        // 给齐 1-11(够拼 row 0-8),但缺 12-14(climb 源帧)→ climb 行整行省略。
        var frames: [Int: CGImage] = [:]
        for n in 1...11 { frames[n] = solidFrame(r: UInt8(n)) }
        let sheet = try ShimejiSpriteSheetPacker.pack(frames: frames)
        #expect(sheet.height == 9 * fh)   // 9 行,无 climb 空行
        #expect(ShimejiSpriteSheetPacker.effectiveRows(frames: frames) == 9)
    }

    @Test("有 shime12-14 → effectiveRows = 10(含 climb)")
    func effectiveRowsTenWithClimbFrames() throws {
        var frames: [Int: CGImage] = [1: solidFrame(r: 1)]
        frames[12] = solidFrame(r: 12)   // 至少一帧 climb 源 → 行保留
        #expect(ShimejiSpriteSheetPacker.effectiveRows(frames: frames) == 10)
    }

    @Test("左向行(row2)由右向帧水平翻转生成")
    func runningLeftIsMirrored() throws {
        // 帧 1 = 左 R=200 / 右 R=50。row1(右向不翻) vs row2(左向翻)。
        var frames: [Int: CGImage] = [1: splitFrame(leftR: 200, rightR: 50)]
        frames[2] = splitFrame(leftR: 200, rightR: 50)
        frames[3] = splitFrame(leftR: 200, rightR: 50)
        let sheet = try ShimejiSpriteSheetPacker.pack(frames: frames)
        let px = sampler(for: sheet)
        let leftQ = fw / 4, rightQ = fw * 3 / 4
        // row1 col0 不翻:左四分位≈200,右四分位≈50。
        #expect(px(0 * fw + leftQ, 1 * fh + fh / 2).r > 150)
        #expect(px(0 * fw + rightQ, 1 * fh + fh / 2).r < 100)
        // row2 col0 翻转:左右互换。
        #expect(px(0 * fw + leftQ, 2 * fh + fh / 2).r < 100)
        #expect(px(0 * fw + rightQ, 2 * fh + fh / 2).r > 150)
    }

    @Test("缺帧回退到 fallbackFrame(1)")
    func missingFrameFallsBack() throws {
        // 只给 frame 1（R=1），缺 frame 2/3 → row1 col1/col2 回退 frame1。
        let frames: [Int: CGImage] = [1: solidFrame(r: 1)]
        let sheet = try ShimejiSpriteSheetPacker.pack(frames: frames)
        let px = sampler(for: sheet)
        #expect(px(cellCenter(1, 0).0, cellCenter(1, 0).1).r == 1)
        #expect(px(cellCenter(1, 1).0, cellCenter(1, 1).1).r == 1)  // 回退
        #expect(px(cellCenter(1, 2).0, cellCenter(1, 2).1).r == 1)  // 回退
    }

    @Test("petJSON 含 slug/displayName/source 且可解析")
    func petJSONValid() throws {
        let data = ShimejiSpriteSheetPacker.petJSON(slug: "neko", displayName: "小猫")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["slug"] as? String == "neko")
        #expect(obj["displayName"] as? String == "小猫")
        #expect(obj["source"] as? String == "shimeji")
        #expect(obj["frameWidth"] as? Int == ShimejiPetdexLayout.frameWidth)
        #expect(obj["rows"] as? Int == ShimejiPetdexLayout.rows)
    }

    @Test("petJSON 无包归属时不写 packId/packName/siblings(向后兼容)")
    func petJSONNoPackByDefault() throws {
        let data = ShimejiSpriteSheetPacker.petJSON(slug: "neko", displayName: "小猫")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["packId"] == nil)
        #expect(obj["packName"] == nil)
        #expect(obj["siblings"] == nil)
    }

    @Test("petJSON 带包归属时写 packId/packName/siblings")
    func petJSONWithPack() throws {
        let data = ShimejiSpriteSheetPacker.petJSON(
            slug: "blue", displayName: "Blue", packId: "alan-pack",
            packName: "Alan's Stickfigures", siblings: ["blue", "red", "green"])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["packId"] as? String == "alan-pack")
        #expect(obj["packName"] as? String == "Alan's Stickfigures")
        #expect((obj["siblings"] as? [String]) == ["blue", "red", "green"])
    }
}
