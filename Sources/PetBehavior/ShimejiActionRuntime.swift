import Foundation

/// 动作运行时类族基类 + 叶子动作(Stay/Animate/Move)。参照 Shimeji-Desktop 的
/// `ActionBase`/`BorderedAction`/`Stay`/`Animate`/`Move` 重新实现动作运行时逻辑(逻辑级,未拷贝源码)。
/// 引用语义类(运行时可变状态:startTime/turning/velocity),贴 Java 结构最保真;
/// 单线程使用(引擎在 host 主线程驱动),非 Sendable。
///
/// 生命周期:`start(ctx)` ≙ Java init(mascot);每 tick `hasNext(ctx)` 判继续,`next(ctx)` 推进。
/// 参数(Duration/Condition/TargetX...)每次访问经脚本引擎**重新求值**(对齐 Java eval 语义)。
public class ShimejiActionRuntime {
    /// 动作定义(params 已含 ActionReference 覆盖合并)。
    public let definition: ShimejiActionDefinition

    /// 动作起始时的 mascot 全局 tick(局部时间 = mascot.time - startTime)。
    var startTime = 0

    /// `${...}` 静态参数缓存(整个动作生命周期只求值一次,start 时清)。键=参数名。
    /// 否则 `TargetX="${...Math.random()...}"` 每帧重掷 → 目标抖动 → lookRight 翻转(摆头);
    /// `Duration="${500+Math.random()*1000}"` 每帧抖 → 行为时长不稳。
    private var staticDoubleCache: [String: Double] = [:]

    public init(definition: ShimejiActionDefinition) {
        self.definition = definition
    }

    // MARK: - 时间(Java ActionBase.getTime/setTime)

    public func time(_ ctx: ShimejiTickContext) -> Int {
        ctx.state.time - startTime
    }

    func setTime(_ ctx: ShimejiTickContext, _ t: Int) {
        startTime = ctx.state.time - t
    }

    // MARK: - 参数求值(每次访问重求值)

    func paramInt(_ ctx: ShimejiTickContext, _ name: String, fallback: Int) -> Int {
        let value = paramDouble(ctx, name, fallback: Double(fallback))
        guard value.isFinite, value < Double(Int.max), value > Double(Int.min) else { return fallback }
        return Int(value.rounded())
    }

    /// 数值参数求值。`${...}` 静态 → 缓存(只第一次求值,后续返缓存);`#{...}` 动态 → 每次求值。
    func paramDouble(_ ctx: ShimejiTickContext, _ name: String, fallback: Double) -> Double {
        guard let script = definition.params[name] else { return fallback }
        if ShimejiScriptEngine.isStatic(script) {
            if let cached = staticDoubleCache[name] { return cached }
            let value = ctx.engine.evalDouble(script, fallback: fallback)
            staticDoubleCache[name] = value
            return value
        }
        return ctx.engine.evalDouble(script, fallback: fallback)
    }

    func paramBool(_ ctx: ShimejiTickContext, _ name: String, fallback: Bool) -> Bool {
        ctx.engine.evalBool(definition.params[name], fallback: fallback)
    }

    /// `Duration` 缺省"无限"(Java Integer.MAX_VALUE;取半防溢出加法)。
    func duration(_ ctx: ShimejiTickContext) -> Int {
        paramInt(ctx, "Duration", fallback: Int.max / 2)
    }

    // MARK: - 生命周期

    /// ≙ Java `init(mascot)`:绑定起始时间 + 清静态参数缓存(新生命周期 `${}` 重新求值一次)。
    /// 子类覆盖追加自身初始化(必须先调 super)。
    public func start(_ ctx: ShimejiTickContext) {
        setTime(ctx, 0)
        staticDoubleCache.removeAll(keepingCapacity: true)
    }

    /// ≙ Java `ActionBase.hasNext`:局部时间未超 Duration 且 Condition 成立。
    public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        time(ctx) < duration(ctx) && paramBool(ctx, "Condition", fallback: true)
    }

    /// ≙ Java `next()`(模板方法,内部调 tick)。子类覆盖 `tick(ctx)`。
    public final func next(_ ctx: ShimejiTickContext) throws {
        bindParams(ctx)
        try tick(ctx)
    }

    /// ≙ Shimeji 把动作参数放进 `VariableMap`:每 tick 求值数值参数 → 写进脚本引擎全局变量,
    /// 供**动画 Condition**(如 ClimbWall 的 `#{TargetY < mascot.anchor.y}`)与表达式读取。
    /// 不绑则 JS 里 `TargetY` 未定义 → 条件恒 false → 动画选不出 → 动作不推进 → **卡死**
    /// (真实包爬墙场景验出)。非数值参数(Condition/Loop 等结构脚本)evalDouble 得 NaN → 跳过。
    private func bindParams(_ ctx: ShimejiTickContext) {
        for key in definition.params.keys {
            let value = paramDouble(ctx, key, fallback: .nan)   // 静态参数走缓存 → 绑定值稳定
            if value.isFinite { ctx.engine.setVariable(key, value) }
        }
    }

    /// 子类每 tick 实现(基类 no-op)。
    func tick(_ ctx: ShimejiTickContext) throws {}

    /// 当前动作是否允许被拖拽劫持(`Draggable` 参数,缺省 true)。复合动作委托当前子动作。
    public func isDraggable(_ ctx: ShimejiTickContext) -> Bool {
        paramBool(ctx, "Draggable", fallback: true)
    }

    /// 当前正在执行的**叶子**动作(复合动作下钻到 currentChild;叶子 = 自己)。
    /// 读当前广播的 Affordance / 判是否 ScanMove 等用。
    var currentLeaf: ShimejiActionRuntime { self }

    // MARK: - 动画选取 + 姿势应用

    /// ≙ Java `getAnimation()`:第一个「isTurn 匹配 + Condition 成立」的分支。每次调用重选。
    func animation(_ ctx: ShimejiTickContext, turning: Bool = false) -> ShimejiAnimation? {
        definition.animations.first { anim in
            anim.isTurn == turning && ctx.engine.evalBool(anim.condition, fallback: anim.condition == nil)
        }
    }

    /// ≙ Java `Animation.apply` + `Pose.apply`:按局部时间取模选 pose,平移 anchor
    /// (朝右取反 dx —— 原图朝左约定),写入 ctx.currentPose 供引擎出帧。
    func applyAnimation(_ ctx: ShimejiTickContext, _ anim: ShimejiAnimation?) {
        guard let anim, let pose = anim.pose(atTick: time(ctx)) else { return }
        let dx = ctx.state.lookRight ? -pose.velocityX : pose.velocityX
        ctx.state.anchor.x += dx
        ctx.state.anchor.y += pose.velocityY
        ctx.currentPose = pose
    }
}

// MARK: - BorderedAction(边界绑定基类)

/// ≙ Java `BorderedAction`:start 时按 BorderType 解析当前所站的具体边并绑定;
/// 每 tick 先让 anchor 跟随边移动(窗口拖动);叶子动作各自检查失地抛 lostGround。
public class ShimejiBorderedRuntime: ShimejiActionRuntime {
    var border: ShimejiBorder?

    override public func start(_ ctx: ShimejiTickContext) {
        super.start(ctx)
        border = definition.borderType.flatMap {
            ctx.environment.resolveBorder($0, at: ctx.state.anchor, lookRight: ctx.state.lookRight)
        }
    }

    /// ≙ Java `BorderedAction.tick`:边跟随(用上帧→当帧环境差分)。
    func borderTick(_ ctx: ShimejiTickContext) {
        guard let border else { return }
        ctx.state.anchor = border.moved(ctx.state.anchor, from: ctx.previousEnvironment, to: ctx.environment)
    }

    /// 失地检查(Move/Stay/Animate tick 内调)。两种 lostGround:
    /// ① 绑了边但 anchor 已离开(窗口移走);
    /// ② **指定了 BorderType 但 start 时就不在该边**(`border==nil`)—— Shimeji `BorderedAction`
    ///    此时拿到 `NotOnBorder`(isOn 恒 false)→ 立即 LostGround。**关键**:地面动作(如顶层无条件
    ///    `Trip` BorderType=Floor)在半空被选中 → 立即掉落,而非静止站桩(真实包场景验出)。
    func ensureOnBorder(_ ctx: ShimejiTickContext) throws {
        if let border {
            if !ctx.environment.isOn(border, ctx.state.anchor) {
                throw ShimejiActionInterruption.lostGround
            }
        } else if definition.borderType != nil {
            throw ShimejiActionInterruption.lostGround
        }
    }
}

// MARK: - Stay

/// ≙ Java `Stay`:站桩播动画(pose velocity 可非零但通常 0),Duration 终止。
public final class ShimejiStayRuntime: ShimejiBorderedRuntime {
    override func tick(_ ctx: ShimejiTickContext) throws {
        borderTick(ctx)
        try ensureOnBorder(ctx)
        applyAnimation(ctx, animation(ctx))
    }
}

// MARK: - Animate

/// ≙ Java `Animate`:动画放完即止(hasNext 多一条 time < 动画总时长)。
public final class ShimejiAnimateRuntime: ShimejiBorderedRuntime {
    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        guard let anim = animation(ctx) else { return false }
        return time(ctx) < anim.durationTicks
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        borderTick(ctx)
        try ensureOnBorder(ctx)
        applyAnimation(ctx, animation(ctx))
    }
}

// MARK: - Move

/// ≙ Java `Move`:沿边走向 TargetX/TargetY,自动朝向目标,有 IsTurn 动画时插播转向,
/// 越过目标吸附,到达即止。目标「未设」= 参数缺失(Java 用 Integer.MAX_VALUE 哨兵)。
public final class ShimejiMoveRuntime: ShimejiBorderedRuntime {
    private var turning = false

    private func targetX(_ ctx: ShimejiTickContext) -> Double? {
        definition.params["TargetX"] != nil ? paramDouble(ctx, "TargetX", fallback: ctx.state.anchor.x) : nil
    }

    private func targetY(_ ctx: ShimejiTickContext) -> Double? {
        definition.params["TargetY"] != nil ? paramDouble(ctx, "TargetY", fallback: ctx.state.anchor.y) : nil
    }

    private var hasTurnAnimation: Bool {
        definition.animations.contains { $0.isTurn }
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        if turning { return true }
        let a = ctx.state.anchor
        let notReachedX = targetX(ctx).map { Int(a.x.rounded()) != Int($0.rounded()) } ?? false
        let notReachedY = targetY(ctx).map { Int(a.y.rounded()) != Int($0.rounded()) } ?? false
        return notReachedX || notReachedY
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        borderTick(ctx)
        try ensureOnBorder(ctx)

        let tX = targetX(ctx)
        let tY = targetY(ctx)
        var down = false

        if let tX, Int(ctx.state.anchor.x.rounded()) != Int(tX.rounded()) {
            let shouldLookRight = ctx.state.anchor.x < tX
            turning = hasTurnAnimation && (turning || shouldLookRight != ctx.state.lookRight)
            ctx.state.lookRight = shouldLookRight
        }
        if let tY { down = ctx.state.anchor.y < tY }

        var anim = animation(ctx, turning: turning)
        // 转向态兜底(review F-1):turn 分支此刻不可用(Condition 不成立)→ 立即退回普通态。
        // 否则 turning 卡死 true → hasNext 恒 true → Move 站桩走满 Duration;Java 同场景
        // NPE→LostGround→Fall,两边都非本意,退普通态是「转向放完即退」意图的安全实现。
        if turning, anim == nil {
            turning = false
            anim = animation(ctx, turning: false)
        }
        // 转向动画放完 → 回普通态(Java Move.tick:turning && time >= anim.duration)。
        if turning, let turnAnim = anim, time(ctx) >= turnAnim.durationTicks {
            turning = false
            anim = animation(ctx, turning: false)
        }
        applyAnimation(ctx, anim)

        // 越过目标吸附(Java:按朝向/落向判定跨越)。
        if let tX {
            if (ctx.state.lookRight && ctx.state.anchor.x >= tX) || (!ctx.state.lookRight && ctx.state.anchor.x <= tX) {
                ctx.state.anchor.x = tX
            }
        }
        if let tY {
            if (down && ctx.state.anchor.y >= tY) || (!down && ctx.state.anchor.y <= tY) {
                ctx.state.anchor.y = tY
            }
        }
    }
}

// MARK: - ScanMove(多宠互动:跑向广播 affordance 的邻居 → 配对)

/// ≙ Java `ScanMove`:跑向「广播了本动作 `Affordance` 的邻居」(host 经 `env.scanTarget` 提供匹配目标),
/// 到达即触发配对——自己切 `Behavior`、目标切 `TargetBehavior`(写 `ctx.pendingInteraction`,引擎/host 落地)。
/// 无匹配目标 → `hasNext` false(动作即止 → 回行为选择;Sequence 里的前置 Stand 防空转刷屏)。
/// 移动/转向/吸附逻辑与 `Move` 同,只是目标来自 scanTarget 而非 `TargetX` 参数。
public final class ShimejiScanMoveRuntime: ShimejiBorderedRuntime {
    private var turning = false
    private var hasTurnAnimation: Bool { definition.animations.contains { $0.isTurn } }

    /// 本动作寻找的 affordance(`Affordance` 参数字面量;空 → 不参与)。
    private var soughtAffordance: String? {
        let s = definition.params["Affordance"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// host 匹配到的目标(`env.scanTarget` 且其 affordance == 本动作所求)。
    private func target(_ ctx: ShimejiTickContext) -> BehaviorPeer? {
        guard let peer = ctx.environment.scanTarget, let want = soughtAffordance,
              peer.affordance == want else { return nil }
        return peer
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        if turning { return true }
        return target(ctx) != nil
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        borderTick(ctx)
        try ensureOnBorder(ctx)
        guard let peer = target(ctx) else { return }   // 无目标:hasNext 会止
        let tX = peer.anchor.x, tY = peer.anchor.y

        if Int(ctx.state.anchor.x.rounded()) != Int(tX.rounded()) {
            let shouldLookRight = ctx.state.anchor.x < tX
            turning = hasTurnAnimation && (turning || shouldLookRight != ctx.state.lookRight)
            ctx.state.lookRight = shouldLookRight
        }
        let down = ctx.state.anchor.y < tY

        var anim = animation(ctx, turning: turning)
        if turning, anim == nil { turning = false; anim = animation(ctx, turning: false) }
        if turning, let t = anim, time(ctx) >= t.durationTicks { turning = false; anim = animation(ctx, turning: false) }
        applyAnimation(ctx, anim)

        if (ctx.state.lookRight && ctx.state.anchor.x >= tX) || (!ctx.state.lookRight && ctx.state.anchor.x <= tX) {
            ctx.state.anchor.x = tX
        }
        if (down && ctx.state.anchor.y >= tY) || (!down && ctx.state.anchor.y <= tY) {
            ctx.state.anchor.y = tY
        }

        // 到达(x/y 都吸附、非转向)→ 触发配对(self→Behavior,target→TargetBehavior)。
        let reached = Int(ctx.state.anchor.x.rounded()) == Int(tX.rounded())
            && Int(ctx.state.anchor.y.rounded()) == Int(tY.rounded())
        if !turning, reached {
            let selfB = (definition.params["Behavior"] ?? definition.params["Behaviour"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let targetB = (definition.params["TargetBehavior"] ?? definition.params["TargetBehaviour"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selfB.isEmpty {
                ctx.pendingInteraction = ShimejiPendingInteraction(
                    selfBehavior: selfB, targetBehavior: targetB, targetID: peer.id)
            }
        }
    }
}
