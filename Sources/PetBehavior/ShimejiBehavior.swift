import Foundation

/// 单个 `<Behavior>` 的不可变值模型(解析自 behaviors.xml)。
///
/// Shimeji 行为图的节点:一个命名行为 + 它的随机权重、条件门控、关联动作、以及完成后
/// 的转移候选(NextBehavior)。纯值类型,无副作用,可无头单测。
public struct ShimejiBehavior: Sendable, Equatable {
    /// 行为名(BehaviorList 内唯一,转移引用按名查)。
    public let name: String

    /// 关联动作名(`Action` 属性,缺省 = `name`)。映射到 actions.xml 的动作帧序;运动/sprite 在接入运动层时落成。
    public let actionName: String

    /// 全局随机池权重。`0` = 不进随机池(只能作 NextBehavior 转移目标,如 `SitAndFaceMouse`
    /// 顶层 Frequency=0 但经 ref Frequency=100 高频转移)。
    public let frequency: Int

    /// `Hidden="true"`:不主动从随机池选,但可作转移目标 / 引擎特殊态(Fall/Dragged/Thrown)触发。
    public let hidden: Bool

    /// 条件 AND-链(外层 `<Condition>` 分组继承 + 自身 `Condition` 属性,**原始表达式串**未求值)。
    /// 全部成立才 effective。求值交给注入的 `ConditionEvaluator`(JSC 求值器;占位桩)。
    public let conditions: [String]

    /// `<NextBehavior Add>`:`true` = 转移候选 ∪ 全局池;`false` = 只在本行为的转移候选里选。
    /// 缺省 `true`(对齐 Shimeji `BehaviorBuilder` 默认)。
    public let nextAdditive: Bool

    /// 完成后的加权转移目标引用(各自带 frequency + 条件链)。空 = 无显式转移(靠 nextAdditive 回全局池)。
    public let nextBehaviors: [ShimejiBehaviorReference]

    public init(
        name: String,
        actionName: String,
        frequency: Int,
        hidden: Bool,
        conditions: [String],
        nextAdditive: Bool,
        nextBehaviors: [ShimejiBehaviorReference]
    ) {
        self.name = name
        self.actionName = actionName
        self.frequency = frequency
        self.hidden = hidden
        self.conditions = conditions
        self.nextAdditive = nextAdditive
        self.nextBehaviors = nextBehaviors
    }
}

/// `<NextBehavior>` 内的 `<BehaviorReference>`:指向某 Behavior 的加权转移引用。
///
/// 关键语义:转移权重用 **ref 自己的 `frequency`**,不是目标 behavior 的 —— 故 frequency=0
/// 的 behavior(不进全局随机池)仍可经 ref 高权重被转移到。条件链同理(外层继承 + 自身)。
public struct ShimejiBehaviorReference: Sendable, Equatable {
    /// 目标行为名(两遍式校验须指向存在的 behavior)。
    public let name: String

    /// 转移权重(`0` = 此转移禁用)。
    public let frequency: Int

    /// 条件 AND-链(NextBehavior 内 `<Condition>` 分组继承 + 自身 `Condition` 属性)。
    public let conditions: [String]

    /// `Hidden` 标记(ref 上少见,保真保留)。
    public let hidden: Bool

    public init(name: String, frequency: Int, conditions: [String], hidden: Bool) {
        self.name = name
        self.frequency = frequency
        self.conditions = conditions
        self.hidden = hidden
    }
}
