import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shimeji 包 → petdex 包的端到端转换（扫包 → 加载 shimeN.png →
/// `ShimejiSpriteSheetPacker` 拼图 → 写 `spritesheet.png` + `pet.json`）。纯 IO 编排，
/// 用临时目录合成 PNG 可端到端测；CLI 壳（`shimeji-convert`）只是它的薄包装。
public enum ShimejiPackConverter {

    public enum ConvertError: Error, Equatable {
        case noFramesFound      // 扫不到任何 shimeN.png
        case packFailed         // 拼图失败
        case writeFailed        // 写 PNG / pet.json 失败
        case unzipFailed        // .zip 解压失败
    }

    /// 转换一个 Shimeji 包 —— 接受 **.zip 或目录**。.zip 先解压到临时目录再转,转完清理。
    /// 设置面板「导入 Shimeji」(拖入 / 选择)走这条。slug/displayName 缺省由帧目录名推导。
    /// **多角色包**(img/<角色A>/ + img/<角色B>/)各转一个独立 petdex 包 → 返回 `[URL]`
    /// (忠于 Shimeji-ee「每 img/<角色>=独立 mascot」语义)。
    /// 安全:输出 slug 经 `sanitizeSlug` 净化(ASCII、无 `/`/`..`)→ 不会越出 outputParentDir;
    /// 仅读取帧目录下的 shimeN.png(不执行包内任何内容),本机自用转换、不重分发。
    @discardableResult
    public static func convertZipOrDir(
        at url: URL, outputParentDir: URL, slug: String? = nil, displayName: String? = nil
    ) throws -> [URL] {
        // 包名取原始 url(zip 去扩展名 / 目录名)—— zip 解压到 UUID 临时目录后 packDir 名无意义,
        // 必须在此捕获真实包名供多角色包归属(packId/packName)。
        let originPackName = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "zip" else {
            return try convert(packDir: url, outputParentDir: outputParentDir, slug: slug,
                               displayName: displayName, packName: originPackName)
        }
        try validateZipEntries(url)   // zip-slip 防护:解压前拒绝穿越条目(ditto 不净化)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-unzip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try unzip(url, to: tmp)
        return try convert(packDir: tmp, outputParentDir: outputParentDir, slug: slug,
                           displayName: displayName, packName: originPackName)
    }

    /// zip-slip 防护:用 `unzip -Z1` 列出条目,拒绝绝对路径 / 含 `..` 段的条目(否则
    /// `ditto -x -k` 会把 `../../.ssh/...` 写出临时目录,覆盖用户 home 敏感文件)。
    static func validateZipEntries(_ zip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw ConvertError.unzipFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // 先 drain 再 wait,防满管阻塞
        p.waitUntilExit()
        guard p.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            throw ConvertError.unzipFailed
        }
        for line in listing.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                throw ConvertError.unzipFailed
            }
        }
    }

    /// 用系统 `ditto` 解压 PKZip 到目标目录(macOS 自带,稳)。
    static func unzip(_ zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        do { try p.run() } catch { throw ConvertError.unzipFailed }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ConvertError.unzipFailed }
    }

    /// 转换一个 Shimeji 包目录到 petdex 包(支持包内多角色)。
    /// - packDir: Shimeji 包根（含 `img/<角色>/shimeN.png`，或直接含 shimeN.png）。
    /// - outputParentDir: 输出父目录（如 `~/.petagent/pets/shimeji`）；每角色写到其下 `<slug>/`。
    /// - slug/displayName: 缺省由角色目录名推导;**仅单角色包时生效**(多角色无法共用一个 slug)。
    /// 返回写好的所有包目录 URL(单角色 1 个,多角色 N 个),按 slug 排序。
    @discardableResult
    public static func convert(
        packDir: URL, outputParentDir: URL, slug: String? = nil, displayName: String? = nil,
        packName: String? = nil
    ) throws -> [URL] {
        let frameDirs = findAllFrameDirectories(packDir)
        guard !frameDirs.isEmpty else { throw ConvertError.noFramesFound }
        let singleChar = frameDirs.count == 1   // 显式 slug/name 仅单角色生效

        // 预扫 base slug:冲突者全加稳定 hash 后缀(全日文角色名都兜底成 "shimeji" → 会互覆)。
        let baseSlugs = frameDirs.map { dir in
            sanitizeSlug(singleChar ? (slug ?? dir.lastPathComponent) : dir.lastPathComponent)
        }
        let slugCounts = Dictionary(baseSlugs.map { ($0, 1) }, uniquingKeysWith: +)
        // 预解析全部 slug(siblings 需在写第一只 pet.json 前就知道同包全员;两遍式)。
        let resolvedSlugs = frameDirs.enumerated().map { (i, dir) in
            slugCounts[baseSlugs[i]]! > 1 ? "\(baseSlugs[i])-\(stableHash4(dir.lastPathComponent))" : baseSlugs[i]
        }
        // 包归属:仅**多角色包**(N>1)标记同包(picker 二级分组);单角色无 packId(向后兼容)。
        let resolvedPackName = packName ?? packDir.lastPathComponent
        let packId: String? = singleChar ? nil : {
            let s = sanitizeSlug(resolvedPackName)
            return s.isEmpty ? "pack-\(stableHash4(resolvedPackName))" : s
        }()
        let packDisplayName: String? = singleChar ? nil : resolvedPackName

        var out: [URL] = []
        for (i, dir) in frameDirs.enumerated() {
            guard let made = try makeSheet(frameDir: dir) else { continue }   // nil = 该角色无可用帧 → 跳过
            let resolvedSlug = resolvedSlugs[i]
            let resolvedName = singleChar ? (displayName ?? dir.lastPathComponent) : dir.lastPathComponent
            let outDir = try writePack(sheet: made.sheet, rows: made.rows, slug: resolvedSlug,
                                       displayName: resolvedName, outputParentDir: outputParentDir,
                                       packId: packId, packName: packDisplayName, siblings: resolvedSlugs)
            // 随包保留运行时数据(conf/actions+behaviors.xml + img/ 原始帧),供
            // ShimejiMascotEngine 全保真驱动。best-effort —— 拷不全只是退化为
            // spritesheet-only(运行时 loader 按完整性判定),不影响既有转换。
            copyRuntimeData(frameDir: dir, packRoot: packDir, outDir: outDir)
            out.append(outDir)
        }
        guard !out.isEmpty else { throw ConvertError.noFramesFound }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 走帧号约定路径所需的最少 shimeN 帧数。低于此(自定义命名包,如火柴人只有 shime1)且有
    /// actions.xml → 改走 XML 解析路径,否则散帧拼出来全是站立帧(桌宠静止不动)。
    static let frameNumberMinDistinctFrames = 4

    /// 为一个角色目录生成 sheet + 真实行数,**自动选路径**:
    /// ① shimeN 覆盖足够(≥ `frameNumberMinDistinctFrames`)→ 帧号约定路径(标准 Shimeji-ee 包,已验证);
    /// ② 否则有可解析的 `conf/actions.xml` → actions.xml 路径(自定义命名包 —— 真正的动画在这);
    /// ③ 兜底:有任意 shimeN 就出帧号 sheet(可能静止但不崩);全无 → nil(该角色跳过)。
    static func makeSheet(frameDir: URL) throws -> (sheet: CGImage, rows: Int)? {
        let numbered = loadFrames(in: frameDir)
        if numbered.count >= frameNumberMinDistinctFrames { return try packNumbered(numbered) }

        let actionRows = rowsFromActions(frameDir: frameDir)
        if !actionRows.isEmpty {
            do {
                return (try ShimejiSpriteSheetPacker.packRows(actionRows),
                        ShimejiSpriteSheetPacker.effectiveRows(rows: actionRows))
            } catch { throw ConvertError.packFailed }
        }
        guard !numbered.isEmpty else { return nil }
        return try packNumbered(numbered)
    }

    private static func packNumbered(_ numbered: [Int: CGImage]) throws -> (CGImage, Int) {
        do {
            return (try ShimejiSpriteSheetPacker.pack(frames: numbered),
                    ShimejiSpriteSheetPacker.effectiveRows(frames: numbered))
        } catch { throw ConvertError.packFailed }
    }

    /// 读 `<frameDir>/conf/actions.xml` → 按 `ShimejiActionRowMapping` 把每行首个命中动作的引用帧
    /// (任意命名,从 frameDir 加载)resolve 成 CGImage。无 actions.xml / 无基本动作(Stand|Walk)/
    /// 帧加载失败 → 返回空(上层回退帧号路径)。帧按文件名缓存,避免重复 IO。
    static func rowsFromActions(frameDir: URL) -> [(row: Int, frames: [CGImage], flip: Bool)] {
        let actionsURL = frameDir.appendingPathComponent("conf/actions.xml")
        guard let data = try? Data(contentsOf: actionsURL) else { return [] }
        let actions = ShimejiActionsParser.parse(data)
        guard actions["Stand"] != nil || actions["Walk"] != nil else { return [] }   // 至少有基本动作才认

        var cache: [String: CGImage] = [:]
        func frame(_ name: String) -> CGImage? {
            if let c = cache[name] { return c }
            guard let img = loadCGImage(frameDir.appendingPathComponent(name)) else { return nil }
            cache[name] = img
            return img
        }
        var rows: [(Int, [CGImage], Bool)] = []
        for spec in ShimejiActionRowMapping.rows {
            guard let poses = spec.actions.lazy.compactMap({ actions[$0] }).first else { continue }
            let imgs = poses.prefix(ShimejiPetdexLayout.cols).compactMap { frame($0.image) }
            if !imgs.isEmpty { rows.append((spec.row, imgs, spec.flipHorizontally)) }
        }
        return rows
    }

    /// 写 `<slug>/{spritesheet.png,pet.json}`,返回包目录。`packId`/`packName`/`siblings`
    /// 写进 pet.json 供 picker 二级分组(多角色包同包归属)。
    private static func writePack(
        sheet: CGImage, rows: Int, slug: String, displayName: String, outputParentDir: URL,
        packId: String? = nil, packName: String? = nil, siblings: [String] = []
    ) throws -> URL {
        let outDir = outputParentDir.appendingPathComponent(slug, isDirectory: true)
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { throw ConvertError.writeFailed }

        guard writePNG(sheet, to: outDir.appendingPathComponent("spritesheet.png")) else {
            throw ConvertError.writeFailed
        }
        let petJSON = ShimejiSpriteSheetPacker.petJSON(
            slug: slug, displayName: displayName, rows: rows,
            packId: packId, packName: packName, siblings: siblings)
        do { try petJSON.write(to: outDir.appendingPathComponent("pet.json")) }
        catch { throw ConvertError.writeFailed }
        return outDir
    }

    // MARK: - 运行时数据保留

    /// 把角色的全保真运行时数据拷进输出包:`conf/{actions,behaviors}.xml` + `img/*.png`(平铺,
    /// 任意命名含 shimeN 与自定义帧)。conf 解析顺序 = **角色目录向上逐级祖先到包根**,每级查
    /// `conf/<name>`,首个命中胜出(Shimeji-ee 惯例:`img/<角色>/conf/` 角色专属 > 包根 `conf/`
    /// 共享;容 `<wrapper>/img/<角色>/` 任意嵌套)。sound/ 跳过(声明:不做音频)。
    /// best-effort:单文件拷失败不抛(运行时 loader 按「actions+behaviors+img 齐全」判定启用)。
    static func copyRuntimeData(frameDir: URL, packRoot: URL, outDir: URL) {
        let fm = FileManager.default

        // conf:逐级祖先解析两份 XML
        let confOut = outDir.appendingPathComponent("conf", isDirectory: true)
        for name in ["actions.xml", "behaviors.xml"] {
            guard let source = resolveConfFile(named: name, frameDir: frameDir, packRoot: packRoot) else { continue }
            try? fm.createDirectory(at: confOut, withIntermediateDirectories: true)
            let dest = confOut.appendingPathComponent(name)
            try? fm.removeItem(at: dest)   // 覆盖重装
            try? fm.copyItem(at: source, to: dest)
        }

        // img:角色目录下平铺的全部 PNG(非递归 —— 帧文件平铺,conf/ 子目录天然被滤掉)
        guard let entries = try? fm.contentsOfDirectory(at: frameDir, includingPropertiesForKeys: nil) else { return }
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        guard !pngs.isEmpty else { return }
        let imgOut = outDir.appendingPathComponent("img", isDirectory: true)
        try? fm.createDirectory(at: imgOut, withIntermediateDirectories: true)
        for png in pngs {
            let dest = imgOut.appendingPathComponent(png.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: png, to: dest)
        }
    }

    /// 从 frameDir 向上逐级(含 frameDir 与 packRoot 自身)找 `*/conf/<name>`,首个存在者胜出。
    /// 限 8 级防异常路径(正常嵌套 ≤3)。
    static func resolveConfFile(named name: String, frameDir: URL, packRoot: URL) -> URL? {
        let fm = FileManager.default
        var dir = frameDir.standardizedFileURL
        let root = packRoot.standardizedFileURL
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("conf").appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            if dir.path == root.path || dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - 包扫描

    /// 找**所有**含 shimeN.png 的角色目录 —— 限深（≤4）递归,容社区包 / .zip 的任意嵌套
    /// （`img/<角色>/` vs 直接 `shimeN.png` vs `<wrapper>/img/<角色>/`）。多角色包(默认
    /// Shimeji-ee 自带 Shimeji+KuroShimeji)每个角色目录各返回一个 → 各转独立包,不丢角色。
    /// 按路径排序保证确定性(FileManager 枚举序不稳定)。
    static func findAllFrameDirectories(_ packDir: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        func consider(_ dir: URL) { if frameCount(in: dir) > 0 { found.append(dir) } }
        consider(packDir)
        if let en = fm.enumerator(at: packDir, includingPropertiesForKeys: [.isDirectoryKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let item as URL in en {
                if en.level > 4 { en.skipDescendants(); continue }
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    consider(item)
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// 确定性 4-hex 短哈希(FNV-1a over UTF8)—— slug 冲突后缀用。同名目录每次导入得**稳定**
    /// slug(可覆盖更新而非堆 `-2/-3`);Swift `Hashable.hashValue` 跨进程随机,不可用。
    static func stableHash4(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(format: "%04x", h & 0xFFFF)
    }

    private static func frameCount(in dir: URL) -> Int {
        (1...ShimejiFrameMapping.standardFrameCount).reduce(0) { acc, n in
            FileManager.default.fileExists(atPath: frameURL(dir, n).path) ? acc + 1 : acc
        }
    }

    /// 加载目录下所有存在的 shimeN.png → `[N: CGImage]`。
    static func loadFrames(in dir: URL) -> [Int: CGImage] {
        var out: [Int: CGImage] = [:]
        for n in 1...ShimejiFrameMapping.standardFrameCount {
            if let img = loadCGImage(frameURL(dir, n)) { out[n] = img }
        }
        return out
    }

    private static func frameURL(_ dir: URL, _ n: Int) -> URL {
        dir.appendingPathComponent("shime\(n).png")
    }

    // MARK: - ImageIO 读写

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - slug

    /// slug 净化：小写、非 ASCII [a-z0-9] 折成单连字符、去首尾连字符。空 → "shimeji"。
    /// 限 ASCII（非 ASCII 字母如日文也折连字符）→ 文件名 / petdex id / URL 安全。
    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "shimeji" : trimmed
    }
}
