import Foundation

/// behaviors.xml → `ShimejiBehaviorGraph` 解析器。
///
/// 手写 `XMLDocument` 树遍历(与本仓 `ShimejiActionsParser` 同风格,沿用 `localName` 匹配绕过
/// 默认命名空间 `xmlns="http://www.group-finity.com/Mascot"`)。递归累积 `<Condition>` 分组的
/// AND-条件链。**两遍式**:本解析器只建符号表(允许前向悬空引用),引用闭合校验由
/// `ShimejiBehaviorGraph.danglingReferences()` 第二遍做。
public enum ShimejiBehaviorParser {
    /// 解析 behaviors.xml 数据。结构非法(无 Mascot/BehaviorList)→ nil。
    public static func parse(_ data: Data) -> ShimejiBehaviorGraph? {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement(),
              let behaviorList = firstChild(of: root, localName: "BehaviorList")
        else { return nil }

        var behaviors: [String: ShimejiBehavior] = [:]
        var order: [String] = []
        collectBehaviors(in: behaviorList, inheritedConditions: [], into: &behaviors, order: &order)
        return ShimejiBehaviorGraph(behaviors: behaviors, topLevelOrder: order)
    }

    // MARK: - 递归收集

    /// 遍历 `<BehaviorList>` / `<Condition>` 容器,收集 `<Behavior>` 叶子,沿途累积条件链。
    private static func collectBehaviors(
        in container: XMLElement,
        inheritedConditions: [String],
        into behaviors: inout [String: ShimejiBehavior],
        order: inout [String]
    ) {
        for child in elementChildren(container) {
            switch child.localName {
            case "Condition":
                let chain = inheritedConditions + conditionAttr(child)
                collectBehaviors(in: child, inheritedConditions: chain, into: &behaviors, order: &order)
            case "Behavior":
                guard let behavior = parseBehavior(child, inheritedConditions: inheritedConditions) else { continue }
                if behaviors[behavior.name] == nil { order.append(behavior.name) }
                behaviors[behavior.name] = behavior
            default:
                continue
            }
        }
    }

    private static func parseBehavior(_ el: XMLElement, inheritedConditions: [String]) -> ShimejiBehavior? {
        guard let name = attr(el, "Name"), !name.isEmpty else { return nil }
        let actionName = attr(el, "Action").flatMap { $0.isEmpty ? nil : $0 } ?? name
        let frequency = Int(attr(el, "Frequency") ?? "") ?? 0
        let hidden = isTrue(attr(el, "Hidden"))
        let conditions = inheritedConditions + conditionAttr(el)

        var nextAdditive = true
        var refs: [ShimejiBehaviorReference] = []
        if let nextBehavior = firstChild(of: el, localName: "NextBehavior") {
            nextAdditive = isTrue(attr(nextBehavior, "Add"), default: true)
            collectRefs(in: nextBehavior, inheritedConditions: [], into: &refs)
        }

        return ShimejiBehavior(
            name: name,
            actionName: actionName,
            frequency: frequency,
            hidden: hidden,
            conditions: conditions,
            nextAdditive: nextAdditive,
            nextBehaviors: refs
        )
    }

    /// 遍历 `<NextBehavior>` / 其内 `<Condition>` 容器,收集 `<BehaviorReference>`,累积条件链。
    private static func collectRefs(
        in container: XMLElement,
        inheritedConditions: [String],
        into refs: inout [ShimejiBehaviorReference]
    ) {
        for child in elementChildren(container) {
            switch child.localName {
            case "Condition":
                let chain = inheritedConditions + conditionAttr(child)
                collectRefs(in: child, inheritedConditions: chain, into: &refs)
            case "BehaviorReference":
                guard let name = attr(child, "Name"), !name.isEmpty else { continue }
                refs.append(ShimejiBehaviorReference(
                    name: name,
                    frequency: Int(attr(child, "Frequency") ?? "") ?? 0,
                    conditions: inheritedConditions + conditionAttr(child),
                    hidden: isTrue(attr(child, "Hidden"))
                ))
            default:
                continue
            }
        }
    }

    // MARK: - XML helpers

    private static func elementChildren(_ el: XMLElement) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func firstChild(of el: XMLElement, localName: String) -> XMLElement? {
        elementChildren(el).first { $0.localName == localName }
    }

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue
    }

    /// 元素自身的 `Condition` 属性 → 单元素数组(便于 `+` 拼链);无则空。
    private static func conditionAttr(_ el: XMLElement) -> [String] {
        guard let c = attr(el, "Condition"), !c.isEmpty else { return [] }
        return [c]
    }

    private static func isTrue(_ raw: String?, default defaultValue: Bool = false) -> Bool {
        guard let raw else { return defaultValue }
        return raw.lowercased() == "true"
    }
}
