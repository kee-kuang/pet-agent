import Foundation

// MARK: - Live2DModelInstaller
//
// 把一个 Live2D 模型包(.zip 或目录,含 `*.model3.json` + moc3 +
// textures + motions)安装进 `PetLibrary` 的 live2d 子目录
// (`~/.petagent/pets/live2d/<slug>/`)。复用「拖拽 / 访达选择即装」UX,让
// Live2D 模型像宠物一样插件化在线装(用户要的那层「模型像宠物一样在线装」)。
//
// 与 `ShimejiPackConverter` 的关键不同:Live2D **不做图像转换**,**整包原样拷贝**
// —— model3.json 内部按相对路径引用 moc3 / textures / physics / motions 多文件,
// 必须保结构,只复制 model3.json 单文件会渲染失败。
//
// 安全:① .zip 解压前 zip-slip 校验(拒绝绝对路径 / 含 `..` 段的条目,否则
// `ditto -x -k` 会把 `../../.ssh/...` 写出临时目录)② slug 净化(ASCII、无 `/`/`..`
// → 不越出 parentDir)③ 仅拷贝文件、不执行包内任何内容(本机自用、不重分发)。
// zip-slip 校验 + ditto 解压逻辑与 `ShimejiPackConverter` 同构;两 target 无依赖
// 关系(Rendering 不依赖 ShimejiImport),故各持一份小副本 —— 改一处记得对照另一处。

public enum Live2DModelInstaller {

    public enum InstallError: Error, Equatable {
        case noModelFound   // 包内找不到 *.model3.json
        case unzipFailed    // .zip 解压 / 校验失败
        case copyFailed     // 拷贝到目标失败
    }

    /// 安装一个 Live2D 包(.zip 或目录)到 `<parentDir>/<slug>/`,返回包目录 URL。
    /// .zip 先校验 + 解压到临时目录,装完清理。slug 优先取 model3 stem(语义名),
    /// 回退源文件/目录名;净化后不会越出 parentDir。同名已存在 → 覆盖重装。
    @discardableResult
    public static func install(from url: URL, into parentDir: URL) throws -> URL {
        if url.pathExtension.lowercased() == "zip" {
            try validateZipEntries(url)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("live2d-unzip-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try unzip(url, to: tmp)
            return try installFromDir(tmp, into: parentDir, slugHint: url.deletingPathExtension().lastPathComponent)
        }
        return try installFromDir(url, into: parentDir, slugHint: url.lastPathComponent)
    }

    /// 探测一个 .zip / 目录是否含 `*.model3.json` —— Shell 拖入路由判据(含则按 Live2D,
    /// 否则按 Shimeji)。zip 走 `unzip -Z1` 列条目;目录走限深扫描。
    public static func containsModel3(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" {
            return (try? zipEntries(url))?.contains { $0.lowercased().hasSuffix(".model3.json") } ?? false
        }
        return Live2DModelPackLoader.model3URL(in: url, maxDepth: 6) != nil
    }

    // MARK: - 目录安装

    /// 从目录安装:定位含 model3.json 的**包根**(model3.json 所在目录),整目录拷进目标。
    static func installFromDir(_ dir: URL, into parentDir: URL, slugHint: String) throws -> URL {
        guard let model3 = Live2DModelPackLoader.model3URL(in: dir, maxDepth: 6) else {
            throw InstallError.noModelFound
        }
        let packRoot = model3.deletingLastPathComponent()
        let stem = Live2DModelPackLoader.modelStem(model3)
        let slug = sanitizeSlug(stem.isEmpty ? slugHint : stem)
        let dest = parentDir.appendingPathComponent(slug, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }   // 覆盖重装
            try fm.copyItem(at: packRoot, to: dest)
        } catch { throw InstallError.copyFailed }
        return dest
    }

    // MARK: - zip 处理(zip-slip 防护)

    /// zip-slip 防护:列条目,拒绝绝对路径 / 含 `..` 段的条目。
    static func validateZipEntries(_ zip: URL) throws {
        let entries = try zipEntries(zip)
        for name in entries where name.hasPrefix("/") || name.split(separator: "/").contains("..") {
            throw InstallError.unzipFailed
        }
    }

    /// `unzip -Z1` 列出 zip 内全部条目名。失败抛 `unzipFailed`。
    static func zipEntries(_ zip: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw InstallError.unzipFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // 先 drain 再 wait,防满管阻塞
        p.waitUntilExit()
        guard p.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            throw InstallError.unzipFailed
        }
        return listing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 用系统 `ditto` 解压 PKZip 到目标目录(macOS 自带,稳)。
    static func unzip(_ zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        do { try p.run() } catch { throw InstallError.unzipFailed }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.unzipFailed }
    }

    // MARK: - slug

    /// slug 净化:小写、非 ASCII [a-z0-9] 折成单连字符、去首尾连字符。空 → "live2d-model"。
    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "live2d-model" : trimmed
    }
}
