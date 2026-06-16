import Foundation

/// 动作执行器的运行时基础:mascot 可变状态、tick 上下文、输出帧、中断、确定性 RNG。
/// 坐标 top-origin(与 BehaviorEnvironmentModel 一致)。1 tick = 40ms(Shimeji Manager.TICK_INTERVAL)。

/// mascot 可变状态(执行器内部唯一事实源)。
public final class ShimejiMascotState {
    /// 锚点(脚底/抓握点,世界坐标 top-origin)。
    public var anchor: BehaviorPoint
    /// 朝右(原图朝左约定;pose 应用时朝右取反 dx,渲染端取右向图/翻转)。
    public var lookRight: Bool
    /// 全局 tick 计数(动作局部时间 = time - startTime)。
    public var time: Int
    /// 用户拖拽中(Dragged/Regist 置位,释放→Thrown 清)。
    public var dragging: Bool

    public init(anchor: BehaviorPoint, lookRight: Bool = false, time: Int = 0, dragging: Bool = false) {
        self.anchor = anchor
        self.lookRight = lookRight
        self.time = time
        self.dragging = dragging
    }
}

/// 动作执行中断(Java LostGroundException 的 Swift 形态):脱离边界 → 引擎捕获强制转 Fall。
public enum ShimejiActionInterruption: Error {
    case lostGround
}

/// 配对互动请求(`ScanMove` 跑到目标邻居时产生)。引擎 tick 后消费:把自己切到 `selfBehavior`、
/// 把目标 pet(`targetID`)交 host 切到 `targetBehavior`(跨引擎,引擎够不到别的 mascot)。
public struct ShimejiPendingInteraction: Sendable, Equatable {
    public let selfBehavior: String
    public let targetBehavior: String
    public let targetID: String?
    public init(selfBehavior: String, targetBehavior: String, targetID: String?) {
        self.selfBehavior = selfBehavior
        self.targetBehavior = targetBehavior
        self.targetID = targetID
    }
}

/// 一次 tick 的执行上下文:状态 + 脚本引擎 + 当帧/上帧环境 + RNG + 当前姿势输出槽。
/// 引擎每 tick 装配;runtime 经它读写一切(不自持引用,免生命周期纠缠)。
public final class ShimejiTickContext {
    public let state: ShimejiMascotState
    public let engine: ShimejiScriptEngine
    /// 当帧环境快照。
    public var environment: BehaviorEnvironment
    /// 上帧环境快照(border.move 跟随窗口位移用;首帧 = 当帧)。
    public var previousEnvironment: BehaviorEnvironment
    /// 确定性 RNG(Dragged 延帧 quirk + 行为调度共用)。
    public var rng: ShimejiRandom
    /// 本 tick 应用的姿势(leaf runtime 写,引擎读出帧;无新姿势时保留上帧 → 帧可重复)。
    public var currentPose: ShimejiPose?
    /// `ScanMove` 到达目标时写入的配对请求;引擎 tick 末消费并清空。
    public var pendingInteraction: ShimejiPendingInteraction?

    public init(
        state: ShimejiMascotState,
        engine: ShimejiScriptEngine,
        environment: BehaviorEnvironment,
        rng: ShimejiRandom
    ) {
        self.state = state
        self.engine = engine
        self.environment = environment
        self.previousEnvironment = environment
        self.rng = rng
        self.currentPose = nil
    }

    /// 动作局部时间换算辅助(Java ActionBase.getTime 语义在 runtime 侧用)。
    public var mascotTime: Int { state.time }
}

/// 引擎每 tick 的输出帧:渲染端据此摆窗口 + 选图。
/// 窗口左上 = anchor − imageAnchor;`lookRight && imageRight == nil` 时渲染端水平翻转
/// image 且锚点 x 镜像(x' = imageWidth − imageAnchorX,需图宽,引擎不持图故由渲染端算)。
public struct ShimejiMascotFrame: Sendable, Equatable {
    public let anchor: BehaviorPoint
    public let lookRight: Bool
    /// 左向原图相对路径(nil = 无图/隐形帧,渲染端保持上帧)。
    public let image: String?
    /// 右向专用图(有则 lookRight 直接用,锚点不镜像)。
    public let imageRight: String?
    public let imageAnchorX: Double
    public let imageAnchorY: Double
    /// 当前行为名(诊断/测试)。
    public let behaviorName: String?

    public init(
        anchor: BehaviorPoint,
        lookRight: Bool,
        image: String?,
        imageRight: String?,
        imageAnchorX: Double,
        imageAnchorY: Double,
        behaviorName: String?
    ) {
        self.anchor = anchor
        self.lookRight = lookRight
        self.image = image
        self.imageRight = imageRight
        self.imageAnchorX = imageAnchorX
        self.imageAnchorY = imageAnchorY
        self.behaviorName = behaviorName
    }
}

/// 确定性 SplitMix64 RNG(与 RuntimeBridge.PetMotionRandom 同算法;PetBehavior deps[] 故
/// 独立一份,15 行不值引依赖)。`RandomNumberGenerator` 合规 → 可直接喂 `pickNext`。
public struct ShimejiRandom: RandomNumberGenerator, Sendable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0,1) 均匀。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
