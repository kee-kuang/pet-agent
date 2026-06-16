import Context
import Foundation

// MARK: - PetMotion 值类型
//
// 形象无关的运动语汇 —— pet 空间运动子系统的地基:位置与形象表现解耦,
// 同一套运动态被所有 renderer 复用。
// `PetMotionController` 每帧消费上游 cursor-follow 候选位置,按模式
// 仲裁出最终「位置 + 朝向 + 运动态」;各 renderer 自行表现(sprite 切走帧 /
// Orb 平移 squash / Live2D 复用),互不知道彼此存在。
//
// 这些类型住在 RuntimeBridge(纯 Swift,form-agnostic,退役 Rust 后的运动 runtime
// 归属),被 Rendering(PetRenderer 协议)与 App(帧循环接入)共同消费。

/// pet 运动模式 —— `PetMotionController` 的状态机模式。仲裁优先级:
/// `dragged` > `perched` > `roaming` > `physics`(高优先覆盖低优先)。
public enum PetMotionMode: Sendable, Equatable {
    /// 默认回落:跟随光标 / 拖拽释放后回落。当前位置由上游 cursor-follow
    /// 候选直接提供(恒速朝光标移动的逻辑见 `LocalRuntimeClient`)。
    case physics
    /// 空闲自主游走。
    case roaming
    /// 沿窗口侧边向上攀爬中 —— 到顶后转 `.perched`。
    case climbing
    /// 锚定某窗口顶边。
    case perched
    /// 用户拖拽跟手。由 Shell 拖拽路径直接驱动(拖拽会 bump
    /// `shellInteractionVersion` 短路当帧 runtime 循环),控制器不参与。
    case dragged
}

/// pet 朝向 —— 由水平位移符号决定。驱动 sprite 走帧 `running-left/right`;
/// Orb / 无方向形象忽略。
public enum PetFacing: Sendable, Equatable {
    case left
    case right
}

/// 形象无关的运动态 —— `PetMotionController` 每帧产出。各 renderer 通过
/// `PetRenderer.updateForMotion(_:)` 收到后自行决定表现。
public enum PetMotionPhase: Sendable, Equatable {
    /// 静止(帧间位移低于阈值)。
    case idle
    /// 行走中,带朝向(cursor-follow 追光标 / 自主漫步)。
    case walking(PetFacing)
    /// 沿窗口侧边向上攀爬中。`PetFacing` = 面朝的墙一侧(贴左边=面右/`.right`),
    /// 供 sprite 镜像、Live2D 抓握倾向。
    case climbing(PetFacing)
    /// 站在窗口顶边。
    case perching
    /// 自由下落 / 弹跳(垂直向下主导的物理回落)。
    case falling
}

/// 每帧喂给 `PetMotionController.resolved(physicsCandidate:input:)` 的输入快照。
/// 纯数据,无副作用,便于单测。坐标系统一为「屏幕底原点 y-up 世界坐标」
/// (与 `syncPetPosition` 落地的 NSWindow origin 同系)。
public struct PetMotionInput: Sendable, Equatable {
    /// 帧间隔秒。
    public let deltaTime: Double
    /// 光标世界坐标。
    public let cursorPosition: Point
    /// 当前可见窗口矩形(已过滤壁纸窗口、已翻成底原点)。爬窗用;跟随 / 漫步态可空。
    public let windows: [Rect]
    /// 可活动的屏幕边界(底原点 y-up)。漫步 clamp / 回落地面用。
    public let screenBounds: Rect
    /// 用户最后一次键鼠输入距今秒数(0 = 刚活跃)。漫步 / 爬窗触发阈值。
    public let idleSeconds: Double
    /// 「跟随光标」开关:开 → 用户活跃时 pet 追光标;关 → 不追(原地或纯漫游)。
    public let followingEnabled: Bool
    /// 「桌面漫游」开关:开 → pet 自主漫步 + 爬窗(跟随关 → 连续漫游;跟随开 → 空闲才漫游)。
    public let roamingEnabled: Bool
    /// 活跃度 0..1(由 pet 情绪态推:happy/talking 高、calm/thinking 低)。给自主漫步加情绪:
    /// 高 → 暂停短、走得快(活泼);低 → 暂停长、走得慢(慵懒)。默认 0.5 中性。参考 GodotDesktopPet
    /// 的 mood-weighted 动作选择(只借思路)。
    public let liveliness: Double

    public init(
        deltaTime: Double,
        cursorPosition: Point,
        windows: [Rect] = [],
        screenBounds: Rect = .zero,
        idleSeconds: Double = 0,
        followingEnabled: Bool = true,
        roamingEnabled: Bool = true,
        liveliness: Double = 0.5
    ) {
        self.deltaTime = deltaTime
        self.cursorPosition = cursorPosition
        self.windows = windows
        self.screenBounds = screenBounds
        self.idleSeconds = idleSeconds
        self.followingEnabled = followingEnabled
        self.roamingEnabled = roamingEnabled
        self.liveliness = liveliness
    }
}

/// `PetMotionController.resolved` 每帧产出:最终位置 + 朝向运动态 + 当前模式。
/// `mode` 供诊断 / 测试断言(行为只依赖 `position` + `phase`)。
public struct PetMotionFrame: Sendable, Equatable {
    public let position: Point
    public let rotation: Double
    public let phase: PetMotionPhase
    public let mode: PetMotionMode

    public init(
        position: Point,
        rotation: Double = 0,
        phase: PetMotionPhase,
        mode: PetMotionMode
    ) {
        self.position = position
        self.rotation = rotation
        self.phase = phase
        self.mode = mode
    }
}
