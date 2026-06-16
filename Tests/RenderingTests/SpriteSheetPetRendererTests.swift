import AppKit
import Testing
@testable import Rendering
import RuntimeBridge

@MainActor
@Suite("SpriteSheetPetRenderer")
struct SpriteSheetPetRendererTests {

    /// 画一张 `w×h` 像素的纯色 PNG 写临时文件，返回 URL。
    private func makeSheet(width: Int, height: Int) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprite-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    /// 画一张**稀疏** sheet:每行(图顶序)只填 `filled[r]` 个 cell(cols 0..<n),其余透明 —— 模拟
    /// Shimeji 转换包「每行帧数 < petdex 列数」。CGContext y-up:图顶 row r 在 context-y=H-(r+1)*fh。
    private func makeSparseSheet(cols: Int, rows: Int, frameW: Int, frameH: Int, filled: [Int]) throws -> URL {
        let W = cols * frameW, H = rows * frameH
        let ctx = try #require(CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))   // 透明底(默认清零)
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        for r in 0..<rows {
            let n = r < filled.count ? filled[r] : cols
            for c in 0..<n {
                ctx.fill(CGRect(x: c * frameW, y: H - (r + 1) * frameH, width: frameW, height: frameH))
            }
        }
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparse-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    @Test("稀疏包(每行帧数 < def 列数)→ play 裁到真实帧数,不播空 cell(根治闪烁)")
    func sparseSheetClampsToRealFrameCount() throws {
        // 模拟 Shimeji 转换包:idle(row0)1 帧、running-right(row1)3 帧。
        let url = try makeSparseSheet(cols: 8, rows: 9, frameW: 12, frameH: 13,
                                      filled: [1, 3, 3, 3, 2, 4, 2, 3, 4])
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        r.updateForMotion(.idle)              // idle def 6 帧,实 1 → 裁到 1(静止不闪)
        #expect(r.currentRowForTesting == 0)
        #expect(r.currentSequenceCountForTesting == 1)
        r.updateForMotion(.walking(.right))   // running-right def 8 帧,实 3 → 裁到 3
        #expect(r.currentRowForTesting == 1)
        #expect(r.currentSequenceCountForTesting == 3)
    }

    @Test("满帧包(petdex 全列)→ play 不裁,保留 def 全部帧(零回归)")
    func fullSheetKeepsAllDefFrames() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)   // 全填,每行 8 帧
        let r = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        r.updateForMotion(.idle)
        #expect(r.currentSequenceCountForTesting == 6)          // idle def 6 帧全留
        r.updateForMotion(.walking(.right))
        #expect(r.currentSequenceCountForTesting == 8)          // running def 8 帧全留
    }

    @Test("合法 8×9 spritesheet → init 成功，view 有尺寸，支持招牌动作")
    func initsFromValidSheet() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)   // 96×117，≥ 8×9 网格
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(renderer.contentLayer.frame.width > 0)
        #expect(renderer.supportedSignatures.contains(.celebrate))
        #expect(renderer.supportedSignatures.contains(.greet))
        // 切情绪态不崩（驱动 row 切换 + 帧定时器）。
        renderer.updateForState(.thinking)
        renderer.updateForState(.confused)
        renderer.pauseDisplayLink()
        renderer.resumeDisplayLink()
    }

    @Test("8×9 无 climb 行 → climbing 回退 running 镜像(right=row1 / left=row2)")
    func climbingFallsBackOnNineRowSheet() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)   // 几何推 9 行,无 climb 行
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.updateForMotion(.climbing(.right))
        #expect(renderer.currentRowForTesting == 1)              // 回退 runningRight
        renderer.updateForMotion(.climbing(.left))
        #expect(renderer.currentRowForTesting == 2)              // 回退 runningLeft
    }

    @Test("8×10 有 climb 行 → climbing 走专用 row9(朝向靠 layer 翻转,行不变)")
    func climbingUsesClimbRowOnTenRowSheet() throws {
        let url = try makeSheet(width: 8 * 12, height: 10 * 13)  // 几何推 10 行,含 climb 行
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.updateForMotion(.climbing(.right))
        #expect(renderer.currentRowForTesting == 9)             // 专用 climb 行
        renderer.updateForMotion(.climbing(.left))
        #expect(renderer.currentRowForTesting == 9)             // 仍 row9(左墙靠水平翻转,非换行)
    }

    @Test("updateForMotion 走帧切行 —— 向右=row1 / 向左=row2 / 下落=row4")
    func motionSwitchesWalkRows() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.updateForMotion(.walking(.right))
        #expect(renderer.currentRowForTesting == 1)
        renderer.updateForMotion(.walking(.left))
        #expect(renderer.currentRowForTesting == 2)
        renderer.updateForMotion(.falling)
        #expect(renderer.currentRowForTesting == 4)
    }

    @Test("运动态 idle 回落到情绪态行(idle=row0, thinking=row8 review)")
    func motionIdleFallsBackToEmotion() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.updateForMotion(.walking(.right))   // 先走起来 → row1
        #expect(renderer.currentRowForTesting == 1)
        renderer.updateForMotion(.idle)              // 停 → 回落情绪态 idle = row0
        #expect(renderer.currentRowForTesting == 0)
        renderer.updateForState(.thinking)           // 情绪 thinking → review row8
        #expect(renderer.currentRowForTesting == 8)
        renderer.updateForMotion(.walking(.left))    // 又走 → 运动态优先 row2
        #expect(renderer.currentRowForTesting == 2)
        renderer.updateForMotion(.idle)              // 停 → 回落到 thinking row8(情绪态保留)
        #expect(renderer.currentRowForTesting == 8)
    }

    @Test("updateForWetness 驱动水渍层不透明度(干=0,湿>0,clamp)")
    func wetnessDrivesTintOpacity() throws {
        let url = try makeSheet(width: 8 * 12, height: 9 * 13)
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        #expect(renderer.wetTintOpacityForTesting == 0)        // 初始干
        renderer.updateForWetness(1.0)
        #expect(renderer.wetTintOpacityForTesting > 0)         // 湿 → tint 上来
        let full = renderer.wetTintOpacityForTesting
        renderer.updateForWetness(0.5)
        #expect(renderer.wetTintOpacityForTesting < full)      // 半湿 < 全湿
        #expect(renderer.wetTintOpacityForTesting > 0)
        renderer.updateForWetness(0)
        #expect(renderer.wetTintOpacityForTesting == 0)        // 回干
        renderer.updateForWetness(5.0)                          // 越界 clamp 到 1
        #expect(renderer.wetTintOpacityForTesting == full)
    }

    @Test("currentFrameAlphaMask 提取当前帧 alpha 轮廓(非空 + aspect-fit letterbox + 缓存)")
    func alphaMaskExtractsCurrentFrame() throws {
        let url = try makeSheet(width: 8 * 24, height: 9 * 26)   // 帧 24×26，纯不透明 teal
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        // host view 72×72，cellSize=1 → mask 72×72。
        let m = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 128))
        #expect(m.width == 72 && m.height == 72)
        #expect(m.mask.count == 72 * 72)
        let opaque = m.mask.filter { $0 >= 128 }.count
        // 帧 24×26 aspect-fit 进 72×72 → 填满高度、宽度居中(留左右 letterbox)。
        #expect(opaque > 1000)                  // 真画出轮廓(非全透)
        #expect(opaque < 72 * 72)               // 有 letterbox(非铺满整框)
        // 缓存:同帧再取应等值(帧未变)。
        let m2 = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 128))
        #expect(m2 == m)
        // maxDim clamp:小 maxDim → mask 单边受限。
        let small = try #require(renderer.currentFrameAlphaMask(cellSize: 1.0, maxDim: 16))
        #expect(small.width == 16 && small.height == 16)
    }

    @Test("尺寸不足 8×9 → init 返回 nil（Shell 回退 placeholder）")
    func failsOnTinySheet() throws {
        let url = try makeSheet(width: 4, height: 4)
        #expect(SpriteSheetPetRenderer(spritesheetURL: url) == nil)
    }

    @Test("不存在的文件 → init 返回 nil")
    func failsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).png")
        #expect(SpriteSheetPetRenderer(spritesheetURL: url) == nil)
    }

    @Test("CodexSpritePackLoader.discover 不崩，返回的 id 都带 codex: 前缀")
    func discoverDoesNotCrash() {
        let entries = CodexSpritePackLoader.discover()   // 读真实 ~/.codex/pets/，可能空
        for e in entries {
            #expect(e.identity.id.hasPrefix("codex:"))
        }
    }

    /// 离屏渲染验证：把 renderer 的 layer 画进 bitmap，断言真有非透明像素落上去。
    /// 这是 overlay 截图抓不到（Metal/屏保）时的视觉验收手段，也防"加载成功但没画出来"。
    @Test("sprite 真画出像素（离屏 layer.render 非空）")
    func drawsNonBlankFrame() throws {
        let url = try makeSheet(width: 8 * 24, height: 9 * 26)   // 帧 24×26，纯 teal
        let renderer = try #require(SpriteSheetPetRenderer(spritesheetURL: url))
        renderer.contentLayer.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        let layer = renderer.contentLayer

        let w = 72, h = 72
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        layer.render(in: ctx)

        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var opaque = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where pixels[i + 3] > 0 { opaque += 1 }
        #expect(opaque > 0, "sprite layer 渲染出全透明 → 没画出帧")
    }
}
