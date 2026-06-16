import QuartzCore
import CoreGraphics
import RuntimeBridge

// MARK: - PetRenderer
//
// 抽象桌宠视觉本体.
//
// `DesktopShellController.makePetWindow` 当前用一个橙色 placeholder NSView
// 当 contentView. 这里定义 protocol, 让 main agent 之后能把 OrbMetalRenderer
// 或 PetPlaceholderRenderer 任意一个挂上去, 而不必修改 shell 拼装代码.
//
// ## 为什么 ChatBehaviorState 不在 Rendering 里 ?
//
// `Orchestrator` -> `Rendering` 已经存在 (见 Package.swift), 反向再加
// `Rendering -> Orchestrator` 会成环. 所以 PetRenderer protocol 暴露的状态
// 是本地 `PetEmotionState` 镜像枚举. Main agent 在 Shell/Orchestrator 层
// 写一行 `ChatBehaviorState -> PetEmotionState` 适配即可.

/// 五态情绪枚举, 与 Orchestrator 的 ChatBehaviorState 对应 (镜像, 防止
/// Rendering 反向依赖 Orchestrator). main agent wiring 时写一个 1:1 适配:
///
/// ```swift
/// extension PetEmotionState {
///     static func from(_ s: ChatBehaviorState) -> PetEmotionState {
///         switch s {
///         case .idle:     return .idle
///         case .watching: return .watching
///         case .thinking: return .thinking
///         case .talking:  return .talking
///         case .confused: return .confused
///         }
///     }
/// }
/// ```
public enum PetEmotionState: Equatable, Sendable {
    case idle
    case watching
    case thinking
    case talking
    case confused
}

/// pet 当前帧 alpha 轮廓 mask（喂 falling-sand `fs_rasterize_pet`，
/// 雪堆 pet 身上）。`mask` 为 `w×h` 行主序 alpha（0..255），**row 0 = sprite 顶部**
/// （CGImage top-left 行序，Y 翻转在 GPU kernel 内做，渲染层不翻）。1 mask cell =
/// 1 FS world cell（按 cellSize 下采样到 pet footprint）。Orb 等无轮廓形象返回 nil。
public struct PetAlphaMask: Equatable, Sendable {
    public var mask: [UInt8]
    public var width: Int
    public var height: Int
    public init(mask: [UInt8], width: Int, height: Int) {
        self.mask = mask
        self.width = width
        self.height = height
    }
}

/// Uniform 包, 喂给 Orb fragment shader.
///
/// 字段单位 / 含义:
/// - `colorHue`: 主体流光色相 (0 - 1 归一化 hue 环, 见 §1.2 oklch 设计)
///   * 0.55 蓝绿 / 0.50 蓝 / 0.75 紫 / 0.30 暖橙 / 0.05 红橙
/// - `flowSpeed`: 内部 cosine 流光 phase 推进速率 (rad/s 量级因子)
///   * 0.3 静止呼吸 / 2.0 急涡旋
/// - `vortexIntensity`: 第二层 vortex 流光叠加强度 (0 - 1)
/// - `squashX`: 沿 X 轴形变系数 (1.0 = 圆球, > 1.0 沿 X 拉长, < 1.0 沿 X 压扁)
/// - `squashY`: 沿 Y 轴形变系数 (同上, talking burst 时 0.92 静态压扁)
///
/// 形变 (squashX / squashY) 同时被 chat 五态 (talking 时垂直压脉冲) 和
/// 物理速度 (`updateForVelocity`) 写入. 拖动期间速度耦合短暂覆盖五态 base
/// 值; 速度归零后 ease 自动回到五态 target (物理形变耦合).
public struct OrbUniforms: Equatable, Sendable {
    public var colorHue: Float
    public var flowSpeed: Float
    public var vortexIntensity: Float
    public var squashX: Float
    public var squashY: Float

    public init(
        colorHue: Float,
        flowSpeed: Float,
        vortexIntensity: Float,
        squashX: Float = 1.0,
        squashY: Float
    ) {
        self.colorHue = colorHue
        self.flowSpeed = flowSpeed
        self.vortexIntensity = vortexIntensity
        self.squashX = squashX
        self.squashY = squashY
    }
}

extension OrbUniforms {
    /// 状态 → uniforms 静态映射. 纯函数, 不依赖 GPU 设备, 方便单测.
    ///
    /// 设计基线: 五态(idle/watching/thinking/talking/confused)→ uniforms 状态映射表.
    /// squashX 五态都是 1.0; X 轴形变只由物理速度 (`updateForVelocity`)
    /// 临时驱动, 不在五态 base 表达里.
    public static func target(for state: PetEmotionState) -> OrbUniforms {
        switch state {
        case .idle:
            return OrbUniforms(
                colorHue: 0.55,
                flowSpeed: 0.3,
                vortexIntensity: 0.2,
                squashX: 1.0,
                squashY: 1.0
            )
        case .watching:
            return OrbUniforms(
                colorHue: 0.50,
                flowSpeed: 0.5,
                vortexIntensity: 0.3,
                squashX: 1.0,
                squashY: 1.0
            )
        case .thinking:
            return OrbUniforms(
                colorHue: 0.75,
                flowSpeed: 1.5,
                vortexIntensity: 0.8,
                squashX: 1.0,
                squashY: 1.0
            )
        case .talking:
            return OrbUniforms(
                colorHue: 0.30,
                flowSpeed: 0.8,
                vortexIntensity: 0.4,
                squashX: 1.0,
                squashY: 0.92
            )
        case .confused:
            return OrbUniforms(
                colorHue: 0.05,
                flowSpeed: 2.0,
                vortexIntensity: 1.0,
                squashX: 1.0,
                squashY: 1.0
            )
        }
    }

    /// 0.25 s ease-out 帧间插值. dt 单位秒. 用 1 - exp(-k*dt) 形式做
    /// 时间无关的指数趋近 (frame-rate independent).
    ///
    /// k 取值让 ~95% 收敛大约在 0.25 s 内: 1 - exp(-12 * 0.25) ≈ 0.95
    /// 所以 k ≈ 12 (1/s). 这是 ease-out 行为 — 起始快、末尾慢, 视觉上
    /// 是平滑入位.
    public func eased(toward target: OrbUniforms, dt: Float) -> OrbUniforms {
        let k: Float = 12.0
        let t = 1.0 - exp(-k * max(0.0, dt))
        return OrbUniforms(
            colorHue: Self.lerpHue(colorHue, target.colorHue, t),
            flowSpeed: Self.lerp(flowSpeed, target.flowSpeed, t),
            vortexIntensity: Self.lerp(vortexIntensity, target.vortexIntensity, t),
            squashX: Self.lerp(squashX, target.squashX, t),
            squashY: Self.lerp(squashY, target.squashY, t)
        )
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    /// Hue 走最短弧插值 (避免 0.95 -> 0.05 时从一头穿过整个色环).
    private static func lerpHue(_ a: Float, _ b: Float, _ t: Float) -> Float {
        var d = b - a
        if d > 0.5 { d -= 1.0 }
        if d < -0.5 { d += 1.0 }
        var r = a + d * t
        if r < 0.0 { r += 1.0 }
        if r >= 1.0 { r -= 1.0 }
        return r
    }
}

/// 桌宠视觉本体 protocol.
///
/// - `view`: 挂到 PetShellWindow.contentView 的 NSView.
/// - `updateForState(_:)`: 切换情绪, 驱动 uniforms 插值过渡.
/// - `updateForVelocity(_:)`: 推入瞬时速度 (例如拖拽 dx/dt 或 Rust runtime
///   反馈), 由 renderer 将方向映射为 squash 各向异性: 沿速度方向拉长,
///   垂直方向压扁 (保体积); 量级映射到形变强度 (有上限避免压成 pancake).
/// 一次性招牌动作 —— 跟 `PetEmotionState`(持续情绪态)正交,事件触发型,
/// 由 `DesktopShellController.dispatchSignature` 路由到 `PetRenderer.trigger`。
///
/// 设计:每个 pet 形象插件声明自己 `supportedSignatures` 子集,Shell 只对
/// 集合内的 action 调 `trigger`(其余忽略,不报错)。Orb 默认不实现,留给
/// 史莱姆等角色化形象用。
///
/// 参考上游开源项目 HermesPet (https://github.com/basionwang-bot/HermesPet)
/// 的 MarkdownRenderer(`onChoiceSelected`)+ LifeSignsModifier(任务完成)事件触发模型。
public enum SignatureAction: Hashable, Sendable {
    /// 打招呼。app 启动 / idle 后回来 / 早上第一次打开。
    case greet
    /// 庆祝。LLM 回复完成 / 任务结束 / 连续聊天 N 轮。当前 `PetChatAnimator.triggerJump`
    /// (talking→idle 跳跃)是此 channel 的弱化版,招牌动作路由收口后可归并。
    case celebrate
    /// 收到。⌥Space 召出 / 点击 pet。
    case acknowledge
    /// 拒绝 / 出错。LLM error / 网络失败 / 工具被拒。
    case refuse
    /// 招牌闲置。idle 持续 ≥ N 秒后随机触发(Clawd 伸懒腰 / 史莱姆抖动)。
    case signatureIdle
    /// 被拖完反应。用户松开拖拽时,可选触发"晕" / "开心"。
    case reactToDragEnd
}

@MainActor
public protocol PetRenderer: AnyObject {
    /// 内容层. 由 shell host 装成 backing layer 挂到 pet window(协议 AppKit-free,平台视图装配交 host)。
    var contentLayer: CALayer { get }

    /// 应用 chat 五态. 调用方应在每次状态机回调时调一次, 内部 ease 完成插值.
    func updateForState(_ state: PetEmotionState)

    /// 推入瞬时速度 (px/s, screen-space). renderer 把速度方向映射为
    /// squash 形变 (沿速度方向拉长, 垂直方向压扁), 模拟弹力球被拽动时
    /// 的物理变形. 拖动停止时调一次 `.zero` 让 ease 回到静态.
    ///
    /// 默认实现为空 — 允许 placeholder / 测试 double 选择不实现.
    func updateForVelocity(_ velocity: CGVector)

    /// 推入形象无关的运动态 (walking 朝向 / idle / falling /
    /// perching), 由 `PetMotionController` 每帧产出. renderer 自行表现:
    /// sprite 按 `.walking(.left/.right)` 切走帧行, Orb 可忽略 (平移 +
    /// `updateForVelocity` squash 已足够表达). 默认 no-op.
    func updateForMotion(_ phase: PetMotionPhase)

    /// 淋湿程度 (0 = 干, 1 = 全湿). 下雨时 app 每帧按 isRainEnabled
    /// lerp 后推入; sprite 形象按 alpha 轮廓叠蓝色水渍 tint, Orb 等默认忽略.
    /// 默认 no-op.
    func updateForWetness(_ level: Float)

    /// 当前帧 alpha 轮廓 mask（喂 falling-sand pet occluder，雪堆身上）。
    /// `cellSize` = FS grid 每 cell 的世界像素（pet footprint 据此下采样），`maxDim`
    /// = 单边 cell 上限（引擎 buffer 容量）。sprite 形象按当前帧 alpha 生成；Orb 等
    /// 无轮廓形象返回 nil（无 occluder）。默认 nil。结果应按当前帧缓存（避免每帧重绘）。
    func currentFrameAlphaMask(cellSize: Float, maxDim: Int) -> PetAlphaMask?

    /// 暂停内部 render loop. 用于 host view 不可见 (e.g. Stage 隐藏时的
    /// mini-orb), 避免 60 Hz `Task @MainActor` hop 抢主线程. 默认 no-op
    /// (placeholder / 测试 double 不需要实现).
    func pauseDisplayLink()

    /// 恢复 render loop. 与 `pauseDisplayLink()` 成对.
    func resumeDisplayLink()

    /// 当前 pet 形象实际能演的招牌动作子集。Shell 派发 trigger 前
    /// 先按此集合过滤,不在集合内的 action 直接忽略(不报错)。Orb 默认空集
    /// (Orb 没有招牌动作,只有 chat 五态),角色化形象(如史莱姆)在
    /// 各自插件里覆盖。
    var supportedSignatures: Set<SignatureAction> { get }

    /// 触发一次性招牌动作。renderer 内部决定具体动画(SDF 形变 /
    /// sprite 帧切换 / metaball 突变 / …),持续时间 + 与情绪态如何叠加都由
    /// renderer 自己决定。
    func trigger(_ signature: SignatureAction)

    /// renderer 是否**自管窗口位置**(每帧自产 anchor + 摆窗,如 Shimeji 引擎)。
    /// `true` → host PetMotionController / drag adapter 的位置驱动整段让位(否则与引擎抢窗)。
    /// 默认 `false`(Orb/sprite/Live2D 位置由 host 仲裁)。
    var drivesOwnWindowPosition: Bool { get }

    /// pet 窗口左键按下 → 交给 renderer(Shimeji 引擎转 Dragged 抓起跟手)。
    /// 仅在 `drivesOwnWindowPosition` 时由控制器路由;默认 no-op。
    func handlePointerDown()

    /// pet 窗口左键释放 → 交给 renderer(Shimeji 引擎转 Thrown 甩出,初速=光标速度)。
    /// 默认 no-op。
    func handlePointerUp()

    /// 用户全局桌宠大小因子(0.5–2.0,1=原始)。**自管窗口的形象**(Shimeji)用它在每帧
    /// 出帧时缩放窗口+锚点;host 仲裁位置的形象由 host 改窗口尺寸,这里默认 no-op。
    func applyScale(_ scale: CGFloat)
}

public extension PetRenderer {
    /// 默认 no-op. PlaceholderPetRenderer / 测试 double 可不覆盖.
    func updateForVelocity(_ velocity: CGVector) {}
    func pauseDisplayLink() {}
    func resumeDisplayLink() {}

    /// 默认 no-op. Orb 等无方向形象不必表现运动态.
    func updateForMotion(_ phase: PetMotionPhase) {}

    /// 默认 no-op. Orb 等不表现淋湿.
    func updateForWetness(_ level: Float) {}

    /// 默认 nil. Orb 等无轮廓形象不提供 occluder mask.
    func currentFrameAlphaMask(cellSize: Float, maxDim: Int) -> PetAlphaMask? { nil }

    /// 默认空集。Orb 等当前没有招牌动作的 renderer 直接走默认。
    var supportedSignatures: Set<SignatureAction> { [] }

    /// 默认 no-op。Shell 端 `dispatchSignature` 已先 contains 校验过滤,
    /// 走到这里的实现都是自愿响应。
    func trigger(_ signature: SignatureAction) {}

    /// 默认 false(host 仲裁位置)。仅 Shimeji 引擎形象覆盖为 true。
    var drivesOwnWindowPosition: Bool { false }

    /// 默认 no-op。仅引擎驱动形象响应指针。
    func handlePointerDown() {}
    func handlePointerUp() {}

    /// 默认 no-op(host 仲裁位置的形象由 host 改窗口尺寸缩放)。仅 Shimeji 自管窗口形象覆盖。
    func applyScale(_ scale: CGFloat) {}
}

// MARK: - exp helper (Float)
//
// Foundation 的 exp(Double) 不接受 Float; Glibc/Darwin 的 expf 在 Foundation
// 导入后通过 `import Foundation` 可见. 这里加一个 Float overload 转发,
// 避免在没有 import Foundation 的文件里写 Double(...)/Float(...) 蹦床.

#if canImport(Foundation)
import Foundation
#endif

@inlinable
internal func exp(_ x: Float) -> Float {
    #if canImport(Darwin)
    return Foundation.expf(x)
    #else
    return Float(Foundation.exp(Double(x)))
    #endif
}
