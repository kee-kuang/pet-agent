import Foundation

/// behaviors.xml 解析后的完整行为图:命名行为表 + 顶层文档序。
///
/// `topLevelOrder` 必须保 BehaviorList 文档序 —— 加权随机的线性累减按候选顺序命中区间,
/// 顺序变了同一随机值会落到不同行为,破坏对 Shimeji 原版的保真 + 测试确定性。
public struct ShimejiBehaviorGraph: Sendable, Equatable {
    /// name → behavior。
    public let behaviors: [String: ShimejiBehavior]

    /// 顶层 behavior 名(全局随机池迭代序 = BehaviorList 文档序)。
    /// 仅含顶层 `<Behavior>`(含 `<Condition>` 分组内的),不含纯转移目标。
    public let topLevelOrder: [String]

    public init(behaviors: [String: ShimejiBehavior], topLevelOrder: [String]) {
        self.behaviors = behaviors
        self.topLevelOrder = topLevelOrder
    }

    public func behavior(named name: String) -> ShimejiBehavior? {
        behaviors[name]
    }

    /// 两遍式校验第二遍:所有 NextBehavior 引用是否指向存在的 behavior。
    /// 返回**悬空引用名去重排序**(空 = 引用闭合)。解析允许前向悬空,运行前校验闭合。
    public func danglingReferences() -> [String] {
        var missing: Set<String> = []
        for behavior in behaviors.values {
            for ref in behavior.nextBehaviors where behaviors[ref.name] == nil {
                missing.insert(ref.name)
            }
        }
        return missing.sorted()
    }
}
