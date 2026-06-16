import AppKit
import Foundation
import ImageIO

// MARK: - CodexSpritePackLoader
//
// 发现 Codex/petdex **格式**(8×9 spritesheet + pet.json)的 sprite 包,包成 `PetPluginEntry`
// 注册进 `PetPluginRegistry`。扫描来源由 `PetLibrary` 决定(2026-06-06 目录架构):
//   ① 自有库 `~/.petagent/pets/<type>/<slug>/` —— 恒加载,类别由子目录(type)定
//   ② 兼容目录 `~/.codex/pets/<slug>/` —— 开关(默认开),类别由 pet.json source 定
// 同 slug 自有优先(兼容里的同名跳过)。"Codex" 指**包格式**,非仅 ~/.codex 位置。
//
// pet-agent 非沙盒(Apple Development 签名装 /Applications)→ 直接读用户主目录,无需
// security-scoped bookmark。

public enum CodexSpritePackLoader {

    /// id 前缀(sprite 包格式命名空间),避免跟内置 SDF 形象（orb/slime）撞 id。
    public static let idPrefix = "codex:"

    /// B-5 注入钩子:Shimeji 导入包(`.shimejiImport`,含 `conf/`+`img/` 全保真运行时数据)优先用
    /// 此工厂造**原始帧驱动的 `ShimejiPetRenderer`**(App 启动注入,须在 `discover()` 前)。入参 =
    /// 包目录;返回 nil(无运行时数据的旧包)→ 回退 `SpriteSheetPetRenderer`(spritesheet-only)。
    /// Rendering 不依赖 PetBehavior/Shimeji target → 经闭包注入避免成环(同
    /// `Live2DModelPackLoader.rendererFactory` 模式)。
    @MainActor public static var shimejiRendererFactory: ((URL) -> PetRenderer?)?

    /// 扫描全部来源(自有库各类型子目录 + 可选兼容目录),返回注册条目。无包 → 空数组。
    @MainActor
    public static func discover() -> [PetPluginEntry] {
        collect(ourRoot: PetLibrary.root, compatRoot: PetLibrary.compatRoot,
                loadCompat: PetLibrary.loadCompatEnabled)
    }

    /// 可注入根目录的发现实现(测试用临时目录)。自有各 type 子目录(类别按位置)→
    /// 兼容目录(类别按 source);slug 去重,自有优先。
    @MainActor
    static func collect(ourRoot: URL, compatRoot: URL, loadCompat: Bool) -> [PetPluginEntry] {
        var entries: [PetPluginEntry] = []
        var seen = Set<String>()
        for kind in PetLibrary.Kind.allCases {
            scan(ourRoot.appendingPathComponent(kind.dirName, isDirectory: true),
                 categoryOverride: kind.category, into: &entries, seen: &seen)
        }
        if loadCompat {
            scan(compatRoot, categoryOverride: nil, into: &entries, seen: &seen)
        }
        return entries
    }

    /// 扫一个 base 下的 `<slug>/` 包。`categoryOverride` 非空 → 类别按位置(自有库);
    /// nil → 按 pet.json source(兼容目录)。slug 已 seen 则跳过(自有优先去重)。
    @MainActor
    private static func scan(
        _ base: URL, categoryOverride: PetCategory?,
        into entries: inout [PetPluginEntry], seen: inout Set<String>
    ) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let sheetURL = spritesheetURL(in: dir) else { continue }
            let slug = dir.lastPathComponent
            guard !seen.contains(slug) else { continue }
            seen.insert(slug)
            let meta = readMeta(in: dir)
            let category = categoryOverride ?? (meta.source == "shimeji" ? .shimejiImport : .codexCommunity)
            let captured = sheetURL
            let packDir = dir
            let isShimeji = category == .shimejiImport
            entries.append(PetPluginEntry(
                identity: PetIdentity(
                    id: idPrefix + slug,
                    displayName: meta.displayName ?? slug,
                    recommendedSize: NSSize(width: 72, height: 72),
                    category: category,
                    packId: meta.packId,
                    packName: meta.packName
                ),
                thumbnail: firstFrameThumbnail(sheetURL: sheetURL),
                installPath: packDir,   // 删除宠物定位用(发现自磁盘 → 可删)
                makeRenderer: {
                    // Shimeji 导入包优先走原始帧引擎驱动;工厂未注入 / 包缺运行时数据 → nil →
                    // 回退 spritesheet 切帧(旧包、或无 conf/img 的包仍可用)。
                    if isShimeji, let renderer = shimejiRendererFactory?(packDir) {
                        return renderer
                    }
                    return SpriteSheetPetRenderer(spritesheetURL: captured)
                }
            ))
        }
    }

    /// idle 首帧(row 0 / col 0,8×9 网格)裁成小缩略图,供 picker 显示。失败返回 nil
    /// (picker 回退 `category.fallbackSymbol`)。
    ///
    /// 用 ImageIO **降采样解码**整张 sheet(`CGImageSourceCreateThumbnailAtIndex`),避免把
    /// 1536×1872 全分辨率 PNG 解进内存 —— discover() 对每个包都调一次,全分辨率解码会卡主线程
    /// (review 提点)。`cropping` 是 CGImage **顶原点**(已 empirically 验证:裁 (0,0) = idle
    /// 站立帧,与 SpriteSheetPetRenderer.showFrame 同约定)。
    static func firstFrameThumbnail(sheetURL: URL, maxDim: CGFloat = 44) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(sheetURL as CFURL, nil) else { return nil }
        return firstFrameThumbnail(source: src, maxDim: maxDim)
    }

    /// 同上,从内存 `Data`(Codex 在线画廊远程缩略图:下完 spritesheet 字节直接裁,不落临时盘)。
    public static func firstFrameThumbnail(data: Data, maxDim: CGFloat = 44) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return firstFrameThumbnail(source: src, maxDim: maxDim)
    }

    private static func firstFrameThumbnail(source src: CGImageSource, maxDim: CGFloat) -> NSImage? {
        let cols = SpritePackGeometry.cols
        // 目标 thumb 较大边 ≈ maxDim*10 → 单 cell 约 maxDim,够清晰又不全解码(10 覆盖带 climb 包)。
        let thumbMax = Int(maxDim) * 10
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbMax,
        ]
        guard let sheet = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              sheet.width >= cols, sheet.height >= SpritePackGeometry.defaultRows else { return nil }
        // 按几何推真实行数(8×10 带 climb 包用 9 会切到 row1 残片)。
        let rows = SpritePackGeometry.rows(width: sheet.width, height: sheet.height)
        let fw = sheet.width / cols, fh = sheet.height / rows
        guard fw > 0, fh > 0,
              let frame = sheet.cropping(to: CGRect(x: 0, y: 0, width: fw, height: fh)) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: fw, height: fh))
    }

    /// 包目录里的 spritesheet 文件（webp 优先，回退 png）。
    private static func spritesheetURL(in dir: URL) -> URL? {
        for name in ["spritesheet.webp", "spritesheet.png"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 从 `pet.json` 读元数据(显示名 + 来源 + 包归属)。缺失/解析失败返回全 nil。
    /// `source` = "shimeji"(本项目 converter 写入)→ 标记为 Shimeji 导入分类。
    /// `packId`/`packName` = 多角色包同包归属(picker 二级分组);旧包无此字段 → nil(向后兼容)。
    static func readMeta(in dir: URL) -> (displayName: String?, source: String?, packId: String?, packName: String?) {
        let petJson = dir.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: petJson),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        let rawName = (obj["displayName"] as? String) ?? (obj["name"] as? String)
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawName : nil
        let source = (obj["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        func nonEmpty(_ key: String) -> String? {
            let v = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty == false) ? v : nil
        }
        return (name, source, nonEmpty("packId"), nonEmpty("packName"))
    }
}
