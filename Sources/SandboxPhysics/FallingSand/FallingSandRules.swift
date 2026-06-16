/// 元素移动候选方向 + 相变阈值常量。参照 sandspiel 的 species.rs 重新实现的元素移动规则（逻辑级，未拷贝源码）：
/// - sand/snow: 下 → 下左/下右
/// - water: 下 → 下左/下右 → 左/右（分散）
/// - steam: 上 → 上左/上右
/// 温度采用现有 pile 温度场的归一化约定（0..1，约 (°C+20)/60）。
public enum FallingSandRules {

    /// 一个 (dx, dy) 偏移。dy = -1 是下，+1 是上。
    public typealias Offset = (dx: Int, dy: Int)

    /// 重力 pass 的候选目标，按优先级排序。`leftFirst` 每帧翻转以消除方向偏置。
    /// 返回空数组表示该元素不参与重力 pass。
    public static func gravityCandidates(_ s: FallingSandSpecies, leftFirst: Bool) -> [Offset] {
        let diag: [Offset] = leftFirst ? [(-1, -1), (1, -1)] : [(1, -1), (-1, -1)]
        let diagUp: [Offset] = leftFirst ? [(-1, 1), (1, 1)] : [(1, 1), (-1, 1)]
        switch s {
        case .snow:  return [(0, -1)] + diag
        case .water: return [(0, -1)] + diag
        case .steam: return [(0, 1)] + diagUp
        default:     return []   // ice/wall/empty 不动
        }
    }

    /// 水平漫流 pass 的候选（仅液体）。`leftFirst` 每帧翻转。
    public static func flowCandidates(_ s: FallingSandSpecies, leftFirst: Bool) -> [Offset] {
        guard s.isLiquid else { return [] }
        return leftFirst ? [(-1, 0), (1, 0)] : [(1, 0), (-1, 0)]
    }

    /// 雪下落概率。1.0 = 每帧确定性下落（1px 下平滑，去掉随机跳帧的抖动）。
    /// 真正的「轻飘慢落」需 per-cell 速度 + 亚像素渲染插值（1a，下一步专做）。
    public static let snowFallProbability: Float = 1.0

    // MARK: - 相变阈值（归一化温度 0..1）

    public static let meltThreshold: Float = 0.50     // snow/ice > 此值 → water
    public static let freezeThreshold: Float = 0.42   // water < 此值 → ice
    public static let evaporateThreshold: Float = 0.85 // water > 此值 → steam
    public static let condenseThreshold: Float = 0.55  // steam < 此值 → water

    public static let meltRatePerSec: Float = 3.0
    public static let freezeRatePerSec: Float = 2.0
    public static let evaporateRatePerSec: Float = 2.5
    public static let condenseRatePerSec: Float = 4.0

    /// steam 自然消散概率/秒（防无限堆积）。低速：steam 主要靠遇冷凝结回水，
    /// 只有 warm（temp > condenseThreshold）时才慢慢散掉，避免与凝结路径竞争。
    public static let steamDissipatePerSec: Float = 0.08

    /// 雪升华基础概率/秒（base，与深度无关）。孤立飞行雪靠这个缓慢消除。
    /// 真正的积雪平衡靠下面的**深度负反馈**项，不靠 base 调高。
    public static let snowSublimatePerSec: Float = 0.012

    /// 雪升华**深度系数** k（每单位列深、每秒额外升华概率）。这是积雪平衡的核心：
    /// 每个雪 cell 升华率 = base + k·columnDepth → 每列总移除 ≈ k·h² →
    /// 稳态 h* = √(S/k)（S=该列落雪率）。**spawn 速率翻倍深度只涨 √2 → 怎么调都自动收敛**，
    /// 根治「消融赶不上、越积越厚」。调大 k → 积雪更浅；调小 → 更厚。
    public static let snowDepthSublimateCoeff: Float = 0.0015
    /// steam lifetime 帧数（rb 计满后倾向凝结/消散）。
    public static let steamLifetimeFrames: UInt8 = 180
}
