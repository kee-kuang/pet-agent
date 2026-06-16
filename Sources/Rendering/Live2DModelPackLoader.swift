import AppKit
import Foundation

// MARK: - Live2DModelPackLoader
//
// 发现 Live2D Cubism 模型包(含 `*.model3.json`)的形象,包成
// `PetPluginEntry` 注册进 `PetPluginRegistry`。扫 `PetLibrary` 的 live2d 子目录
// (`~/.petagent/pets/live2d/<slug>/`)。
//
// **SDK 无关**:只认 `*.model3.json` 文件存在,不解析、不渲染 —— 渲染由后续的
// `Live2DPetRenderer`(接 Cubism Metal)负责。当前阶段 `makeRenderer` 回退 nil →
// Shell 走 placeholder(模型已能像宠物一样安装 + 出现在 picker「Live2D」分组,
// 渲染待 Cubism 渲染器接入)。这一步把用户要的「模型像宠物一样在线装」落地。
//
// 为何独立于 `CodexSpritePackLoader`:Live2D 包结构(model3.json + moc3 + textures
// + motions 多文件)与 petdex sprite(spritesheet + pet.json)完全不同,扫描判据
// 不同。两个 loader 各扫各的,Shell `rebuildPetList` 合并。

public enum Live2DModelPackLoader {

    /// id 前缀(Live2D 命名空间),避免与 `codex:` / 内置裸 id(orb/slime)撞。
    public static let idPrefix = "live2d:"

    /// Live2D 模型推荐初始 size(比 sprite 大;真实尺寸由 Cubism renderer 接管时按 canvas 校准)。
    static let recommendedSize = NSSize(width: 180, height: 240)

    /// renderer 工厂注入钩子:Rendering 不能依赖 Live2D/CubismBridge(会成环),故真正的
    /// `Live2DPetRenderer`(Cubism Metal)由上层(App 启动时)注入此闭包,参数为模型包的
    /// `*.model3.json` URL。未注入(无 SDK / 未 wire)时 `makeRenderer` 回退 nil → Shell placeholder。
    @MainActor public static var rendererFactory: ((URL) -> PetRenderer?)?

    /// 缩略图生成钩子(App 启动注入 `Live2DThumbnailGenerator.generateAndCache`)。Rendering 不能
    /// 依赖 Live2D/CubismBridge(成环),故由上层注入。参数 = 模型 `*.model3.json` URL,生成并缓存
    /// `<model3 同级>/.petagent-thumb.png`。未注入(无 SDK)→ 无缩略图(占位)。
    @MainActor public static var thumbnailGenerator: ((URL) -> Void)?

    /// 为某 Live2D 包目录生成缩略图(找其 model3 → 调注入的 generator 离屏渲染缓存)。导入后调,
    /// 紧接着 `rebuildPetList` 即显示预览图。无 model3 / 未注入 generator → false。
    @MainActor
    @discardableResult
    public static func generateThumbnail(forPackDir dir: URL) -> Bool {
        guard let model3 = model3URL(in: dir, maxDepth: 6), let gen = thumbnailGenerator else { return false }
        gen(model3)
        return true
    }

    /// 自有库里**缺**缓存缩略图的模型 model3 URL(供 App 启动后台逐个补生成,生成完 rebuild picker)。
    @MainActor
    public static func model3sNeedingThumbnail() -> [URL] {
        let fm = FileManager.default
        let liveRoot = PetLibrary.installDir(for: .live2d)
        guard let children = try? fm.contentsOfDirectory(
            at: liveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let model3 = model3URL(in: dir) else { continue }
            let thumb = model3.deletingLastPathComponent().appendingPathComponent(thumbnailCacheFileName)
            if fm.fileExists(atPath: thumb.path) == false { result.append(model3) }
        }
        return result
    }

    /// 扫描自有库 live2d 子目录,返回注册条目。无包 → 空数组。
    @MainActor
    public static func discover() -> [PetPluginEntry] {
        collect(liveRoot: PetLibrary.installDir(for: .live2d))
    }

    /// 可注入根目录的发现实现(测试用临时目录)。扫 `<liveRoot>/<slug>/` 找含
    /// `*.model3.json` 的包,按 slug(目录名)字典序稳定输出。
    @MainActor
    static func collect(liveRoot: URL) -> [PetPluginEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: liveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [PetPluginEntry] = []
        for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let model3 = model3URL(in: dir) else { continue }
            let slug = dir.lastPathComponent
            let model3URL = model3   // capture for the factory closure
            entries.append(PetPluginEntry(
                identity: PetIdentity(
                    id: idPrefix + slug,
                    displayName: displayName(model3: model3, slug: slug),
                    recommendedSize: recommendedSize,
                    category: .live2d
                ),
                // 缩略图 = 缓存的离屏渲染图(`Live2DThumbnailGenerator` 在导入/启动时生成);
                // 没缓存 → nil → picker 用 category.fallbackSymbol 占位,待生成后 rebuild 显示。
                thumbnail: cachedThumbnail(forModel3: model3),
                installPath: dir,   // 删除宠物定位用(发现自磁盘 → 可删)
                // 有注入的工厂(App 启动 wire)→ 真 Live2DPetRenderer;否则 nil → placeholder。
                makeRenderer: { rendererFactory?(model3URL) }
            ))
        }
        return entries
    }

    /// 缓存缩略图文件名(放 model3 同级,与 `Live2DThumbnailGenerator.cacheFileName` 保持一致 ——
    /// Rendering 不能依赖 Live2D 故此处硬编码同名字符串,改动两处需同步)。
    static let thumbnailCacheFileName = ".petagent-thumb.png"

    /// model3 同级的缓存缩略图(离屏渲染生成);不存在 / 解码失败 → nil。
    static func cachedThumbnail(forModel3 model3: URL) -> NSImage? {
        let url = model3.deletingLastPathComponent().appendingPathComponent(thumbnailCacheFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 包目录里第一个 `*.model3.json`。限深 `maxDepth`(默认 2,容 `<slug>/x.model3.json`
    /// 或 `<slug>/runtime/x.model3.json` 两种常见布局);安装器扫未知解压树时用更大深度。
    static func model3URL(in dir: URL, maxDepth: Int = 2) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var found: URL?
        for case let item as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            if item.lastPathComponent.lowercased().hasSuffix(".model3.json") {
                // 取路径最短(最浅)的一个,稳定且偏向包根 model3。
                if found == nil || item.path.count < found!.path.count { found = item }
            }
        }
        return found
    }

    /// 显示名:`*.model3.json` 文件名去 `.model3.json` 后缀(如 `Hiyori.model3.json` →
    /// "Hiyori")。空则回退 slug(目录名)。
    static func displayName(model3: URL, slug: String) -> String {
        let stem = modelStem(model3)
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? slug : trimmed
    }

    /// `Foo.model3.json` → "Foo";非标准命名回退去最后一段扩展名。
    static func modelStem(_ model3: URL) -> String {
        let base = model3.lastPathComponent
        if base.lowercased().hasSuffix(".model3.json") {
            return String(base.dropLast(".model3.json".count))
        }
        return (base as NSString).deletingPathExtension
    }
}
