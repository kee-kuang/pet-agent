import Foundation

/// 极简确定性 PRNG（SplitMix64）—— 给 `PetMotionController` 漫步选随机路点用。
///
/// 为什么自带而不用 `Double.random`:① 控制器是纯值类型,需**确定性**才能单测
/// (给定 seed → 固定序列);② SplitMix64 是公认高质量、零依赖、单步无状态依赖的
/// 64-bit 生成器,一行 next 足够覆盖「选个屏内 x」这种弱随机需求。
///
/// 值语义:`next()` 是 `mutating`,在 `PetMotionController.resolved` 的 `var next = self`
/// 副本上推进,随新控制器返回 → 纯函数式不破坏。
public struct PetMotionRandom: Sendable, Equatable {
    private var state: UInt64

    /// 默认 seed 取 SplitMix64 常用黄金比常数,保证非平凡初始序列。
    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.state = seed
    }

    /// 推进并返回下一个 64-bit 值(SplitMix64)。
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 推进并返回 [0, 1) 均匀分布 Double(取高 53 位,与 IEEE-754 尾数对齐)。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
