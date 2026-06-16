import Foundation

// MARK: - PetCatalog
//
// Codex/petdex 在线桌宠 catalog 客户端(应用内一键安装)。蓝本参考上游开源项目
// agentpet (https://github.com/ntd4996/agentpet) 的 PetBrowser/PetInstaller(原生 Swift)
// + petdex (https://github.com/crafter-station/petdex) 的 install 安全契约
// (域名 allowlist + Referer 防盗链 + 路径遍历防护)。纯 Foundation 叶子模块,网络层
// 经 `AssetFetcher` 协议注入 → mock 可全测,不碰真网。
//
// catalog 端点:`https://petdex.crafter.run/api/manifest`(公开免鉴权 slim JSON)。
// 包格式:pet.json + spritesheet.{webp,png},装进 `~/.codex/pets/<slug>/`(本项目目标目录,
// 被 CodexSpritePackLoader.discover() 发现)。

/// 远端 catalog 一只宠物(镜像 petdex `/api/manifest` 的 pets[] 元素)。
public struct RemotePet: Decodable, Identifiable, Equatable, Sendable {
    public let slug: String
    public let displayName: String?
    public let kind: String?          // character / creature / object
    public let submittedBy: String?
    public let spritesheetUrl: String
    public let petJsonUrl: String

    public var id: String { slug }
    public var name: String { displayName ?? slug }
    public var author: String { submittedBy ?? "community" }

    public init(slug: String, displayName: String?, kind: String?, submittedBy: String?,
                spritesheetUrl: String, petJsonUrl: String) {
        self.slug = slug
        self.displayName = displayName
        self.kind = kind
        self.submittedBy = submittedBy
        self.spritesheetUrl = spritesheetUrl
        self.petJsonUrl = petJsonUrl
    }
}

/// 分类(petdex `kind`)—— 浏览画廊分段过滤用。
public enum PetCatalogKind {
    public static let all = "all"
    /// (label, value),value="all" 表示不过滤。
    public static let segments: [(label: String, value: String)] = [
        ("全部", "all"), ("角色", "character"), ("生物", "creature"), ("物件", "object"),
    ]
}

/// 容错解码:单个元素坏掉时产 nil 而非让整数组解码失败(petdex 偶有脏数据 / 新字段)。
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

/// `/api/manifest` 顶层:`{ generatedAt, total, pets: [...] }`,只取 pets(lenient)。
struct PetManifest: Decodable {
    let pets: [RemotePet]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pets = try c.decode([Lenient<RemotePet>].self, forKey: .pets).compactMap(\.value)
    }
    enum CodingKeys: String, CodingKey { case pets }
}
