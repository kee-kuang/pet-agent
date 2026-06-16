import Foundation

// MARK: - PetLibrary
//
// 桌宠目录架构:本项目**自有**宠物库,按类型分子目录,
// 不再寄居 Codex 生态共享目录。`~/.codex/pets/` 降级为**可选加载的兼容目录**。
//
//   ~/.petagent/pets/            ← 自有根(恒加载,类别由子目录定)
//     ├── codex/<slug>/          Codex/petdex 社区宠(在线装 / 手动放)
//     ├── shimeji/<slug>/        Shimeji 转换导入
//     └── live2d/<slug>/         预留(Live2D 形象)
//   ~/.codex/pets/<slug>/        ← 兼容目录(Codex 生态共享,默认加载、可关;类别由 pet.json source 定)
//
// dotfile 选型(非 ~/Library/Application Support)与 Codex 宠生态(~/.codex / ~/.petdex /
// ~/.agentpet)一致,用户好找好手动管理。路径解析单一真相源,安装器 / 发现器都问它。

public enum PetLibrary {

    /// 自有库的类型子目录 —— 类别由**位置**决定(比读 pet.json source 更 robust)。
    public enum Kind: CaseIterable, Sendable {
        case codex, shimeji, live2d
        public var dirName: String {
            switch self {
            case .codex: return "codex"
            case .shimeji: return "shimeji"
            case .live2d: return "live2d"
            }
        }
        public var category: PetCategory {
            switch self {
            case .codex: return .codexCommunity
            case .shimeji: return .shimejiImport
            case .live2d: return .live2d
            }
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 自有根 `~/.petagent/pets/`。
    public static var root: URL { home.appendingPathComponent(".petagent/pets", isDirectory: true) }

    /// 兼容根 `~/.codex/pets/`(Codex 生态共享)。
    public static var compatRoot: URL { home.appendingPathComponent(".codex/pets", isDirectory: true) }

    /// 某类型的安装目录 `~/.petagent/pets/<kind>/`(安装器写这里)。
    public static func installDir(for kind: Kind) -> URL {
        root.appendingPathComponent(kind.dirName, isDirectory: true)
    }

    // MARK: - 删除(卸载宠物)

    public enum RemoveError: Error, Equatable {
        case notInLibrary   // 目录不在自有库/兼容库内(拒绝删任意路径)
        case removeFailed
    }

    /// 删除一个宠物包目录。**安全**:只允许删 `~/.petagent/pets/` 或 `~/.codex/pets/`
    /// **严格子目录**(`hasPrefix(root + "/")` → 既挡库根本身,也挡 `petsEVIL` 这类同前缀兄弟),
    /// 防误删任意路径。目录不存在视为成功(幂等)。返回是否真的删了东西。
    @discardableResult
    public static func removePack(at dir: URL) throws -> Bool {
        let target = dir.standardizedFileURL.path
        let ourPrefix = root.standardizedFileURL.path + "/"
        let compatPrefix = compatRoot.standardizedFileURL.path + "/"
        guard target.hasPrefix(ourPrefix) || target.hasPrefix(compatPrefix) else {
            throw RemoveError.notInLibrary
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target) else { return false }   // 幂等:已不在
        do { try fm.removeItem(atPath: target) } catch { throw RemoveError.removeFailed }
        return true
    }

    // MARK: - 开关(UserDefaults 持久化)

    /// 兼容目录加载开关(默认 **true** —— 现有 Codex 用户/已装宠不丢)。
    public static let loadCompatDefaultsKey = "pet.library.loadCompat"
    public static var loadCompatEnabled: Bool {
        get { UserDefaults.standard.object(forKey: loadCompatDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: loadCompatDefaultsKey) }
    }

    /// Codex 宠在线安装时**同时**写一份到兼容目录(跨 Codex 工具共享)开关(默认 false)。
    public static let dualWriteDefaultsKey = "pet.library.dualWriteCompat"
    public static var dualWriteCompatEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: dualWriteDefaultsKey) }   // 缺省 false
        set { UserDefaults.standard.set(newValue, forKey: dualWriteDefaultsKey) }
    }
}
