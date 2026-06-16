import Foundation

/// 行为/引用条件(`#{...}` / `${...}` 表达式)的求值器抽象。
///
/// 设计要点:调度器只问「此刻这条条件成立吗」,**完全不知道上下文形状**(mascot anchor /
/// environment 边界 / cursor / totalCount)。上下文绑定全交给求值器实现 ——
/// JavaScriptCore 求值器把 mascot/environment 桥进 JS 沙箱按帧构造;测试用字典桩。
/// 这样行为图调度(纯逻辑)与条件求值(需运行时上下文)彻底解耦,各自可独立演进/测试。
///
/// 非 `Sendable`:求值器是 `pickNext` 的同步参数(不被调度器存储、不跨 actor),JSC 实现持有
/// 非 Sendable 的 `JSContext`,每帧在 MainActor 上即用即弃。`Sendable` 会无谓挡住 JSC 实现。
public protocol ConditionEvaluator {
    /// 条件表达式是否成立。无法解析/求值的表达式由实现决定降级策略(JSC 实现倾向降级 false 或保守处理)。
    func isSatisfied(_ condition: String) -> Bool
}

/// 占位求值器:所有条件视为成立(= 忽略条件的纯 frequency 模式)。
///
/// ⚠️ 它**不产生**「按位置门控」的真实 Shimeji 行为(floor/wall/ceiling.isOn 那套需 JSC 求值器)。
/// 仅供:无条件包的纯频率调度 / 单测频率逻辑 / JSC 求值器未就位前的默认兜底。真实桌面行为需 JSC 求值器。
public struct AlwaysTrueConditionEvaluator: ConditionEvaluator {
    public init() {}
    public func isSatisfied(_ condition: String) -> Bool { true }
}
