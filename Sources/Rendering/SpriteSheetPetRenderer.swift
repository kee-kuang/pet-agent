import AppKit
import QuartzCore
import RuntimeBridge

// MARK: - SpriteSheetPetRenderer
//
// 数据驱动 sprite 形象 —— 兼容 **Codex / petdex pet 包格式**：一张 `spritesheet`
// （8 列 × 9 行，每帧 192×208，行=状态、列=帧）。直接吃 `~/.codex/pets/{slug}/` 整个社区库。
//
// 不走 Metal：用 `CALayer.contents = CGImage.cropping(到当前帧)` 逐帧播放
// （CGImage 是 top-left 原点 → 行 0 在最上，无 Y 翻转坑），`magnificationFilter=.nearest`
// 保像素感。帧时序按 petdex 桌面运行时的 STATES 表（每帧可变 duration）。
//
// 状态行（9 行，参照 petdex 的 main.zig STATES 状态表重新实现，数据约定，未拷贝源码）：
//   0 idle / 1 running-right / 2 running-left / 3 waving / 4 jumping
//   / 5 failed / 6 waiting / 7 running / 8 review
// 本项目 `PetEmotionState`(5) + `SignatureAction` 映射到这些行。

@MainActor
public final class SpriteSheetPetRenderer: PetRenderer {

    public var contentLayer: CALayer { spriteLayer }

    private static let cols = SpritePackGeometry.cols

    private let sheet: CGImage
    private let frameW: CGFloat
    private let frameH: CGFloat
    /// 本 sheet 实际行数(几何推导:经典 8×9 → 9;带 climb 的 8×10 → 10)。
    private let sheetRows: Int
    /// 是否含专用 climb 行(row 9)。无则 `.climbing` 回退 running 镜像。
    private let hasClimbRow: Bool
    /// 每行实际非空帧数(从 col 0 起连续计)。Shimeji 转换包按映射表填,每行帧数常 < petdex
    /// STATES 假定的列数(如 idle 实 1 帧 vs def 播 6 帧)→ 播到透明空 cell 会「一帧有一帧无」闪烁。
    /// 据此把 play 帧序裁到真实帧、空 cell 不播(根治闪烁,且兼容任意稀疏社区包)。
    private let frameCounts: [Int]
    private let spriteLayer = CALayer()
    /// 淋湿:蓝色水渍层,叠在 sprite 上,用当前帧 alpha 作 mask → 只染 pet 像素。
    /// opacity 跟淋湿程度走(0 = 干)。
    private let wetTintLayer = CALayer()
    /// wetTintLayer 的 mask —— contents = 当前帧 CGImage,alpha 把蓝色裁成 pet 轮廓。
    private let wetMaskLayer = CALayer()
    /// 全湿时蓝色 tint 的最大不透明度(留克制,水渍是点缀不是糊一层蓝)。
    private static let maxWetTintAlpha: Float = 0.32
    private var wetness: Float = 0

    private var frameTimer: Timer?
    private var sequence: [Frame] = []
    private var frameIndex = 0
    /// 当前帧裁剪后的 CGImage（showFrame 写）—— alpha occluder mask 提取复用，免重裁。
    private var currentCropped: CGImage?
    /// alpha occluder mask 缓存：按当前帧标识 + mask 尺寸缓存，帧不变则直接返回（每行就几帧）。
    /// key 用 maskW/H（已由 cellSize 推导）而非 cellSize 原值 —— cellSize 运行时恒定
    /// （`fallingSandCellSize`），尺寸相同即可安全复用；接入可变 cellSize 时需把它纳入 key。
    private struct AlphaMaskKey: Equatable { let row: Int; let col: Int; let w: Int; let h: Int }
    private var cachedAlphaMaskKey: AlphaMaskKey?
    private var cachedAlphaMask: PetAlphaMask?
    private var currentFrameRow = 0
    private var currentFrameCol = 0
    private var currentState: PetEmotionState = .idle
    /// 当前空间运动态(walking 朝向 / idle / falling / perching)。
    /// 与情绪态(`currentState`)正交:运动态(走/落)优先,静止/perch 回落到情绪态。
    private var currentMotion: PetMotionPhase = .idle
    /// 正在播一次性招牌动作(`trigger`)—— 此间 motion/emotion 变化只记录不打断,
    /// 招牌播完再 `refreshLoopAnimation` 回到当前态。
    private var playingOneShot = false
    /// 当前循环播放的状态行 —— 只在它变化时才重播,避免每帧 updateForMotion reset 到第 0 帧。
    private var activeNamed: NamedState?
    private var paused = false

    private struct Frame { let col: Int; let row: Int; let durMs: Int }

    // MARK: - Init

    /// 失败返回 nil（图加载失败 / 尺寸不足 8×9）→ Shell fallback 到 placeholder。
    public init?(spritesheetURL: URL) {
        guard
            let image = NSImage(contentsOf: spritesheetURL),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            cg.width >= Self.cols, cg.height >= SpritePackGeometry.defaultRows
        else { return nil }
        self.sheet = cg
        let rows = SpritePackGeometry.rows(width: cg.width, height: cg.height)
        self.sheetRows = rows
        self.hasClimbRow = rows >= 10
        self.frameW = CGFloat(cg.width) / CGFloat(Self.cols)
        self.frameH = CGFloat(cg.height) / CGFloat(rows)
        self.frameCounts = Self.detectFrameCounts(sheet: cg, cols: Self.cols, rows: rows)

        spriteLayer.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .nearest   // 像素感
        spriteLayer.minificationFilter = .nearest

        // 淋湿:蓝色 tint 层 + sprite alpha mask(只染 pet 像素),初始全透明(干)。
        wetTintLayer.frame = spriteLayer.bounds
        wetTintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wetTintLayer.backgroundColor = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.95, alpha: 1).cgColor
        wetTintLayer.opacity = 0
        wetMaskLayer.frame = spriteLayer.bounds
        wetMaskLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wetMaskLayer.contentsGravity = .resizeAspect   // 与 spriteLayer 对齐
        wetMaskLayer.magnificationFilter = .nearest
        wetTintLayer.mask = wetMaskLayer
        spriteLayer.addSublayer(wetTintLayer)

        activeNamed = .idle
        play(named: .idle, loop: true)
    }

    deinit { frameTimer?.invalidate() }

    // MARK: - PetRenderer

    public func updateForState(_ state: PetEmotionState) {
        currentState = state
        refreshLoopAnimation()
    }

    /// 接 `PetMotionController` 每帧运动态。走/落切走帧行,静止/perch
    /// 回落情绪态。每帧调用,但 `refreshLoopAnimation` 只在行真变化时重播。
    public func updateForMotion(_ phase: PetMotionPhase) {
        currentMotion = phase
        applyClimbFlip(for: phase)
        refreshLoopAnimation()
    }

    /// climb 行源帧面右;`climbing(.left)`(贴右墙、面左)时水平翻转 spriteLayer 镜像之。
    /// 仅 climb 用翻转(running-left 是独立烘焙行,不翻);离开 climb 复位,否则其他行被镜像。
    private func applyClimbFlip(for phase: PetMotionPhase) {
        var flip = false
        if case .climbing(.left) = phase, hasClimbRow { flip = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.transform = flip ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// 淋湿程度 0..1 → 蓝色水渍层不透明度。每帧调用,无隐式动画
    /// (CATransaction 关)避免 opacity 渐变拖尾;变化微小则跳过省事。
    public func updateForWetness(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        guard abs(clamped - wetness) > 0.001 else { return }
        wetness = clamped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wetTintLayer.opacity = clamped * Self.maxWetTintAlpha
        CATransaction.commit()
    }

    /// 测试钩子(@testable):当前湿渍层不透明度。
    var wetTintOpacityForTesting: Float { wetTintLayer.opacity }

    /// 当前帧 alpha 轮廓 mask（喂 falling-sand pet occluder，雪堆身上）。
    /// pet 占位 = host view 尺寸（72×72）；按 cellSize 下采样到 footprint cell 数（cellSize=1
    /// → 72×72），单边 clamp 到 maxDim。当前帧裁剪图按 `.resizeAspect`（与 spriteLayer 同）
    /// 画进 RGBA context，取 alpha 通道。**row 0 = sprite 顶部**（CGImage 行序，Y 翻转在
    /// GPU kernel 内）。按当前帧 + 尺寸缓存：帧不变直接返回（每行就几帧，免每帧重绘）。
    public func currentFrameAlphaMask(cellSize: Float, maxDim: Int) -> PetAlphaMask? {
        guard let cropped = currentCropped, cellSize > 0, maxDim > 0 else { return nil }
        let footW = max(1, Double(spriteLayer.bounds.width))
        let footH = max(1, Double(spriteLayer.bounds.height))
        let maskW = min(maxDim, max(1, Int((footW / Double(cellSize)).rounded(.up))))
        let maskH = min(maxDim, max(1, Int((footH / Double(cellSize)).rounded(.up))))
        let key = AlphaMaskKey(row: currentFrameRow, col: currentFrameCol, w: maskW, h: maskH)
        if key == cachedAlphaMaskKey, let cached = cachedAlphaMask { return cached }

        guard let mask = Self.extractAlpha(from: cropped, maskW: maskW, maskH: maskH) else { return nil }
        let result = PetAlphaMask(mask: mask, width: maskW, height: maskH)
        cachedAlphaMaskKey = key
        cachedAlphaMask = result
        return result
    }

    /// 把 sprite 帧 CGImage 按 aspect-fit 画进 maskW×maskH RGBA context，取 alpha 通道。
    /// aspect-fit 复刻 `spriteLayer.contentsGravity = .resizeAspect`，让 mask 与屏幕像素对齐。
    /// 用 RGBA premultipliedLast 而非 alphaOnly:Swift `CGContext` 的 `space` 是非可选,
    /// 与 alphaOnly 要求的 nil colorspace 冲突,RGBA 读 alpha 字节是务实正解(透明背景上
    /// 合成后 dst_alpha = src_alpha,预乘只影响 RGB 不影响 alpha 通道)。仅帧切换时跑(缓存)。
    private static func extractAlpha(from image: CGImage, maskW: Int, maskH: Int) -> [UInt8]? {
        let bytesPerRow = maskW * 4
        guard let ctx = CGContext(
            data: nil, width: maskW, height: maskH, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // aspect-fit：sprite 帧（imgW×imgH）缩放居中进 maskW×maskH 框（同 .resizeAspect）。
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let scale = min(CGFloat(maskW) / imgW, CGFloat(maskH) / imgH)
        let drawW = imgW * scale, drawH = imgH * scale
        let drawRect = CGRect(x: (CGFloat(maskW) - drawW) / 2, y: (CGFloat(maskH) - drawH) / 2, width: drawW, height: drawH)
        ctx.draw(image, in: drawRect)
        guard let base = ctx.data else { return nil }
        let ptr = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * maskH)
        var mask = [UInt8](repeating: 0, count: maskW * maskH)
        // CGContext 缓冲 row 0 = 顶行（与 kernel 约定一致，不翻转）。取每像素 alpha 字节。
        for y in 0..<maskH {
            let rowBase = y * bytesPerRow
            for x in 0..<maskW { mask[y * maskW + x] = ptr[rowBase + x * 4 + 3] }
        }
        return mask
    }

    public func pauseDisplayLink() {
        paused = true
        frameTimer?.invalidate()
        frameTimer = nil
    }

    public func resumeDisplayLink() {
        guard paused else { return }
        paused = false
        activeNamed = nil // 强制重播当前态(暂停时 timer 已停)
        refreshLoopAnimation()
    }

    public var supportedSignatures: Set<SignatureAction> {
        [.celebrate, .greet, .acknowledge, .refuse, .reactToDragEnd]
    }

    public func trigger(_ signature: SignatureAction) {
        guard let named = Self.namedState(forSignature: signature) else { return }
        // 一次性播完招牌动作 → 回到当前运动/情绪态循环。其间 updateForMotion/State
        // 只记录不打断(playingOneShot 闸)。
        playingOneShot = true
        activeNamed = nil
        play(named: named, loop: false) { [weak self] in
            guard let self else { return }
            self.playingOneShot = false
            self.refreshLoopAnimation()
        }
    }

    // MARK: - 循环动画仲裁(运动态优先于情绪态)

    /// 据当前运动态 + 情绪态算出该循环播放的状态行,只在它变化时重播。
    private func refreshLoopAnimation() {
        guard !paused, !playingOneShot else { return }
        let named = effectiveNamed()
        guard named != activeNamed else { return }
        activeNamed = named
        play(named: named, loop: true)
    }

    /// 运动态(走/落)优先;静止 / perch 回落到情绪态行。
    private func effectiveNamed() -> NamedState {
        switch currentMotion {
        case .walking(.right): return .runningRight
        case .walking(.left):  return .runningLeft
        case .climbing(let facing):
            // 有专用 climb 行(8×10 包,如 Shimeji shime12-14)→ 走真攀爬帧(朝向靠 layer 翻转);
            // 经典 8×9 包无 climb 行 → 回退 running 帧镜像。
            return hasClimbRow ? .climbing : (facing == .right ? .runningRight : .runningLeft)
        case .falling:         return .jumping   // 空中姿态(petdex 无独立 falling 行)
        case .perching, .idle: return Self.namedState(for: currentState)
        }
    }

    /// 测试钩子(@testable 可见):当前循环播放的 sprite 行索引。
    /// 0 idle / 1 runningRight / 2 runningLeft / 3 waving / 4 jumping / 5 failed
    /// / 6 waiting / 7 running / 8 review。行选择在 `play` 内同步定,不依赖帧定时器。
    var currentRowForTesting: Int { sequence.first?.row ?? -1 }

    /// 测试钩子(@testable):当前播放序列帧数(已裁到本行真实非空帧 → 验证稀疏包不播空帧防闪烁)。
    var currentSequenceCountForTesting: Int { sequence.count }

    // MARK: - Playback

    private func play(named: NamedState, loop: Bool, completion: (() -> Void)? = nil) {
        guard !paused else { completion?(); return }
        let def = Self.defs[named] ?? Self.defs[.idle]!
        // 裁到本行真实帧数:Shimeji 转换包每行帧数 < def 假定列数,播空 cell 会闪烁。
        // 帧按 col 0 起连续填,故 col < realCount 即真实帧;裁空则至少留首帧(静止,不闪)。
        let realCount = def.row < frameCounts.count ? frameCounts[def.row] : Self.cols
        let frames = def.frames.filter { $0.col < realCount }
        let effective = frames.isEmpty ? Array(def.frames.prefix(1)) : frames
        sequence = effective.map { Frame(col: $0.col, row: def.row, durMs: $0.durMs) }
        frameIndex = 0
        showFrame()
        schedule(loop: loop, completion: completion)
    }

    /// 启动时检测每行实际非空帧数(从 col 0 连续计,首个全透明 cell 即截止)。把 sheet 渲进 RGBA
    /// 缓冲扫 alpha;检测失败保守按满列(`cols`,不改变现状)。一次性,与帧裁剪配合根治稀疏包闪烁。
    private static func detectFrameCounts(sheet: CGImage, cols: Int, rows: Int) -> [Int] {
        let W = sheet.width, H = sheet.height, bpr = W * 4
        guard W > 0, H > 0, let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Array(repeating: cols, count: rows) }
        ctx.draw(sheet, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let data = ctx.data else { return Array(repeating: cols, count: rows) }
        let ptr = data.bindMemory(to: UInt8.self, capacity: bpr * H)
        let fw = W / cols, fh = H / rows
        // cell (CGContext 缓冲 row 0 = 图顶,与 showFrame 的 CGImage top-left cropping 同系)
        // 内任一像素 alpha>16 即非空;稀疏采样(步长 4)够判,省扫整框。
        func hasContent(_ r: Int, _ c: Int) -> Bool {
            var y = r * fh
            while y < r * fh + fh {
                let base = y * bpr
                var x = c * fw
                while x < c * fw + fw { if ptr[base + x * 4 + 3] > 16 { return true }; x += 4 }
                y += 4
            }
            return false
        }
        return (0..<rows).map { r in
            var n = 0
            for c in 0..<cols { if hasContent(r, c) { n = c + 1 } else { break } }
            return max(1, n)   // 至少留首帧,避免整行空时序列为空
        }
    }

    private func showFrame() {
        guard frameIndex < sequence.count else { return }
        let f = sequence[frameIndex]
        // CGImage top-left 原点：行 0 在最上。
        let rect = CGRect(x: CGFloat(f.col) * frameW, y: CGFloat(f.row) * frameH, width: frameW, height: frameH)
        let cropped = sheet.cropping(to: rect)
        spriteLayer.contents = cropped
        // 湿渍 mask 跟随当前帧,蓝色 tint 始终裁在当前 pet 轮廓上。
        wetMaskLayer.contents = cropped
        // 记录当前帧（裁剪图 + 行列标识）供 alpha occluder mask 提取 + 缓存。
        currentCropped = cropped
        currentFrameRow = f.row
        currentFrameCol = f.col
    }

    private func schedule(loop: Bool, completion: (() -> Void)?) {
        frameTimer?.invalidate()
        guard sequence.count > 1 else { completion?(); return }
        let dur = Double(sequence[frameIndex].durMs) / 1000.0
        // Timer 回调是 Sendable，@MainActor 状态用 assumeIsolated hop（决策 #5）。
        frameTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.paused else { return }
                self.frameIndex += 1
                if self.frameIndex >= self.sequence.count {
                    if loop { self.frameIndex = 0 } else { completion?(); return }
                }
                self.showFrame()
                self.schedule(loop: loop, completion: completion)
            }
        }
    }

    // MARK: - 状态表（参照 petdex 的 main.zig STATES 状态表重新实现，数据约定，未拷贝源码）

    private enum NamedState {
        case idle, runningRight, runningLeft, waving, jumping, failed, waiting, running, review, climbing
    }

    private struct StateDef { let row: Int; let frames: [(col: Int, durMs: Int)] }

    private static func seq(_ count: Int, dur: Int, last: Int) -> [(Int, Int)] {
        (0..<count).map { ($0, $0 == count - 1 ? last : dur) }
    }

    private static let defs: [NamedState: StateDef] = [
        .idle:         StateDef(row: 0, frames: [(0, 280), (1, 110), (2, 110), (3, 140), (4, 140), (5, 320)]),
        .runningRight: StateDef(row: 1, frames: seq(8, dur: 120, last: 220)),
        .runningLeft:  StateDef(row: 2, frames: seq(8, dur: 120, last: 220)),
        .waving:       StateDef(row: 3, frames: seq(4, dur: 140, last: 280)),
        .jumping:      StateDef(row: 4, frames: seq(5, dur: 140, last: 280)),
        .failed:       StateDef(row: 5, frames: seq(8, dur: 140, last: 240)),
        .waiting:      StateDef(row: 6, frames: seq(6, dur: 150, last: 260)),
        .running:      StateDef(row: 7, frames: seq(6, dur: 120, last: 220)),
        .review:       StateDef(row: 8, frames: seq(6, dur: 150, last: 280)),
        // 攀爬专用行(row 9,仅 8×10 包):3 帧 hand-over-hand 循环(Shimeji shime12-14)。
        // 130ms/帧比 running 120 稍慢传「费力」感;源帧面右,climbing(.left) 由 layer 翻转。
        .climbing:     StateDef(row: 9, frames: [(0, 150), (1, 150), (2, 150)]),
    ]

    /// 本项目 5 情绪态 → Codex 状态行。
    private static func namedState(for state: PetEmotionState) -> NamedState {
        switch state {
        case .idle:     return .idle
        case .watching: return .waiting   // 待命踱步
        case .thinking: return .review     // 专注/审阅
        case .talking:  return .waving     // 招手/说话
        case .confused: return .failed     // 出错/困惑
        }
    }

    /// 招牌动作 → 一次性状态行。
    private static func namedState(forSignature sig: SignatureAction) -> NamedState? {
        switch sig {
        case .greet:       return .waving
        case .celebrate:   return .jumping
        case .acknowledge: return .waving
        case .refuse:      return .failed
        case .reactToDragEnd: return .failed   // item1:被拖完「晕」一下(复用 failed 行)
        case .signatureIdle: return nil
        }
    }
}
