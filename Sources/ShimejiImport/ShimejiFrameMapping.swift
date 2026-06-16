import Foundation

// MARK: - ShimejiImport
//
// 把 Shimeji-ee 包（`img/<角色>/shimeN.png` 标准 46 帧）转成本项目
// petdex 兼容 sprite 包（8 列 × 9 行、每帧 192×208），装到 `~/.codex/pets/<slug>/`
// 即被 `CodexSpritePackLoader.discover()` 发现、`SpriteSheetPetRenderer` 播放。
//
// 纯打包核心（映射表 + 网格拼装），合成 fixture 离屏测试，无需真实包。
// 帧映射依据 Shimeji-ee canonical actions.xml 的帧号约定（参照社区标准帧语义整理而成）。
//
// **帧语义按文件号标准化**（Shimeji-ee 约定），故按帧号映射、不必解析 actions.xml；
// 非标准包的自定义帧序留待后续 commit 加 XML 解析覆盖。

/// petdex sprite 表布局（与 `SpriteSheetPetRenderer` 的 8×9 / 192×208 约定一致）。
public enum ShimejiPetdexLayout {
    public static let cols = 8
    public static let rows = 9
    public static let frameWidth = 192
    public static let frameHeight = 208
    public static var sheetWidth: Int { cols * frameWidth }
    public static var sheetHeight: Int { rows * frameHeight }
}

/// Shimeji 46 帧 → petdex 9 状态行映射（「手工定义」核心，无法自动推导）。
///
/// petdex 9 行（参照 petdex 的 `main.zig` STATES 状态表重新实现的数据约定，未拷贝源码；与 `SpriteSheetPetRenderer` 一致）：
///   0 idle / 1 runningRight / 2 runningLeft / 3 waving / 4 jumping
///   / 5 failed / 6 waiting / 7 running / 8 review
///
/// Shimeji 帧朝向单一（通常面右），左向行（runningLeft）由 `flipHorizontally` 水平
/// 翻转 right 帧生成（petdex 是独立 left/right 行，renderer 不翻）。`frames` 是 shimeN
/// 的 N（1-based）；缺帧时 packer 回退 frame 1（再缺 → 透明 cell）。
public enum ShimejiFrameMapping {

    /// 一行的来源定义：目标行号 + 来源 shimeN 帧序（≤8）+ 是否水平翻转 + 是否可选(源帧全缺则整行省略)。
    public struct RowSpec: Equatable, Sendable {
        public let row: Int
        public let frames: [Int]
        public let flipHorizontally: Bool
        /// 可选行:若 `frames` 对应的 shimeN 全缺 → packer 整行省略(sheet 缩回不含此行),
        /// 而非用 fallbackFrame 填(那会让 climb 行变「静止站立」,比 renderer 回退 running 更假)。
        public let optional: Bool
        public init(row: Int, frames: [Int], flipHorizontally: Bool, optional: Bool = false) {
            self.row = row
            self.frames = frames
            self.flipHorizontally = flipHorizontally
            self.optional = optional
        }
    }

    /// 映射表（基线；必选行缺帧回退 shime1,可选行缺帧整行省略）。
    /// row 0-8 = 经典 9 行;row 9 = 攀爬专用(可选,Shimeji 标准 shime12-14 爬墙帧)。
    public static let rows: [RowSpec] = [
        RowSpec(row: 0, frames: [1],          flipHorizontally: false),  // idle ← 站立
        RowSpec(row: 1, frames: [1, 2, 3],    flipHorizontally: false),  // runningRight ← walk 循环（面右）
        RowSpec(row: 2, frames: [1, 2, 3],    flipHorizontally: true),   // runningLeft ← walk 镜像
        RowSpec(row: 3, frames: [5, 6, 1],    flipHorizontally: false),  // waving ← 抗拒举臂≈招手
        RowSpec(row: 4, frames: [22, 4],      flipHorizontally: false),  // jumping ← 跳 + 落
        RowSpec(row: 5, frames: [9, 7, 8, 10], flipHorizontally: false), // failed ← 被捏/拖=沮丧
        RowSpec(row: 6, frames: [11, 26],     flipHorizontally: false),  // waiting ← 坐/抬头=待命
        RowSpec(row: 7, frames: [1, 2, 3],    flipHorizontally: false),  // running ← 同 walk（Shimeji run 复用 1-3）
        RowSpec(row: 8, frames: [26, 15, 16, 17], flipHorizontally: false), // review ← 坐+转头=专注
        RowSpec(row: 9, frames: [12, 13, 14], flipHorizontally: false, optional: true), // climbing ← shime12-14 爬墙(面右)
    ]

    /// 标准 Shimeji-ee 总帧数（社区包常有缺帧；packer 容缺）。
    public static let standardFrameCount = 46

    /// 回退帧号：任一映射帧缺失时退到此帧（站立基帧，几乎所有包都有）。
    public static let fallbackFrame = 1
}

/// 「Shimeji 动作名 → petdex 行」映射(actions.xml 解析路径用)。
///
/// 自定义命名的包(帧叫 `dance01.png` 而非 `shimeN.png`)无法走帧号约定,改由 actions.xml 拿
/// 「每个动作引用哪些帧」,再按本表把**标准 Shimeji-ee 动作名**灌进对应 sprite 行。每行给一组
/// **候选动作名**(按序第一个在 actions.xml 里存在且有帧的胜出),覆盖常见命名变体。
/// `flip`=左向行用右向动作镜像。无候选命中 → 该行留空(renderer 稀疏检测跳过 → 回退情绪态)。
public enum ShimejiActionRowMapping {

    public struct ActionRowSpec: Equatable, Sendable {
        public let row: Int
        public let actions: [String]      // 候选动作名(首个命中胜出)
        public let flipHorizontally: Bool
        public let optional: Bool
        public init(row: Int, actions: [String], flip: Bool, optional: Bool = false) {
            self.row = row; self.actions = actions; self.flipHorizontally = flip; self.optional = optional
        }
    }

    /// 行 ← 候选 Shimeji 动作名。名称取自 canonical Shimeji-ee actions.xml(Stand/Walk/Run/Sit/
    /// ClimbWall/...)。row 9 climbing 可选(无爬墙动作的包缩回 9 行 → 回退 running 镜像)。
    public static let rows: [ActionRowSpec] = [
        .init(row: 0, actions: ["Stand"],                              flip: false),               // idle
        .init(row: 1, actions: ["Walk", "Run", "Dash"],               flip: false),               // runningRight
        .init(row: 2, actions: ["Walk", "Run", "Dash"],               flip: true),                // runningLeft(镜像)
        .init(row: 3, actions: ["Dance", "Wave", "Bounce"],           flip: false, optional: true), // waving ← Dance 近似
        .init(row: 4, actions: ["Jump", "Bounce", "Tripping"],        flip: false, optional: true), // jumping
        .init(row: 5, actions: ["Pinched", "Dragged", "Tripping"],    flip: false, optional: true), // failed
        .init(row: 6, actions: ["Sit", "SitDown", "SitAndLookUp"],    flip: false, optional: true), // waiting
        .init(row: 7, actions: ["Run", "Dash", "Walk"],               flip: false),               // running
        .init(row: 8, actions: ["SitAndLookUp", "SitWithLegsUp", "Sit"], flip: false, optional: true), // review
        .init(row: 9, actions: ["ClimbWall", "GrabWall"],             flip: false, optional: true), // climbing
    ]
}
