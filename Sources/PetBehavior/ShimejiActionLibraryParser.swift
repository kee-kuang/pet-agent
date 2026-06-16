import Foundation

/// actions.xml → `ShimejiActionLibrary` 全保真解析器(运行时执行用)。
///
/// 与 `ShimejiBehaviorParser` 同风格:手写 `XMLDocument` + `localName` 匹配绕命名空间;
/// 两遍式(解析允许前向悬空,`danglingReferences()` 第二遍校验)。
/// 覆盖真实包结构:多 `<ActionList>` 块、Sequence/Select 的 `<ActionReference>`(参数覆盖)与
/// **匿名内联 `<Action>`** 混排、多 `<Animation Condition>` 分支、`IsTurn`。
/// 声明的简化:`<Hotspot>`(鼠标交互区)与 Pose 的 `Sound/Volume`(音效)跳过 —— 当前不做
/// 点击热区与音频,接入时再补。
public enum ShimejiActionLibraryParser {
    /// 已知属性(进结构化字段),其余属性进 `params` 原文(每 tick 脚本求值)。
    private static let structuralAttributes: Set<String> = ["Name", "Type", "Class", "BorderType"]

    /// 解析 actions.xml。结构非法(无 ActionList)→ nil。
    public static func parse(_ data: Data) -> ShimejiActionLibrary? {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement()
        else { return nil }

        let lists = elementChildren(root).filter { $0.localName == "ActionList" }
        guard !lists.isEmpty else { return nil }

        var actions: [String: ShimejiActionDefinition] = [:]
        for list in lists {
            for actionElement in elementChildren(list) where actionElement.localName == "Action" {
                guard let action = parseAction(actionElement), !action.name.isEmpty else { continue }
                actions[action.name] = action
            }
        }
        return ShimejiActionLibrary(actions: actions)
    }

    // MARK: - Action

    /// 解析一个 `<Action>`(命名顶层或匿名内联)。`name` 缺省 ""(匿名内联)。
    private static func parseAction(_ el: XMLElement) -> ShimejiActionDefinition? {
        let name = attr(el, "Name") ?? ""
        let type = actionType(from: el)
        let borderType = attr(el, "BorderType").flatMap(ShimejiBorderType.init(rawValue:))
        let params = scriptParams(el)

        var animations: [ShimejiAnimation] = []
        var children: [ShimejiActionChild] = []
        for child in elementChildren(el) {
            switch child.localName {
            case "Animation":
                animations.append(parseAnimation(child))
            case "ActionReference":
                guard let refName = attr(child, "Name"), !refName.isEmpty else { continue }
                children.append(.reference(ShimejiActionReference(
                    name: refName,
                    paramOverrides: scriptParams(child)
                )))
            case "Action":
                if let inline = parseAction(child) {
                    children.append(.inline(inline))
                }
            default:
                continue   // Hotspot 等跳过(见文件头声明)
            }
        }

        return ShimejiActionDefinition(
            name: name,
            type: type,
            borderType: borderType,
            params: params,
            animations: animations,
            children: children
        )
    }

    /// `Type` → 枚举。Embedded 带 `Class` 原文;未知 Type 容错按 animate(能播动画不崩)。
    private static func actionType(from el: XMLElement) -> ShimejiActionType {
        switch attr(el, "Type") ?? "" {
        case "Stay": return .stay
        case "Move": return .move
        case "Animate", "": return .animate
        case "Sequence": return .sequence
        case "Select": return .select
        case "Embedded": return .embedded(className: attr(el, "Class") ?? "")
        default: return .animate
        }
    }

    /// 结构化属性之外的全部属性 → 参数原文表。
    private static func scriptParams(_ el: XMLElement) -> [String: String] {
        var params: [String: String] = [:]
        for attribute in el.attributes ?? [] {
            guard let key = attribute.localName ?? attribute.name,
                  !structuralAttributes.contains(key),
                  let value = attribute.stringValue
            else { continue }
            params[key] = value
        }
        return params
    }

    // MARK: - Animation / Pose

    private static func parseAnimation(_ el: XMLElement) -> ShimejiAnimation {
        let poses = elementChildren(el)
            .filter { $0.localName == "Pose" }
            .map(parsePose)
        return ShimejiAnimation(
            condition: attr(el, "Condition"),
            isTurn: (attr(el, "IsTurn")?.lowercased() == "true"),
            poses: poses
        )
    }

    private static func parsePose(_ el: XMLElement) -> ShimejiPose {
        let anchor = pair(attr(el, "ImageAnchor"))
        let velocity = pair(attr(el, "Velocity"))
        return ShimejiPose(
            image: normalizeImage(attr(el, "Image")),
            imageRight: normalizeImage(attr(el, "ImageRight")),
            imageAnchorX: anchor.0,
            imageAnchorY: anchor.1,
            velocityX: velocity.0,
            velocityY: velocity.1,
            durationTicks: max(Int(attr(el, "Duration") ?? "") ?? 1, 1)
        )
    }

    /// `"x,y"` → 数对(任一非法 → 0;Velocity 含 `${}` 表达式的极少数包此处降 0,执行器不崩)。
    private static func pair(_ raw: String?) -> (Double, Double) {
        guard let raw else { return (0, 0) }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (0, 0) }
        return (Double(parts[0]) ?? 0, Double(parts[1]) ?? 0)
    }

    /// 去前导 `/`(包内帧路径约定 `/shime1.png`)。
    private static func normalizeImage(_ raw: String?) -> String? {
        guard var path = raw, !path.isEmpty else { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    // MARK: - XML helpers

    private static func elementChildren(_ el: XMLElement) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue
    }
}
