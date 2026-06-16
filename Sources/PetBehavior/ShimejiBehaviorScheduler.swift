import Foundation

/// 数据驱动行为状态机:按 Shimeji 的加权随机 + NextBehavior 转移图选下一个行为。
///
/// 参照 Shimeji-Desktop 的 `Configuration.buildNextBehavior` 重新实现行为选取逻辑(逻辑级,未拷贝源码)。
/// 纯函数 + 注入式 RNG / `ConditionEvaluator` → 完全确定性可测,无副作用、不碰 AppKit。
/// `pickNext` 对 `RandomNumberGenerator` 泛型:生产可传 `SystemRandomNumberGenerator`(真随机)
/// 或种子 RNG(可复现);测试传种子/脚本 RNG 验证分布。
public struct ShimejiBehaviorScheduler: Sendable {
    public let graph: ShimejiBehaviorGraph

    /// `totalFrequency==0` 时的兜底行为名。Shimeji 语义:重定位到屏顶 + 下落(`Fall`);
    /// 重定位是运动副作用(由运动控制器在接入时落地),调度器只回名字。
    public let fallbackBehaviorName: String

    public init(graph: ShimejiBehaviorGraph, fallbackBehaviorName: String = "Fall") {
        self.graph = graph
        self.fallbackBehaviorName = fallbackBehaviorName
    }

    /// 选下一个行为名。
    ///
    /// 候选 = `(previous==nil || previous.nextAdditive ? 全局池 effective : [])` + `previous.refs effective`,
    /// 权重 = behavior.frequency(全局池)/ ref.frequency(转移)。`effective` = frequency>0 且条件链全成立。
    /// 候选按「全局池(文档序)→ 转移引用(声明序)」拼接,`r ∈ [0,total)` 线性累减命中第一个区间。
    /// 全空(total==0)→ `fallbackBehaviorName`。
    ///
    /// - Parameters:
    ///   - previous: 上一个行为名(`nil` = 初始,等价 nextAdditive 全局池)。
    ///   - evaluator: 条件求值器(占位桩 / JSC)。
    ///   - rng: 随机源(inout,消耗其状态)。
    public func pickNext(
        previous: String?,
        evaluator: ConditionEvaluator,
        using rng: inout some RandomNumberGenerator
    ) -> String {
        var candidates: [(name: String, weight: Int)] = []
        var total = 0

        let prev = previous.flatMap { graph.behavior(named: $0) }

        // 全局池:prev 为空 或 prev 允许 additive 转移时,纳入所有 effective 顶层行为。
        if prev == nil || prev?.nextAdditive == true {
            for name in graph.topLevelOrder {
                guard let behavior = graph.behavior(named: name),
                      isEffective(frequency: behavior.frequency, conditions: behavior.conditions, evaluator: evaluator)
                else { continue }
                candidates.append((name, behavior.frequency))
                total += behavior.frequency
            }
        }

        // 转移引用:权重用 ref 自己的 frequency(故 freq=0 的目标行为仍可经 ref 被选)。
        if let prev {
            for ref in prev.nextBehaviors
            where isEffective(frequency: ref.frequency, conditions: ref.conditions, evaluator: evaluator) {
                candidates.append((ref.name, ref.frequency))
                total += ref.frequency
            }
        }

        guard total > 0 else { return fallbackBehaviorName }

        // r ∈ [0,total):累计权重首次 > r 的候选命中(等价 Java 的 `r -= w; if r<0`)。
        let r = Int.random(in: 0..<total, using: &rng)
        var cumulative = 0
        for candidate in candidates {
            cumulative += candidate.weight
            if r < cumulative { return candidate.name }
        }
        return candidates.last?.name ?? fallbackBehaviorName   // 防御:浮点/边界兜底,正常不可达
    }

    /// effective = frequency>0 且条件链全部成立。frequency==0 直接禁用(对齐 `isEffective`)。
    private func isEffective(frequency: Int, conditions: [String], evaluator: ConditionEvaluator) -> Bool {
        guard frequency > 0 else { return false }
        for condition in conditions where !evaluator.isSatisfied(condition) { return false }
        return true
    }
}
