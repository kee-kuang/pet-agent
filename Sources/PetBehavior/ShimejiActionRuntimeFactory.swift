import Foundation

/// 动作定义 → 运行时工厂。复合动作的子运行时**构造期即递归建好**(对齐 Java buildAction 期
/// 构造子 Action),自引用包用深度防护拦下(返回空 Animate,不崩)。
///
/// Embedded Java 类名 → Swift 运行时映射;多 mascot/IE 类**按父类降级**
/// (Breed→Animate / WalkWithIE→Move / FallWithIE→Fall...,声明的简化:无繁殖/广播/IE 窗口抓取)。
public struct ShimejiActionRuntimeFactory {
    public let library: ShimejiActionLibrary

    /// 嵌套构造深度上限(正常包 <6;自引用 Sequence 会无限递归,拦下)。
    private static let maxDepth = 16

    public init(library: ShimejiActionLibrary) {
        self.library = library
    }

    /// 按动作名建运行时(行为 actionName 入口)。未知名 → nil。
    public func makeRuntime(actionNamed name: String) -> ShimejiActionRuntime? {
        guard let def = library.action(named: name) else { return nil }
        return makeRuntime(for: def, depth: 0)
    }

    /// 按定义建运行时(参数覆盖已合并的 definition)。
    public func makeRuntime(for definition: ShimejiActionDefinition, depth: Int = 0) -> ShimejiActionRuntime {
        guard depth < Self.maxDepth else {
            // 自引用/超深嵌套:降级为空 Animate(无动画 → hasNext false → 立即结束,不崩不卡)。
            return ShimejiAnimateRuntime(definition: ShimejiActionDefinition(name: definition.name, type: .animate))
        }

        switch definition.type {
        case .stay:
            return ShimejiStayRuntime(definition: definition)
        case .move:
            return ShimejiMoveRuntime(definition: definition)
        case .animate:
            return ShimejiAnimateRuntime(definition: definition)
        case .sequence:
            return ShimejiSequenceRuntime(definition: definition, children: makeChildren(of: definition, depth: depth))
        case .select:
            return ShimejiSelectRuntime(definition: definition, children: makeChildren(of: definition, depth: depth))
        case .embedded(let className):
            return makeEmbedded(className: className, definition: definition, depth: depth)
        }
    }

    private func makeChildren(of definition: ShimejiActionDefinition, depth: Int) -> [ShimejiActionRuntime] {
        definition.children.map { child in
            switch child {
            case .inline(let inlineDef):
                return makeRuntime(for: inlineDef, depth: depth + 1)
            case .reference(let ref):
                guard let target = library.action(named: ref.name) else {
                    // 悬空引用(已被 danglingReferences 预警):空 Animate 占位,立即结束。
                    return ShimejiAnimateRuntime(definition: ShimejiActionDefinition(name: ref.name, type: .animate))
                }
                return makeRuntime(for: merged(target, overrides: ref.paramOverrides), depth: depth + 1)
            }
        }
    }

    /// ≙ Java `ActionBuilder.createVariables`:目标动作 params ← 引用覆盖同名。
    private func merged(
        _ target: ShimejiActionDefinition,
        overrides: [String: String]
    ) -> ShimejiActionDefinition {
        guard !overrides.isEmpty else { return target }
        let params = target.params.merging(overrides) { _, override in override }
        return ShimejiActionDefinition(
            name: target.name,
            type: target.type,
            borderType: target.borderType,
            params: params,
            animations: target.animations,
            children: target.children
        )
    }

    /// Embedded Java 类名(取末段)→ Swift 运行时;未知/多 mascot 类按父类降级。
    private func makeEmbedded(
        className: String,
        definition: ShimejiActionDefinition,
        depth: Int
    ) -> ShimejiActionRuntime {
        let simpleName = className.split(separator: ".").last.map(String.init) ?? className
        switch simpleName {
        case "Fall", "FallWithIE":
            return ShimejiFallRuntime(definition: definition)
        case "Jump", "BreedJump", "ScanJump":
            return ShimejiJumpRuntime(definition: definition)
        case "Dragged":
            return ShimejiDraggedRuntime(definition: definition)
        case "Regist":
            return ShimejiRegistRuntime(definition: definition)
        case "Look":
            return ShimejiLookRuntime(definition: definition)
        case "Offset":
            return ShimejiOffsetRuntime(definition: definition)
        case "WalkWithIE", "RunWithIE", "BreedMove", "BroadcastMove", "MoveWithTurn":
            return ShimejiMoveRuntime(definition: definition)
        case "BroadcastStay":
            return ShimejiStayRuntime(definition: definition)
        case "ScanMove", "ScanInteract":
            // 多宠互动:跑向广播 affordance 的邻居 → 到达配对(Hug 系)。
            return ShimejiScanMoveRuntime(definition: definition)
        default:
            // Breed/Broadcast/Interact/Transform/SelfDestruct/Mute/ThrowIE... → Animate 降级
            // (播动画,无副作用)。Broadcast=Animate + affordance 由引擎从 leaf 参数读出;
            // Interact=Animate(播配对动画,配对切换由 ScanMove 触发)。
            return ShimejiAnimateRuntime(definition: definition)
        }
    }
}
