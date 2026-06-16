import Foundation

/// actions.xml 的完整运行时动作模型(动作执行器的数据面)。
///
/// 与 `ShimejiImport.ShimejiActionsParser`(导入期:只取叶子动作首个动画的帧序拼 spritesheet)
/// 不同,这里是**全保真模型**:全部动作类型(Stay/Move/Animate/Sequence/Select/Embedded)、
/// 多 `<Animation Condition>` 分支、参数脚本原文(`Duration`/`TargetX`/`InitialVX`...每 tick
/// 求值)、ActionReference 参数覆盖、匿名内联子 Action。纯值类型,无头可测。
/// 语义来源:参照 Shimeji-Desktop 的 `config/ActionBuilder` + `action/*` 重新实现动作模型与执行公式
/// (逻辑级,未拷贝源码)。

/// 一帧姿势:`<Pose Image ImageAnchor Velocity Duration>`。
public struct ShimejiPose: Sendable, Equatable {
    /// 帧图相对路径(去前导 `/`,如 `shime1.png`)。nil = 隐形帧(合法,少见)。
    public let image: String?
    /// 右向专用图(`ImageRight`)。nil = 渲染端水平翻转 `image` 生成。
    public let imageRight: String?
    /// 图上与 mascot anchor 对齐的点(`ImageAnchor="x,y"`,图像坐标系,y 向下)。
    /// 窗口左上角 = anchor - imageAnchor;右向图锚点 x 镜像(width - x)。
    public let imageAnchorX: Double
    public let imageAnchorY: Double
    /// 每 tick 位移(`Velocity="dx,dy"`)。应用时朝右取反 dx(原图朝左约定)。
    public let velocityX: Double
    public let velocityY: Double
    /// 本姿势持续 tick 数(1 tick = 40ms)。
    public let durationTicks: Int

    public init(
        image: String?,
        imageRight: String? = nil,
        imageAnchorX: Double = 0,
        imageAnchorY: Double = 0,
        velocityX: Double = 0,
        velocityY: Double = 0,
        durationTicks: Int = 1
    ) {
        self.image = image
        self.imageRight = imageRight
        self.imageAnchorX = imageAnchorX
        self.imageAnchorY = imageAnchorY
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.durationTicks = durationTicks
    }
}

/// 一条动画分支:`<Animation [Condition] [IsTurn]>` + Pose 序列。
/// 动作每 tick 选**第一个**条件成立的分支;pose 按动作累计 tick 对 `durationTicks` 取模推进(自动循环)。
public struct ShimejiAnimation: Sendable, Equatable {
    /// 分支条件脚本原文(`#{}`/`${}`),nil = 无条件(恒选)。每 tick 重新求值。
    public let condition: String?
    /// `IsTurn="true"`:转向动画(Move 转向时插播)。
    public let isTurn: Bool
    public let poses: [ShimejiPose]

    /// 总时长 = Σ pose.durationTicks(pose 推进取模基)。
    public let durationTicks: Int

    public init(condition: String?, isTurn: Bool = false, poses: [ShimejiPose]) {
        self.condition = condition
        self.isTurn = isTurn
        self.poses = poses
        self.durationTicks = poses.reduce(0) { $0 + $1.durationTicks }
    }

    /// 按动作累计 tick 取当前 pose(Shimeji `Animation.getPoseAt`:对总时长取模 → 自动循环)。
    public func pose(atTick tick: Int) -> ShimejiPose? {
        guard durationTicks > 0, !poses.isEmpty else { return poses.first }
        var remaining = tick % durationTicks
        for pose in poses {
            remaining -= pose.durationTicks
            if remaining < 0 { return pose }
        }
        return poses.last
    }
}

/// 动作类型(`Type` 属性)。`embedded` 的 Java 类名保留原文,执行器按类名映射 Swift 运行时
/// (未知/多 mascot 类按其父类降级,见执行器)。
public enum ShimejiActionType: Sendable, Equatable {
    case stay
    case move
    case animate
    case sequence
    case select
    case embedded(className: String)
}

/// 边界类型(`BorderType` 属性):动作把 mascot 绑在哪类边上(init 时从环境解析出具体边)。
public enum ShimejiBorderType: String, Sendable, Equatable {
    case floor = "Floor"
    case wall = "Wall"
    case ceiling = "Ceiling"
}

/// Sequence/Select 的子项:命名引用(可带参数覆盖)或匿名内联动作。
public indirect enum ShimejiActionChild: Sendable, Equatable {
    case reference(ShimejiActionReference)
    case inline(ShimejiActionDefinition)
}

/// `<ActionReference Name [参数覆盖...]>`:引用命名动作,属性覆盖其同名参数
/// (如 `<ActionReference Name="Falling" InitialVX="${mascot.environment.cursor.dx}"/>`)。
public struct ShimejiActionReference: Sendable, Equatable {
    public let name: String
    /// 参数覆盖(脚本原文)。build 时 merge:目标动作 params ← 覆盖同名。
    public let paramOverrides: [String: String]

    public init(name: String, paramOverrides: [String: String] = [:]) {
        self.name = name
        self.paramOverrides = paramOverrides
    }
}

/// 一个 `<Action>` 定义(命名顶层或匿名内联)。
public struct ShimejiActionDefinition: Sendable, Equatable {
    /// 动作名。匿名内联子动作为 ""(不入库,仅作父动作子项)。
    public let name: String
    public let type: ShimejiActionType
    /// 边界绑定(Stay/Move/Animate/Turn 用)。
    public let borderType: ShimejiBorderType?
    /// 其余属性原文(Duration/Condition/TargetX/TargetY/InitialVX/InitialVY/Gravity/
    /// RegistanceX/RegistanceY/Loop/LookRight/X/Y/Draggable...)。值是脚本/字面量原文,
    /// 执行器每 tick 经脚本引擎求值(对齐 Shimeji `eval` 跨 tick 重求值语义)。
    public let params: [String: String]
    /// 动画分支(叶子动作用;Sequence/Select 无)。
    public let animations: [ShimejiAnimation]
    /// 子项(Sequence/Select 用;叶子无)。
    public let children: [ShimejiActionChild]

    public init(
        name: String,
        type: ShimejiActionType,
        borderType: ShimejiBorderType? = nil,
        params: [String: String] = [:],
        animations: [ShimejiAnimation] = [],
        children: [ShimejiActionChild] = []
    ) {
        self.name = name
        self.type = type
        self.borderType = borderType
        self.params = params
        self.animations = animations
        self.children = children
    }
}

/// actions.xml 解析产物:命名动作表(跨所有 `<ActionList>` 块合并)。
public struct ShimejiActionLibrary: Sendable, Equatable {
    public let actions: [String: ShimejiActionDefinition]

    public init(actions: [String: ShimejiActionDefinition]) {
        self.actions = actions
    }

    public func action(named name: String) -> ShimejiActionDefinition? {
        actions[name]
    }

    /// 两遍式第二遍:收集悬空 ActionReference(含嵌套 inline 内的)。空 = 引用闭合。
    public func danglingReferences() -> [String] {
        var missing: Set<String> = []
        for action in actions.values {
            collectDangling(in: action.children, into: &missing)
        }
        return missing.sorted()
    }

    private func collectDangling(in children: [ShimejiActionChild], into missing: inout Set<String>) {
        for child in children {
            switch child {
            case .reference(let ref):
                if actions[ref.name] == nil { missing.insert(ref.name) }
            case .inline(let def):
                collectDangling(in: def.children, into: &missing)
            }
        }
    }
}
