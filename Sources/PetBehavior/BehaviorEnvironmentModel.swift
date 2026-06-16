import Foundation

/// Shimeji 条件表达式读取的桌面/mascot 状态值模型。
///
/// **坐标约定**:沿用 Shimeji 原生 **top-origin**(y 向下,top < bottom,floor=bottom 边=视觉底)
/// —— 条件表达式(`mascot.environment.floor.isOn(...)` 那套)就是为它写的,沿用其坐标约定重新实现派生逻辑最保真。
/// 本仓桌面是 bottom-origin,**翻转映射由 `DesktopEnvironmentProvider` 负责**(填充本模型时做)。
/// 纯值类型,与求值器(JSC)解耦 —— 本文件不 import JavaScriptCore。

/// 一个点(mascot anchor / cursor)。
public struct BehaviorPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 一块矩形区域(workArea / activeWindow / screen)。top-origin:`top < bottom`。
/// 四条边(leftBorder/rightBorder/topBorder/bottomBorder)+ `isOn` 语义在 JS 侧按 Shimeji
/// `Wall`/`FloorCeiling.isOn` 生成(见 `JSConditionEvaluator`)。
public struct BehaviorArea: Sendable, Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    /// 不可见区域(如无活动窗口)→ 所有 `isOn` 恒 false(对齐 Shimeji `area.isVisible()` 门控)。
    public var visible: Bool

    public init(left: Double, top: Double, right: Double, bottom: Double, visible: Bool = true) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.visible = visible
    }

    public var width: Double { right - left }
    public var height: Double { bottom - top }

    /// 不可见空区域(无活动窗口时的 activeWindow 占位)。
    public static let invisible = BehaviorArea(left: 0, top: 0, right: 0, bottom: 0, visible: false)
}

/// 光标:位置 + 半衰平均速度(Shimeji `Location`:`dx=(dx+Δx)/2` 指数平滑,Thrown 初速来源)。
public struct BehaviorCursor: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var dx: Double
    public var dy: Double

    public init(x: Double = 0, y: Double = 0, dx: Double = 0, dy: Double = 0) {
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
    }
}

/// 互动目标邻居快照(多宠互动 Hug 等)。host 每帧为「正在扫描某 affordance 的 mascot」匹配到一只
/// **正在广播该 affordance 的最近邻居**,注入其 env.scanTarget;无匹配 → nil。坐标 top-origin。
/// `ScanMove` 动作据此跑过去,到达时触发配对行为(自己切 Behavior、目标切 TargetBehavior)。
public struct BehaviorPeer: Sendable, Equatable {
    /// 邻居 pet id(配对时 host 据此把目标 pet 切到 TargetBehavior)。
    public var id: String?
    /// 邻居锚点(脚底中心,top-origin 世界坐标)。
    public var anchor: BehaviorPoint
    /// 邻居正在广播的 affordance(`ScanMove` 按自身 Affordance 参数与之匹配,如 "Hug")。
    public var affordance: String?

    public init(id: String? = nil, anchor: BehaviorPoint, affordance: String? = nil) {
        self.id = id
        self.anchor = anchor
        self.affordance = affordance
    }
}

/// 桌面环境:工作区 + 活动窗口(activeIE)+ 屏幕 + 光标 + 最近邻居。floor/ceiling/wall 是**派生边**
/// (依 anchor 在 JS 侧算出当前所站的边或 NotOnBorder),不在此存。
public struct BehaviorEnvironment: Sendable, Equatable {
    /// 工作区(屏幕减 Dock/菜单栏)。
    public var workArea: BehaviorArea
    /// 活动窗口(Shimeji 的 activeIE)。无活动窗口 → `.invisible`。
    public var activeWindow: BehaviorArea
    /// 屏幕(全显示器并集)。
    public var screen: BehaviorArea
    /// 光标(位置 + 半衰速度)。条件(`cursor.y < screen.height/2`)与 Thrown 初速用。
    public var cursor: BehaviorCursor
    /// 多宠互动:host 为本 mascot 的 `ScanMove` 匹配到的目标邻居(无 → nil,单宠时恒 nil → 互动零触发)。
    public var scanTarget: BehaviorPeer?

    public init(
        workArea: BehaviorArea,
        activeWindow: BehaviorArea,
        screen: BehaviorArea,
        cursor: BehaviorCursor = BehaviorCursor(),
        scanTarget: BehaviorPeer? = nil
    ) {
        self.workArea = workArea
        self.activeWindow = activeWindow
        self.screen = screen
        self.cursor = cursor
        self.scanTarget = scanTarget
    }
}

/// mascot 视图:条件表达式的求值上下文。`#{mascot.anchor.y > 100}` / `mascot.lookRight ? ...`。
public struct BehaviorMascot: Sendable, Equatable {
    /// 锚点(脚底中心,世界坐标 top-origin)。
    public var anchor: BehaviorPoint
    /// 朝向右(影响 `wall` 派生取左/右边 + 条件里的 `mascot.lookRight ? ...`)。
    public var lookRight: Bool
    /// 当前桌宠总数(`mascot.totalCount < 50` 那类分裂上限条件)。
    public var totalCount: Int
    /// 桌面环境。
    public var environment: BehaviorEnvironment

    public init(anchor: BehaviorPoint, lookRight: Bool, totalCount: Int, environment: BehaviorEnvironment) {
        self.anchor = anchor
        self.lookRight = lookRight
        self.totalCount = totalCount
        self.environment = environment
    }
}
