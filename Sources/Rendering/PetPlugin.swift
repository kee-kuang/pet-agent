import AppKit

// MARK: - PetIdentity
//
// Pet 形象插件的元数据 —— 不含视觉/动画实现细节,纯描述。设置面板 UI 用它
// 来渲染下拉框 + 预览缩略图;UserDefaults 用 `id` 持久化用户选择。
//
// 设计参考上游开源项目 HermesPet (https://github.com/basionwang-bot/HermesPet)
// 的 `AgentMode` 元数据 pattern,但 PetAgent 用结构化 struct 而非 enum + label/icon 离散 case,因为
// pet 形象未来会从 5 个外部插件扩展(史莱姆 / 雪人 / Ferris / …),不适合
// hard-code 在一个 enum 里。

/// 形象来源分类 —— 设置面板 picker 按此分组,让用户感知「哪些桌宠属于哪类」。
/// 借鉴上游开源项目 AccountyCat (https://github.com/strjonas/AccountyCat)
/// 的 `ACPortraitSource`(多来源统一建模)。
/// 分类抓手已现成:内置形象裸 id(orb/slime),Codex 包 `codex:` 前缀,Shimeji
/// 导入包 pet.json 带 `"source":"shimeji"`(见 ShimejiSpriteSheetPacker.petJSON)。
public enum PetCategory: String, Equatable, Sendable, CaseIterable {
    case builtin         // 内置 SDF 形象(弹力球 / 史莱姆),编译期 plugin
    case codexCommunity  // ~/.codex/pets/ 原生 Codex/petdex sprite 包
    case shimejiImport   // 由 Shimeji 包转换导入的 sprite 包(pet.json source=shimeji)
    case live2d          // 预留:Live2D 形象

    /// 设置面板分组标题。
    public var displayName: String {
        switch self {
        case .builtin: return "内置"
        case .codexCommunity: return "Codex 社区"
        case .shimejiImport: return "Shimeji 导入"
        case .live2d: return "Live2D"
        }
    }

    /// 分组排序权重(内置在最前,Live2D 在最后)。
    public var sortOrder: Int {
        switch self {
        case .builtin: return 0
        case .codexCommunity: return 1
        case .shimejiImport: return 2
        case .live2d: return 3
        }
    }

    /// 无缩略图时的占位 SF Symbol(按来源给个可辨识图标)。
    public var fallbackSymbol: String {
        switch self {
        case .builtin: return "circle.hexagongrid.fill"
        case .codexCommunity: return "cube.box.fill"
        case .shimejiImport: return "figure.walk.motion"
        case .live2d: return "person.crop.square.badge.video.fill"
        }
    }
}

public struct PetIdentity: Equatable, Sendable {
    /// 全局唯一 ID。UserDefaults 用此 key 持久化用户选择(`"pet.plugin.id"` →
    /// "orb" / "slime" / "ferris" / …)。命名约定:lower-kebab,无空格。
    public let id: String

    /// 设置面板下拉显示的中文名(例如"弹力球" / "史莱姆" / "Ferris 螃蟹")。
    public let displayName: String

    /// renderer view 推荐的初始 size。Shell 装到 `PetShellWindow` 时按此值
    /// 调整 window content。当前 Orb 是 64×64,后续角色化形象可能更大。
    public let recommendedSize: NSSize

    /// 来源分类 —— picker 分组用。内置形象默认 `.builtin`;运行时发现的 sprite 包
    /// 由 `CodexSpritePackLoader` 按 pet.json 设 `.codexCommunity` / `.shimejiImport`。
    public let category: PetCategory

    /// 包归属 ID —— **同一个导入包**(如多角色 Shimeji 包)拆出的多只宠物共享同一 packId,
    /// 供 picker 二级分组("标明哪些宠物属于同一个包")。`nil` = 无包归属(单宠物 / 内置 /
    /// 历史导入的旧包),picker 里各自独立显示(向后兼容)。见 pet-library-and-multipet-design.md §4。
    public let packId: String?

    /// 包展示名(原始包目录/zip 名),picker 包分组标题用。`nil` 同 `packId`。
    public let packName: String?

    public init(
        id: String, displayName: String, recommendedSize: NSSize, category: PetCategory = .builtin,
        packId: String? = nil, packName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.recommendedSize = recommendedSize
        self.category = category
        self.packId = packId
        self.packName = packName
    }
}

// MARK: - PetPlugin
//
// Pet 形象插件契约 —— 每种形象(Orb / Slime / Ferris / …)实现一个 type
// conform `PetPlugin`,声明 identity + 提供 renderer 工厂。Shell 通过
// `PetPluginRegistry` 按 ID 查找 plugin 然后调 `makeRenderer()` 拿到具体
// renderer 实例。
//
// 为什么 type-level conformance(static identity)而非 instance-level:
// - identity 是不变的描述性元数据,所有实例共享 → static 更自然
// - 设置面板要枚举所有可用 plugin 展示给用户选,枚举时不需要先实例化
// - 跟 SwiftUI ViewModifier / Identifiable 协议设计同源

public protocol PetPlugin {
    /// 该形象的 identity(id / 显示名 / 推荐 size)。
    static var identity: PetIdentity { get }

    /// 创建一个新的 renderer 实例。Metal-less 系统(headless CI / 某些 VM)
    /// 上某些 plugin(如 OrbMetalRenderer)会返回 nil,Shell 端需要 fallback
    /// 到 placeholder。每次 `makeRenderer()` 都创建新实例,不复用。
    @MainActor static func makeRenderer() -> PetRenderer?
}

// MARK: - PetPluginRegistry
//
// 进程内 pet plugin 注册表,@MainActor 单例。app 启动时各 plugin 自我注册
// (例如 `OrbPetPlugin.registerSelf()` 在 `MinimalAppDelegate.didFinishLaunching`
// 调一次),Shell 按 UserDefaults 选 plugin 时来这查。
//
// 当前阶段只支持 app 启动时一次性注册,不支持 hot-reload 也不支持第三方
// SDK 注册外部 plugin(N3 之后讨论)。

// MARK: - PetPluginEntry
//
// 注册表条目 —— **值类型**,统一容纳两类形象来源:
//   - 编译期类型级 plugin（Orb / Slime 等 SDF 代码形象，`register(_ plugin: PetPlugin.Type)` 包进来）
//   - **运行时数据形象**（如扫 `~/.codex/pets/` 发现的 sprite 包，`register(_ entry:)` 直接注册）
// 后者没有静态类型，无法做 type-level conformance，故引入值类型条目（借鉴上游开源项目
// AccountyCat (https://github.com/strjonas/AccountyCat) 的 `ACCharacter` 值类型 + catalog 可增长的设计）。

public struct PetPluginEntry {
    public let identity: PetIdentity
    public let makeRenderer: @MainActor () -> PetRenderer?
    /// 设置面板 picker 缩略图(sprite 包 = idle 首帧;内置 SDF 形象 = nil → 用
    /// `category.fallbackSymbol` 占位)。`CodexSpritePackLoader` 发现包时预裁。
    public let thumbnail: NSImage?
    /// 磁盘包目录 —— 运行时发现的 sprite/Live2D 包有(`~/.petagent/pets/<kind>/<slug>/` 或兼容目录),
    /// 供「删除宠物」定位要删的目录。内置 SDF 形象(Orb/Slime)= nil → **不可删**。
    public let installPath: URL?

    public init(
        identity: PetIdentity,
        thumbnail: NSImage? = nil,
        installPath: URL? = nil,
        makeRenderer: @escaping @MainActor () -> PetRenderer?
    ) {
        self.identity = identity
        self.thumbnail = thumbnail
        self.installPath = installPath
        self.makeRenderer = makeRenderer
    }
}

@MainActor
public final class PetPluginRegistry {

    public static let shared = PetPluginRegistry()

    /// id → entry。id 重复时后注册覆盖前者（测试 / 热替换 / 同名 sprite 包）。
    private var entries: [String: PetPluginEntry] = [:]

    private init() {}

    /// 注册类型级 plugin（Orb/Slime）——包成 entry。
    public func register(_ plugin: PetPlugin.Type) {
        let identity = plugin.identity
        entries[identity.id] = PetPluginEntry(identity: identity, makeRenderer: { plugin.makeRenderer() })
    }

    /// 注册值级 entry（运行时 sprite 包等）。
    public func register(_ entry: PetPluginEntry) {
        entries[entry.identity.id] = entry
    }

    /// 按 ID 查找。返回 nil = 未注册 / ID 拼错。
    public func plugin(for id: String) -> PetPluginEntry? {
        entries[id]
    }

    /// 注销一个 entry(删除宠物用)。内置形象不应被删(调用方按 `installPath != nil` 把关)。
    public func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    /// 所有已注册 entry。设置面板 UI 用此枚举生成下拉项。dict 序不保证稳定。
    public var all: [PetPluginEntry] {
        Array(entries.values)
    }

    /// 测试用 reset。生产代码不调。
    public func resetForTesting() {
        entries.removeAll()
    }
}

// MARK: - OrbPetPlugin
//
// 把现有 `OrbMetalRenderer`(体积呼吸 + 完成跳跃 + 物理 squash
// 等都在它身上)包装成第一个 `PetPlugin`。是 PetAgent 唯一默认形象,id
// "orb",DesktopShellController 在未配置 / 配错时会 fallback 到它。
//
// Metal-less 系统(headless CI)上 `OrbMetalRenderer.init?` 返回 nil →
// `makeRenderer` 也返回 nil → Shell fallback 到 placeholder NSView。

public enum OrbPetPlugin: PetPlugin {
    public static let identity = PetIdentity(
        id: "orb",
        displayName: "弹力球",
        recommendedSize: NSSize(width: 64, height: 64)
    )

    @MainActor
    public static func makeRenderer() -> PetRenderer? {
        OrbMetalRenderer()
    }
}
