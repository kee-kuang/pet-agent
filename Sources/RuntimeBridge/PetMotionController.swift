import Context

/// 形象无关的运动仲裁层 —— pet 位置的**单一决策出口**:所有形象共用一套位置仲裁,
/// 渲染层只消费结果不参与决策。
///
/// ## 职责
///
/// pet 位置有两种 regime:物理回落(跟光标 / 拖拽释放)vs 行为驱动(漫步 /
/// 爬窗)。本控制器每帧:
/// 1. 仲裁出 `PetMotionMode`(physics / roaming / perched / dragged);
/// 2. 据模式算最终位置(physics 透传候选,roaming/perched 自行算);
/// 3. 据 `previousPosition → 最终位置` 的位移算 `PetMotionPhase`。
///
/// ## 模式
///
/// - `.physics`:透传上游 cursor-follow 候选(零回归)。
/// - `.roaming`:空闲 → 重力降到可见地面 → 沿地面走向随机路点 + 暂停。
/// - `.perched`:漫步到窗口下方暂停时按概率爬上窗口顶边,x/y 跟随窗口移动;
///   窗口关闭/移走 → 解除 → 落回地面。爬升过程降级为瞬移到位(完整
///   攀爬动画需更多帧,留后续)。
/// - `.dragged`:由 Shell 拖拽路径直接驱动(短路帧循环),控制器不参与。
///
/// ## 位置无状态 + 纯函数式
///
/// 控制器不存 pet 位置(权威源是 App `currentRenderState`,拖拽/不跟随也准),每帧
/// 由调用方传 `previousPosition` → 免 staleness。只持有 `mode` + 漫步/爬窗自身演进态
/// (路点 / 暂停计时 / 所站窗口矩形 / PRNG)。`resolved` 不就地变更,返回新 controller。
public struct PetMotionController: Sendable, Equatable {
    /// 当前模式(上一帧仲裁结果)。
    public private(set) var mode: PetMotionMode

    /// 漫步当前路点 x(NSScreen 全局坐标)。`nil` = 需选新路点。
    private var roamTargetX: Double?
    /// 漫步路点间暂停剩余秒。
    private var roamPauseRemaining: Double
    /// 当前所站窗口矩形(底原点,与 pet 位置同系)。`nil` = 未爬窗。逐帧按邻近度重匹配跟随。
    private var perchedRect: Rect?
    /// 正在沿侧边攀爬的窗口(逐帧上升的窗口攀爬)。`nil` = 未攀爬。到顶转 `perchedRect`,窗口没了 → 落回。
    private var climbingRect: Rect?
    /// 攀爬中锚定的侧边 x(窗口左或右边)。
    private var climbEdgeX: Double
    /// 攀爬中面朝的墙一侧(贴左边 = 面右 `.right`)。供 sprite 镜像 / Live2D 抓握。
    private var climbFacing: PetFacing
    /// 当前攀爬/吸附的是否「屏幕边缘」(吸附屏幕边 / 拖到边):true 时无需 `matchWindow`(屏幕恒在),
    /// 升到 `climbTopY` 后吸附在屏幕边(保持,直到用户拖走)。
    private var screenEdgeClimb: Bool
    /// 屏幕边攀爬的目标吸附高度(y)。窗口攀爬用 `climbingRect` 顶边,不读此值。
    private var climbTopY: Double
    /// 选路点 / 爬窗概率用的确定性 PRNG。
    private var rng: PetMotionRandom

    // MARK: - 调参常数

    static let idleMotionEpsilon = 0.5
    static let fallingDominanceRatio = 2.0
    static let roamThresholdSeconds = 8.0
    static let roamSpeed = 70.0
    static let roamFallSpeed = 520.0
    static let roamPauseSeconds = 1.4
    static let roamArrivalEpsilon = 4.0
    static let groundSnapEpsilon = 2.0
    static let roamEdgeMargin = 24.0
    /// 窗口顶边至少高出地面这么多(px)才值得爬。
    static let perchMinElevation = 60.0
    /// 窗口至少这么宽(px)pet 才站得下。
    static let perchMinWidth = 80.0
    /// 站立点离窗口左右边的内缩(px),不悬在边角。
    static let perchEdgeInset = 8.0
    /// 逐帧跟踪:窗口 origin 移动超过此(px)视为失配(窗口换了/关了)。
    static let perchMaxTrackShift = 120.0
    /// 逐帧跟踪:窗口尺寸变化容差(px),超过视为不是同一窗口。
    static let perchMaxSizeDelta = 80.0
    /// 沿侧边向上攀爬速度(px/s)。可见但不拖沓(~1s 爬 200px)。
    static let climbSpeed = 200.0
    /// 漫步越过可爬窗口侧边时,爬上去的概率(每次越过掷一次)。
    static let wallClimbChance = 0.5
    /// 窗口至少这么高(px)才值得沿侧边爬(太矮直接走过)。
    static let climbMinHeight = 80.0
    /// 拖到屏幕边多近(px)就吸附爬屏幕边。须 < `roamEdgeMargin`(24),否则正常漫步
    /// 到边缘内缩点(x=margin)就会误触发;现 12 < 24 → 仅拖拽释放到极边(x<12)才吸附。
    static let screenEdgeClingThreshold = 12.0
    /// 吸附屏幕边后向上爬的高度(px,离地)。停在此高度「挂在墙上」,直到用户拖走。
    static let screenEdgeClingHeight = 220.0

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.mode = .physics
        self.roamTargetX = nil
        self.roamPauseRemaining = 0
        self.perchedRect = nil
        self.climbingRect = nil
        self.climbEdgeX = 0
        self.climbFacing = .right
        self.screenEdgeClimb = false
        self.climbTopY = 0
        self.rng = PetMotionRandom(seed: seed)
    }

    /// 每帧仲裁。
    /// - `previousPosition`:pet 上一帧真实位置(权威值)。
    /// - `physicsCandidate`:上游 cursor-follow 候选位置。
    public func resolved(
        previousPosition: Point,
        physicsCandidate: Point,
        input: PetMotionInput
    ) -> (controller: PetMotionController, frame: PetMotionFrame) {
        var next = self
        let (mode, position) = next.decide(
            previous: previousPosition,
            candidate: physicsCandidate,
            input: input
        )
        next.mode = mode
        // 攀爬时 x 锚定侧边(位移 dx≈0,无法由位移推朝向)→ 用 climbFacing;其余走位移推导。
        let phase = mode == .climbing
            ? .climbing(next.climbFacing)
            : Self.phase(from: previousPosition, to: position, mode: mode)
        let frame = PetMotionFrame(position: position, rotation: 0, phase: phase, mode: mode)
        return (next, frame)
    }

    // MARK: - 模式 + 位置仲裁

    /// 仲裁优先级:跟随追光标(活跃) > 续站 > 漫步/爬窗。两个开关解耦:
    /// - 跟随开 + 用户活跃 → 追光标(physics 透传候选)。
    /// - 漫游开 → 自主漫步/爬窗:跟随**关**时连续漫游(用户显式要「自由漫步」),
    ///   跟随**开**时仅用户空闲 ≥ 阈值才漫游(活跃时优先追光标,避免两者打架)。
    /// - 都不触发 → physics 兜底:跟随开停在光标候选,否则原地不动。
    private mutating func decide(
        previous: Point,
        candidate: Point,
        input: PetMotionInput
    ) -> (PetMotionMode, Point) {
        let userActive = input.idleSeconds < Self.roamThresholdSeconds
        // 跟随开 + 活跃 → 追光标,清空溜达/爬窗态。
        if input.followingEnabled && userActive {
            clearTransientState()
            return (.physics, candidate)
        }
        // 漫游:跟随关 → 连续(此分支即非「跟随+活跃」);跟随开 → 仅空闲(userActive 已为 false)。
        if input.roamingEnabled {
            // 吸附在屏幕边(无窗口,屏幕恒在 → 不 matchWindow,保持到拖走)。
            if mode == .perched, screenEdgeClimb {
                return (.perched, Point(x: climbEdgeX, y: climbTopY))
            }
            // 已在窗口上且窗口仍可跟踪 → 续站,跟随窗口移动。
            if mode == .perched, let rect = perchedRect,
               let tracked = Self.matchWindow(to: rect, in: input.windows) {
                perchedRect = tracked
                return (.perched, Self.perchPosition(previousX: previous.x, window: tracked))
            }
            // 沿屏幕边逐帧上升到吸附高度 → 转 perched(屏幕边)。
            if mode == .climbing, screenEdgeClimb {
                let nextY = previous.y + Self.climbSpeed * input.deltaTime
                if nextY >= climbTopY - Self.groundSnapEpsilon {
                    return (.perched, Point(x: climbEdgeX, y: climbTopY))   // 到吸附点 → 挂住
                }
                return (.climbing, Point(x: climbEdgeX, y: nextY))
            }
            // 攀爬中:沿窗口侧边逐帧上升,到顶转 perched;攀爬窗口没了 → 清掉走下面重力落回。
            if mode == .climbing, let rect = climbingRect {
                if let tracked = Self.matchWindow(to: rect, in: input.windows) {
                    climbingRect = tracked
                    let top = tracked.origin.y + tracked.height
                    let nextY = previous.y + Self.climbSpeed * input.deltaTime
                    if nextY >= top - Self.groundSnapEpsilon {
                        climbingRect = nil               // 到顶 → 站到顶边
                        perchedRect = tracked
                        return (.perched, Self.perchPosition(previousX: climbEdgeX, window: tracked))
                    }
                    return (.climbing, Point(x: climbEdgeX, y: nextY))   // 继续上爬
                }
                climbingRect = nil                       // 窗口没了 → 落回
            }
            // 否则漫步;途中越过可爬窗口侧边 → 沿侧边攀爬;贴屏幕边 → 吸附爬屏幕边。
            perchedRect = nil
            switch steppedRoam(previous: previous, input: input) {
            case let .climbWall(window, edgeX, facing):
                climbingRect = window
                screenEdgeClimb = false
                climbEdgeX = edgeX
                climbFacing = facing
                return (.climbing, Point(x: edgeX, y: previous.y + Self.climbSpeed * input.deltaTime))
            case let .climbScreenEdge(edgeX, topY, facing):
                climbingRect = nil
                screenEdgeClimb = true
                climbEdgeX = edgeX
                climbTopY = topY
                climbFacing = facing
                return (.climbing, Point(x: edgeX, y: previous.y + Self.climbSpeed * input.deltaTime))
            case let .walk(point):
                return (.roaming, point)
            }
        }
        // 漫游关:跟随开停在光标候选,否则原地不动(不追光标)。
        clearTransientState()
        return (.physics, input.followingEnabled ? candidate : previous)
    }

    private mutating func clearTransientState() {
        roamTargetX = nil
        roamPauseRemaining = 0
        perchedRect = nil
        climbingRect = nil
        screenEdgeClimb = false
    }

    /// 外部接管(用户拖拽)时调:清掉漫步路点 + 所站窗口 perch + 回 `.physics`。
    /// 否则松手后 `decide` 见 mode 仍 `.perched`/perchedRect 非空 → 直接 teleport 回拖拽前
    /// 所站的窗口顶边(表现为"松手就弹回原处")。清掉后松手从落点重力下落再重新漫游
    /// (参照上游开源项目 HermesPet (https://github.com/basionwang-bot/HermesPet)
    /// 拖拽开始时清 patrol/perch 状态的做法,逻辑级,未拷贝源码)。
    public mutating func clearForExternalControl() {
        mode = .physics
        clearTransientState()
    }

    // MARK: - 漫步积分 + 爬窗触发

    private enum RoamOutcome {
        case walk(Point)
        case climbWall(window: Rect, edgeX: Double, facing: PetFacing)
        /// 屏幕边吸附(吸附屏幕边 / 拖到边):edgeX = 屏幕左/右边,topY = 吸附高度,无窗口(无需 matchWindow)。
        case climbScreenEdge(edgeX: Double, topY: Double, facing: PetFacing)
    }

    /// 漫步一帧:先重力降到地面,落地后沿地面走向随机路点,到点暂停换路点;
    /// 走动途中越过可爬窗口的左/右侧边 + 概率命中 → 沿侧边攀爬(`.climbWall`)。
    private mutating func steppedRoam(previous: Point, input: PetMotionInput) -> RoamOutcome {
        let bounds = input.screenBounds
        let ground = bounds.origin.y
        let dt = input.deltaTime

        // 1. 悬空 → 重力下落到地面(失去窗口支撑后也走这条 → 落回地面)。
        if previous.y > ground + Self.groundSnapEpsilon {
            return .walk(Point(x: previous.x, y: max(ground, previous.y - Self.roamFallSpeed * dt)))
        }
        // 吸附屏幕边 / 拖到边:落到地面后 x 极贴屏幕左/右边(拖拽释放越过 roamEdgeMargin)→ 吸附爬屏幕边。
        // 阈值 < roamEdgeMargin,正常漫步(clamp 在 margin 内)不触发。
        let leftEdge = bounds.origin.x
        let rightEdge = bounds.origin.x + bounds.width
        let clingTop = ground + Self.screenEdgeClingHeight
        if previous.x <= leftEdge + Self.screenEdgeClingThreshold {
            return .climbScreenEdge(edgeX: leftEdge, topY: clingTop, facing: .left)   // 贴左边 → 面左(墙在左)
        }
        if previous.x >= rightEdge - Self.screenEdgeClingThreshold {
            return .climbScreenEdge(edgeX: rightEdge, topY: clingTop, facing: .right)  // 贴右边 → 面右
        }
        // 2. 在地面 —— 暂停中静止消耗计时。
        if roamPauseRemaining > 0 {
            roamPauseRemaining = max(0, roamPauseRemaining - dt)
            return .walk(Point(x: previous.x, y: ground))
        }
        // 3. 选路点。
        let minX = bounds.origin.x + Self.roamEdgeMargin
        let maxX = bounds.origin.x + bounds.width - Self.roamEdgeMargin
        if roamTargetX == nil {
            roamTargetX = maxX > minX ? (minX + rng.nextUnit() * (maxX - minX)) : previous.x
        }
        guard let target = roamTargetX else { return .walk(Point(x: previous.x, y: ground)) }

        // mood:活跃度 → 暂停时长 + 步速。lively(1)→ 暂停短、走得快;慵懒(0)→ 暂停长、走得慢。
        let lively = min(max(input.liveliness, 0), 1)

        // 4. 到达路点 → 暂停换路点;未到 → 朝路点走一步(途中越过可爬窗口侧边 → 概率爬墙)。
        let dx = target - previous.x
        if abs(dx) <= Self.roamArrivalEpsilon {
            roamTargetX = nil
            roamPauseRemaining = Self.roamPauseSeconds * (1.6 - lively)   // lively 0→1.6× / 1→0.6×
            return .walk(Point(x: previous.x, y: ground))
        }
        let step = Self.roamSpeed * (0.7 + 0.6 * lively) * dt   // lively 0→0.7× / 1→1.3×
        let nextX = abs(dx) <= step ? target : previous.x + (dx > 0 ? step : -step)
        let clampedX = maxX > minX ? min(max(nextX, minX), maxX) : nextX
        // 走动越过可爬窗口的左/右侧边 → 概率沿侧边攀爬。
        if let climb = Self.wallToClimb(fromX: previous.x, toX: clampedX, ground: ground, in: input.windows),
           rng.nextUnit() < Self.wallClimbChance {
            return .climbWall(window: climb.window, edgeX: climb.edgeX, facing: climb.facing)
        }
        return .walk(Point(x: clampedX, y: ground))
    }

    /// 漫步从 `fromX` 走到 `toX` 这一步是否越过某可爬窗口的左/右侧边。可爬 = 顶边够高
    /// (`perchMinElevation` 离地)+ 顶够宽可站(`perchMinWidth`)+ 窗口够高(`climbMinHeight`)。
    /// 命中返回越过的边 x + 面朝(贴左边=面右,墙在右侧)。多个取离 `fromX` 最近的。
    static func wallToClimb(fromX: Double, toX: Double, ground: Double, in windows: [Rect])
        -> (window: Rect, edgeX: Double, facing: PetFacing)? {
        let lo = min(fromX, toX), hi = max(fromX, toX)
        var best: (window: Rect, edgeX: Double, facing: PetFacing)?
        var bestDist = Double.greatestFiniteMagnitude
        for window in windows {
            let top = window.origin.y + window.height
            guard top - ground >= perchMinElevation,
                  window.width >= perchMinWidth,
                  window.height >= climbMinHeight else { continue }
            let left = window.origin.x
            let right = window.origin.x + window.width
            if left >= lo, left <= hi, abs(left - fromX) < bestDist {
                best = (window, left, .right); bestDist = abs(left - fromX)   // 墙在右 → 面右
            }
            if right >= lo, right <= hi, abs(right - fromX) < bestDist {
                best = (window, right, .left); bestDist = abs(right - fromX)  // 墙在左 → 面左
            }
        }
        return best
    }

    // MARK: - 爬窗几何(纯函数)

    /// 逐帧跟踪:在当前窗口列表里找与上帧所站矩形最接近的(origin 位移 + 尺寸变化
    /// 均在容差内)。找不到 → 窗口关了/移走了 → 返回 nil(触发落回地面)。
    static func matchWindow(to rect: Rect, in windows: [Rect]) -> Rect? {
        var best: Rect?
        var bestDist = Double.greatestFiniteMagnitude
        for window in windows {
            let originDist = abs(window.origin.x - rect.origin.x) + abs(window.origin.y - rect.origin.y)
            let sizeDelta = abs(window.width - rect.width) + abs(window.height - rect.height)
            if originDist <= perchMaxTrackShift, sizeDelta <= perchMaxSizeDelta, originDist < bestDist {
                best = window
                bestDist = originDist
            }
        }
        return best
    }

    /// 站立点:窗口顶边,x 取上帧 x clamp 到窗口跨度(随窗口横移自然跟随)。
    static func perchPosition(previousX: Double, window: Rect) -> Point {
        let top = window.origin.y + window.height
        let minX = window.origin.x + perchEdgeInset
        let maxX = window.origin.x + window.width - perchEdgeInset
        let x = maxX > minX ? min(max(previousX, minX), maxX) : window.origin.x + window.width / 2
        return Point(x: x, y: top)
    }

    // MARK: - 运动态派生

    /// 据帧间位移算运动态。漫步的下落/行走/暂停由位移自然落到 falling/walking/idle;
    /// 爬窗(perched)恒 `.perching`(站立,sprite 走 idle/sit 帧)。
    static func phase(from: Point, to: Point, mode: PetMotionMode) -> PetMotionPhase {
        if mode == .perched {
            return .perching
        }
        if mode == .climbing {   // 攀爬时 x 锚定侧边(dx≈0),朝向由 resolved 用 climbFacing 覆盖,此处兜底。
            return .climbing(to.x >= from.x ? .right : .left)
        }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < idleMotionEpsilon {
            return .idle
        }
        if dy < 0 && abs(dy) > abs(dx) * fallingDominanceRatio {
            return .falling
        }
        guard dx != 0 else {
            return .idle
        }
        return .walking(dx > 0 ? .right : .left)
    }
}
