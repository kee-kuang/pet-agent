import CoreGraphics
import Foundation

/// Shimeji 帧 → petdex 8×9 spritesheet 打包核心（纯函数，无 IO）。
/// 输入 `[N: CGImage]`（N = shimeN 的 1-based 号），按 `ShimejiFrameMapping` 选帧、
/// aspect-fit 进 192×208 cell、左向行水平翻转、拼 8×9 网格 → 输出 CGImage + pet.json。
/// CLI 壳（扫包 / 写 PNG）独立于此核心；此核心可合成 fixture 离屏测试。
public enum ShimejiSpriteSheetPacker {

    public enum PackError: Error, Equatable {
        case noFrames                 // 一张帧都没有
        case contextCreationFailed    // CGContext / makeImage 失败
    }

    /// 把 shimeN 帧拼成 8×9 petdex spritesheet。缺映射帧回退 `fallbackFrame`，
    /// 再缺则该 cell 透明。返回 CGImage 的 row 0 在顶（CGImage 行序，与
    /// `SpriteSheetPetRenderer` 的 `sheet.cropping` 消费约定一致）。
    public static func pack(frames: [Int: CGImage]) throws -> CGImage {
        guard !frames.isEmpty else { throw PackError.noFrames }
        let cellW = ShimejiPetdexLayout.frameWidth
        let cellH = ShimejiPetdexLayout.frameHeight
        let totalW = ShimejiPetdexLayout.sheetWidth

        // 可选行(climb)源帧全缺 → 整行省略(不 fallback 填站立帧,那比 renderer 回退 running 更假)。
        // 必选行始终保留。effectiveRows = 保留行最大号+1(9 经典 / 10 含 climb)。
        let specs = activeSpecs(frames: frames)
        let effectiveRows = (specs.map(\.row).max() ?? (ShimejiPetdexLayout.rows - 1)) + 1
        let totalH = effectiveRows * cellH

        guard let ctx = CGContext(
            data: nil, width: totalW, height: totalH, bitsPerComponent: 8,
            bytesPerRow: totalW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PackError.contextCreationFailed }
        // 透明底（CGContext 缓冲默认清零 = 全透明）。

        for spec in specs {
            // petdex row 0 在图顶；CGContext y-up → row r 的 cell 底边 context-y =
            // (effectiveRows-1-r)*cellH，使 row 0 落在图像顶部（与 renderer cropping 一致）。
            let cellBottomY = (effectiveRows - 1 - spec.row) * cellH
            for (col, frameN) in spec.frames.prefix(ShimejiPetdexLayout.cols).enumerated() {
                // 可选行不回退 fallback(缺帧的 cell 留透明,但整行至少有一帧才保留);必选行回退站立帧。
                let img = spec.optional ? frames[frameN] : (frames[frameN] ?? frames[ShimejiFrameMapping.fallbackFrame])
                guard let img else { continue }
                let cell = CGRect(x: col * cellW, y: cellBottomY, width: cellW, height: cellH)
                draw(img, into: ctx, cell: cell, flip: spec.flipHorizontally)
            }
        }
        guard let out = ctx.makeImage() else { throw PackError.contextCreationFailed }
        return out
    }

    /// 从「已 resolve 的每行有序帧」直接拼 sheet(actions.xml 解析路径用)。
    /// 各行帧已是 CGImage(按动作 Pose 序加载);空帧行省略,effectiveRows = 非空行最大号+1。
    /// 与 `pack(frames:)` 共用 `draw`(aspect-fit 居中 + 可选水平翻转)。row 0 在图顶(同 cropping 约定)。
    public static func packRows(_ rows: [(row: Int, frames: [CGImage], flip: Bool)]) throws -> CGImage {
        let nonEmpty = rows.filter { !$0.frames.isEmpty }
        guard !nonEmpty.isEmpty else { throw PackError.noFrames }
        let cellW = ShimejiPetdexLayout.frameWidth, cellH = ShimejiPetdexLayout.frameHeight
        let effRows = (nonEmpty.map(\.row).max() ?? (ShimejiPetdexLayout.rows - 1)) + 1
        guard let ctx = CGContext(
            data: nil, width: ShimejiPetdexLayout.sheetWidth, height: effRows * cellH,
            bitsPerComponent: 8, bytesPerRow: ShimejiPetdexLayout.sheetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PackError.contextCreationFailed }
        for r in nonEmpty {
            let cellBottomY = (effRows - 1 - r.row) * cellH   // row 0 落图顶(CGContext y-up)
            for (col, img) in r.frames.prefix(ShimejiPetdexLayout.cols).enumerated() {
                draw(img, into: ctx,
                     cell: CGRect(x: col * cellW, y: cellBottomY, width: cellW, height: cellH),
                     flip: r.flip)
            }
        }
        guard let out = ctx.makeImage() else { throw PackError.contextCreationFailed }
        return out
    }

    /// actions.xml 路径的实际行数(供 pet.json 报真实行数)。
    public static func effectiveRows(rows: [(row: Int, frames: [CGImage], flip: Bool)]) -> Int {
        (rows.filter { !$0.frames.isEmpty }.map(\.row).max() ?? (ShimejiPetdexLayout.rows - 1)) + 1
    }

    /// 实际参与拼图的行:必选行全留;可选行(climb)仅当至少一源帧存在才留(否则整行省略,sheet 缩回)。
    static func activeSpecs(frames: [Int: CGImage]) -> [ShimejiFrameMapping.RowSpec] {
        ShimejiFrameMapping.rows.filter { spec in
            guard spec.optional else { return true }
            return spec.frames.contains { frames[$0] != nil }
        }
    }

    /// 给定可用帧,sheet 实际行数(9 经典 / 10 含 climb)。供 pet.json 报告真实行数。
    public static func effectiveRows(frames: [Int: CGImage]) -> Int {
        (activeSpecs(frames: frames).map(\.row).max() ?? (ShimejiPetdexLayout.rows - 1)) + 1
    }

    /// aspect-fit 一帧进 cell（保持比例居中，复刻 spriteLayer `.resizeAspect`），
    /// flip=true 时绕 cell 中心水平镜像（左向行由右向帧翻转生成）。
    private static func draw(_ img: CGImage, into ctx: CGContext, cell: CGRect, flip: Bool) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let scale = min(cell.width / iw, cell.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dst = CGRect(x: cell.minX + (cell.width - dw) / 2,
                         y: cell.minY + (cell.height - dh) / 2,
                         width: dw, height: dh)
        ctx.saveGState()
        if flip {
            ctx.translateBy(x: cell.midX, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.translateBy(x: -cell.midX, y: 0)
        }
        ctx.draw(img, in: dst)
        ctx.restoreGState()
    }

    /// petdex `pet.json`（最小必要字段）。`SpriteSheetPetRenderer` 自带 9 行 STATES 表，
    /// pet.json 主要供 `CodexSpritePackLoader.discover()` 读显示名 + 标记来源。
    /// `packId`/`packName`/`siblings`:多角色包拆出的各角色携带同包归属(picker 二级分组用)。
    /// 全 nil/空 → 不写这三字段(单角色包 / 向后兼容)。见 pet-library-and-multipet-design.md §4.1。
    public static func petJSON(slug: String, displayName: String,
                               rows: Int = ShimejiPetdexLayout.rows,
                               packId: String? = nil, packName: String? = nil,
                               siblings: [String] = []) -> Data {
        // 注:`rows` 仅作信息字段;renderer/loader 实际按 sheet 几何推行数(SpritePackGeometry),不读此值。
        var obj: [String: Any] = [
            "slug": slug,
            "displayName": displayName,
            "source": "shimeji",
            "frameWidth": ShimejiPetdexLayout.frameWidth,
            "frameHeight": ShimejiPetdexLayout.frameHeight,
            "cols": ShimejiPetdexLayout.cols,
            "rows": rows,
        ]
        if let packId, !packId.isEmpty { obj["packId"] = packId }
        if let packName, !packName.isEmpty { obj["packName"] = packName }
        if !siblings.isEmpty { obj["siblings"] = siblings }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
