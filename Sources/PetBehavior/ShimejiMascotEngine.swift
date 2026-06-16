import Foundation

/// Shimeji 引擎 facade(Shijima 式 tiny facade):行为图 + 动作库 + mascot 状态,每 tick 产出
/// 「画哪张图 + anchor + 朝向」纯数据帧。host 负责喂环境/驱动窗口/渲染图。
///
/// 每 tick(40ms):sync 脚本引擎 → 当前动作 next(可继续)/ 行为衔接(动作结束 → 加权随机选下个)
/// / lostGround → 强制 Fall → time++ → 出帧。hijack:`pointerPressed`(可拖动作 → Dragged)/
/// `pointerReleased`(拖拽中 → Thrown,初速 = 光标半衰速度,经引用覆盖进 Fall)。
/// 出屏防护(Java UserBehavior 越界检测的简化形态):anchor 完全出屏 → 收回屏内顶部 + 强制 Fall。
@MainActor
public final class ShimejiMascotEngine {
    public let graph: ShimejiBehaviorGraph
    public let library: ShimejiActionLibrary

    private let scheduler: ShimejiBehaviorScheduler
    private let factory: ShimejiActionRuntimeFactory
    private let scriptEngine = ShimejiScriptEngine()
    private let context: ShimejiTickContext

    private var currentBehaviorName: String?
    private var currentRuntime: ShimejiActionRuntime?

    /// 强制行为名(Shimeji schema 常量;社区包均沿用)。
    private let fallBehaviorName: String
    private let draggedBehaviorName: String
    private let thrownBehaviorName: String

    /// 单 tick 行为链上限:空动作(条件全不成立)连环跳时防死循环(Java 无此防护会栈溢)。
    private static let maxTransitionsPerTick = 10

    // MARK: - 只读暴露(host/测试)

    public var anchor: BehaviorPoint { context.state.anchor }
    public var lookRight: Bool { context.state.lookRight }
    public var isDragging: Bool { context.state.dragging }
    public var behaviorName: String? { currentBehaviorName }

    /// 当前正在**广播**的 affordance(当前叶子动作的 `Affordance` 参数;ScanMove 扫描态不广播 → nil)。
    /// host 据此把「广播者」匹配给「扫描者」的 `env.scanTarget`。
    public var offeredAffordance: String? {
        guard let leaf = currentRuntime?.currentLeaf, !(leaf is ShimejiScanMoveRuntime) else { return nil }
        let s = leaf.definition.params["Affordance"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// 当前正在**寻找**的 affordance(当前叶子是 ScanMove 时其 `Affordance`)。host 据此匹配广播者。
    public var seekingAffordance: String? {
        guard let leaf = currentRuntime?.currentLeaf, leaf is ShimejiScanMoveRuntime else { return nil }
        let s = leaf.definition.params["Affordance"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// 配对互动:ScanMove 到达目标后,host 应把**目标 pet**切到此行为(`(targetID, behavior)`)。读即清。
    private var pendingOutgoingPairing: (targetID: String, behavior: String)?
    public func consumeOutgoingPairing() -> (targetID: String, behavior: String)? {
        defer { pendingOutgoingPairing = nil }
        return pendingOutgoingPairing
    }

    /// host 强制本 mascot 切到指定行为(配对互动:目标被切到 TargetBehavior;无此行为 → 随机衔接)。
    public func triggerBehavior(named name: String) { forceBehavior(name) }

    public init(
        graph: ShimejiBehaviorGraph,
        library: ShimejiActionLibrary,
        anchor: BehaviorPoint,
        environment: BehaviorEnvironment,
        seed: UInt64 = 0x5EED,
        fallBehaviorName: String = "Fall",
        draggedBehaviorName: String = "Dragged",
        thrownBehaviorName: String = "Thrown"
    ) {
        self.graph = graph
        self.library = library
        self.scheduler = ShimejiBehaviorScheduler(graph: graph, fallbackBehaviorName: fallBehaviorName)
        self.factory = ShimejiActionRuntimeFactory(library: library)
        self.fallBehaviorName = fallBehaviorName
        self.draggedBehaviorName = draggedBehaviorName
        self.thrownBehaviorName = thrownBehaviorName
        self.context = ShimejiTickContext(
            state: ShimejiMascotState(anchor: anchor),
            engine: scriptEngine,
            environment: environment,
            rng: ShimejiRandom(seed: seed)
        )
    }

    // MARK: - 主循环

    /// 推进一 tick。host 按 ~40ms 节奏调用(或按自身帧率折算)。
    public func tick(environment: BehaviorEnvironment) -> ShimejiMascotFrame {
        context.previousEnvironment = context.environment
        context.environment = environment
        syncScript()

        if currentRuntime == nil {
            transition(previous: nil)
        } else if let runtime = currentRuntime {
            do {
                if runtime.hasNext(context) {
                    try runtime.next(context)
                } else {
                    transition(previous: currentBehaviorName)
                }
            } catch {
                // lostGround:脱离边界/挣脱拖拽 → 强制 Fall(Java UserBehavior catch 同义)。
                context.state.dragging = false
                forceBehavior(fallBehaviorName)
            }
        }

        // 多宠互动配对(ScanMove 到达目标):自己切 selfBehavior + 把目标配对暴露给 host(跨引擎)。
        if let pi = context.pendingInteraction {
            context.pendingInteraction = nil
            forceBehavior(pi.selfBehavior)
            if let tid = pi.targetID, !pi.targetBehavior.isEmpty {
                pendingOutgoingPairing = (tid, pi.targetBehavior)
            }
        }

        clampToWorkAreaHorizontally()
        recoverIfOffscreen()
        // F-4(review):anchor 取整 —— Shimeji 是整数像素模型(Java `Point` int),Move 目标吸附
        // (`TargetX=${...Math.random()...}`)等会引入小数,逐 tick 累积成对角漂移。取整对齐原版,
        // 且与条件求值/isOn(本就按 rounded 比较)一致。
        context.state.anchor = BehaviorPoint(
            x: context.state.anchor.x.rounded(),
            y: context.state.anchor.y.rounded())
        context.state.time += 1
        return makeFrame()
    }

    /// 安全网(实机真实包验出):把 anchor.x 夹进 workArea 水平范围。
    ///
    /// 根因:`wallBorder` 按 `lookRight` 只查单侧墙(忠于 Shimeji `getWall`),pet 在左边但面右时
    /// 左墙(x=workArea.left)漏检 → 高速甩出/拖拽把 x 推过边界进负值 → workArea floor 的 x-range
    /// 不含 → floor 永不命中 → 坠穿屏底 → 出屏吸回屏顶 → **无限下落循环**。真实墙会物理挡住 pet,
    /// 但精确整数墙在高速插值下会被跳过(x 从 +1 跳到 −1 不经 0)。夹 x 保证 floor 恒在脚下,根治。
    private func clampToWorkAreaHorizontally() {
        let wa = context.environment.workArea
        guard wa.right > wa.left else { return }
        let x = context.state.anchor.x
        if x < wa.left { context.state.anchor.x = wa.left }
        else if x > wa.right { context.state.anchor.x = wa.right }
    }

    // MARK: - hijack(host 鼠标事件接入)

    /// 左键按下:当前动作可拖 → 切 Dragged(Java UserBehavior.mousePressed)。
    public func pointerPressed() {
        guard currentRuntime?.isDraggable(context) != false else { return }
        context.state.dragging = true
        forceBehavior(draggedBehaviorName)
    }

    /// 左键释放:拖拽中 → 切 Thrown(初速 = environment.cursor.dx/dy,经包内引用覆盖喂 Fall)。
    public func pointerReleased() {
        guard context.state.dragging else { return }
        context.state.dragging = false
        forceBehavior(thrownBehaviorName)
    }

    // MARK: - 行为衔接

    /// 动作结束 → 调度器选下个行为;空动作连环跳有界。
    private func transition(previous: String?) {
        var prev = previous
        for _ in 0..<Self.maxTransitionsPerTick {
            let evaluator = JSConditionEvaluator(engine: scriptEngine)
            let name = scheduler.pickNext(previous: prev, evaluator: evaluator, using: &context.rng)
            if startBehavior(named: name) { return }
            prev = name
        }
        currentBehaviorName = nil
        currentRuntime = nil
    }

    /// 强制切指定行为(Fall/Dragged/Thrown;Java buildBehavior(name) 同义)。失败回退随机衔接。
    private func forceBehavior(_ name: String) {
        if !startBehavior(named: name) {
            transition(previous: nil)
        }
    }

    /// 起一个行为:行为名 → actionName → 运行时 → start。start 后立即不可跑(条件不成立/
    /// 空动作)→ false 让调用方继续衔接(Java UserBehavior.init 的空动作即跳语义)。
    private func startBehavior(named name: String) -> Bool {
        guard let behavior = graph.behavior(named: name),
              let runtime = factory.makeRuntime(actionNamed: behavior.actionName)
        else { return false }

        runtime.start(context)
        syncScript()   // start 可能动了 anchor/朝向(Instant)→ 重绑供后续求值
        guard runtime.hasNext(context) else {
            currentBehaviorName = name
            currentRuntime = nil
            return false
        }
        currentBehaviorName = name
        currentRuntime = runtime
        return true
    }

    // MARK: - 内部

    /// 把当前状态快照重绑进脚本引擎(用户脚本条件/参数据此求值)。
    private func syncScript() {
        scriptEngine.sync(mascot: BehaviorMascot(
            anchor: context.state.anchor,
            lookRight: context.state.lookRight,
            totalCount: 1,
            environment: context.environment
        ))
    }

    /// 出屏防护:anchor 偏出屏幕外缘 margin → 收回屏内 + 强制 Fall。
    /// **不查上方出屏**(F-9,对齐 Java):pet 从天而降本就在屏顶上方,高抛也应靠重力划回,
    /// 而非被吸回屏顶。只在水平全出屏 / 跌穿屏底时收回。
    private func recoverIfOffscreen() {
        let screen = context.environment.screen
        let margin: Double = 256
        let a = context.state.anchor
        guard a.x < screen.left - margin || a.x > screen.right + margin ||
            a.y > screen.bottom + margin
        else { return }

        let clampedX = min(max(a.x, screen.left + 1), screen.right - 1)
        context.state.anchor = BehaviorPoint(x: clampedX, y: screen.top + 1)
        context.state.dragging = false
        forceBehavior(fallBehaviorName)
    }

    private func makeFrame() -> ShimejiMascotFrame {
        let pose = context.currentPose
        return ShimejiMascotFrame(
            anchor: context.state.anchor,
            lookRight: context.state.lookRight,
            image: pose?.image,
            imageRight: pose?.imageRight,
            imageAnchorX: pose?.imageAnchorX ?? 0,
            imageAnchorY: pose?.imageAnchorY ?? 0,
            behaviorName: currentBehaviorName
        )
    }
}
