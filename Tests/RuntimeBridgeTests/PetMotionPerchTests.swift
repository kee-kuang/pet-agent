import Testing
@testable import RuntimeBridge
import Context

// MARK: - PetMotionController 爬窗测试
//
// 爬窗:漫步到窗口下方暂停时按概率爬上窗口顶边(snap),x/y 跟随窗口移动;窗口
// 关闭/移走 → 解除 → 落回地面。坐标系:窗口矩形底原点,与 pet 位置同系。

private let dt = 1.0 / 60.0
private let bounds = Rect(origin: Point(x: 0, y: 100), width: 1000, height: 700)
// 横跨大半屏、顶边高出地面 600px 的可站窗口。
private let bigWindow = Rect(origin: Point(x: 100, y: 400), width: 800, height: 300)

/// 在恒定输入(给定窗口列表)下驱动 N 帧,返回轨迹。
private func drive(
    seed: UInt64,
    start: Point,
    idleSeconds: Double,
    windows: [Rect],
    frames: Int
) -> (controller: PetMotionController, trajectory: [PetMotionFrame]) {
    var controller = PetMotionController(seed: seed)
    var position = start
    var list: [PetMotionFrame] = []
    for _ in 0..<frames {
        let input = PetMotionInput(
            deltaTime: dt,
            cursorPosition: position,
            windows: windows,
            screenBounds: bounds,
            idleSeconds: idleSeconds
        )
        let r = controller.resolved(previousPosition: position, physicsCandidate: position, input: input)
        controller = r.controller
        position = r.frame.position
        list.append(r.frame)
    }
    return (controller, list)
}

// MARK: - 纯几何 helper

@Test("wallToClimb —— 越过可爬窗口侧边返回边x+面朝(墙在右=面右)")
func wallToClimbDetectsEdges() {
    let ground = 100.0
    // 从左侧 90 走到 110 越过左边 100 → 命中,墙在右 → 面右。
    let left = PetMotionController.wallToClimb(fromX: 90, toX: 110, ground: ground, in: [bigWindow])
    #expect(left?.edgeX == 100)
    #expect(left?.facing == .right)
    // 从右侧 910 走到 890 越过右边 900 → 墙在左 → 面左。
    let right = PetMotionController.wallToClimb(fromX: 910, toX: 890, ground: ground, in: [bigWindow])
    #expect(right?.edgeX == 900)
    #expect(right?.facing == .left)
    // 没越过任何边(500→520 在窗内)→ nil。
    #expect(PetMotionController.wallToClimb(fromX: 500, toX: 520, ground: ground, in: [bigWindow]) == nil)
    // 太矮(height < climbMinHeight 80)→ 不爬。
    let lowWin = Rect(origin: Point(x: 100, y: 110), width: 800, height: 30)
    #expect(PetMotionController.wallToClimb(fromX: 90, toX: 110, ground: ground, in: [lowWin]) == nil)
}

@Test("越过窗口侧边 → 进 .climbing 逐帧上升 → 到顶转 .perched(非瞬移)")
func climbsWallGraduallyToTop() {
    let (_, frames) = drive(seed: 0x7777, start: Point(x: 500, y: 100), idleSeconds: 10, windows: [bigWindow], frames: 3000)
    #expect(frames.contains { $0.mode == .climbing })   // 有攀爬过程(逐帧,非瞬移)
    let perchedIdx = frames.firstIndex { $0.mode == .perched }
    #expect(perchedIdx != nil)
    if let pi = perchedIdx {
        #expect(frames[pi].position.y == bigWindow.origin.y + bigWindow.height)  // 顶边 700
        #expect(frames[..<pi].contains { $0.mode == .climbing })                  // perch 前先攀爬
        // 攀爬帧 phase 为 .climbing(带朝向)
        #expect(frames.contains { if case .climbing = $0.phase { return true } else { return false } })
    }
}

@Test("perchPosition 站到窗口顶边,x clamp 进窗口跨度")
func perchPositionSnapsToTop() {
    let p = PetMotionController.perchPosition(previousX: 500, window: bigWindow)
    #expect(p.y == bigWindow.origin.y + bigWindow.height) // 700
    #expect(p.x == 500)                                    // 在跨度内,保持
    // 越界 x 被 clamp 到窗口内缩边
    let pLeft = PetMotionController.perchPosition(previousX: 0, window: bigWindow)
    #expect(pLeft.x == bigWindow.origin.x + PetMotionController.perchEdgeInset) // 108
}

@Test("matchWindow —— 小幅移动可跟踪,大幅跳变失配")
func matchWindowTracking() {
    let moved = Rect(origin: Point(x: 130, y: 410), width: 800, height: 300) // 移 30+10
    #expect(PetMotionController.matchWindow(to: bigWindow, in: [moved]) == moved)
    let jumped = Rect(origin: Point(x: 700, y: 400), width: 800, height: 300) // 移 600
    #expect(PetMotionController.matchWindow(to: bigWindow, in: [jumped]) == nil)
    #expect(PetMotionController.matchWindow(to: bigWindow, in: []) == nil)
}

// MARK: - 行为(多帧)

@Test("漫步越过窗口侧边 → 最终爬上窗口顶边")
func roamingClimbsOntoWindow() {
    // 起点在地面;长跑足够多帧让走动越过窗口左/右侧边 + 0.5 概率命中沿侧边爬到顶。
    let (_, frames) = drive(seed: 0x7777, start: Point(x: 500, y: 100), idleSeconds: 10, windows: [bigWindow], frames: 3000)
    let perched = frames.first { $0.mode == .perched }
    #expect(perched != nil)
    if let p = perched {
        #expect(p.position.y == bigWindow.origin.y + bigWindow.height) // 站在顶边 700
        #expect(p.phase == .perching)
    }
}

@Test("已站窗口 → 窗口横移,pet x 跟随")
func perchedFollowsHorizontalMove() {
    // 先驱动到爬上窗口
    var controller = PetMotionController(seed: 0x7777)
    var pos = Point(x: 500, y: 100)
    var climbed = false
    for _ in 0..<3000 {
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10)
        )
        controller = r.controller; pos = r.frame.position
        if r.frame.mode == .perched { climbed = true; break }
    }
    #expect(climbed)
    // 窗口右移 60px(分 6 帧每帧 10,模拟用户拖窗)
    var win = bigWindow
    for _ in 0..<6 {
        win = Rect(origin: Point(x: win.origin.x + 10, y: win.origin.y), width: win.width, height: win.height)
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [win], screenBounds: bounds, idleSeconds: 10)
        )
        controller = r.controller; pos = r.frame.position
        #expect(r.frame.mode == .perched)
    }
    // pet 仍站在(右移后的)窗口顶边
    #expect(pos.y == win.origin.y + win.height)
    #expect(pos.x >= win.origin.x + PetMotionController.perchEdgeInset)
    #expect(pos.x <= win.origin.x + win.width - PetMotionController.perchEdgeInset)
}

@Test("所站窗口消失 → 解除 perch,落回地面")
func perchedFallsWhenWindowGone() {
    var controller = PetMotionController(seed: 0x7777)
    var pos = Point(x: 500, y: 100)
    for _ in 0..<3000 {
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10)
        )
        controller = r.controller; pos = r.frame.position
        if r.frame.mode == .perched { break }
    }
    #expect(pos.y == bigWindow.origin.y + bigWindow.height) // 在顶边
    // 窗口消失 → 后续帧应解除 + 下落到地面
    var lastFrame: PetMotionFrame!
    for _ in 0..<600 {
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [], screenBounds: bounds, idleSeconds: 10)
        )
        controller = r.controller; pos = r.frame.position; lastFrame = r.frame
    }
    #expect(lastFrame.mode != .perched)   // 不再站着
    #expect(pos.y == bounds.origin.y)     // 落回地面 100
}

@Test("用户活跃 → 退出 perch 回 physics 透传候选")
func userActiveExitsPerch() {
    var controller = PetMotionController(seed: 0x7777)
    var pos = Point(x: 500, y: 100)
    for _ in 0..<3000 {
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10)
        )
        controller = r.controller; pos = r.frame.position
        if r.frame.mode == .perched { break }
    }
    // 用户回来(idleSeconds=0)→ physics,位置透传候选
    let candidate = Point(x: 200, y: 300)
    let r = controller.resolved(
        previousPosition: pos,
        physicsCandidate: candidate,
        input: PetMotionInput(deltaTime: dt, cursorPosition: candidate, windows: [bigWindow], screenBounds: bounds, idleSeconds: 0)
    )
    #expect(r.frame.mode == .physics)
    #expect(r.frame.position == candidate)
}

// MARK: - 拖拽接管清 perch(回归:松手不弹回原窗口)

@Test("拖拽: clearForExternalControl 清掉 perch → 松手从落点下落,不 snap 回原窗口顶边")
func clearForExternalControlDropsPerchState() {
    // 先驱动到 perched(复用 roamingClimbsOntoWindow 的确定 seed/帧)。
    var controller = PetMotionController(seed: 0x7777)
    var pos = Point(x: 500, y: 100)
    for _ in 0..<3000 {
        let r = controller.resolved(
            previousPosition: pos, physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10))
        controller = r.controller; pos = r.frame.position
        if r.frame.mode == .perched { break }
    }
    #expect(controller.mode == .perched)

    let draggedPos = Point(x: 300, y: 250)   // 模拟被拖到高空别处

    // 对照(bug):不清状态 → 下一帧 decide 仍 snap 回原 perch 顶边(=用户说的"回到原处")。
    var noClear = controller
    let snapBack = noClear.resolved(
        previousPosition: draggedPos, physicsCandidate: draggedPos,
        input: PetMotionInput(deltaTime: dt, cursorPosition: draggedPos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10))
    #expect(snapBack.frame.mode == .perched)
    #expect(snapBack.frame.position.y == bigWindow.origin.y + bigWindow.height)   // 弹回顶边 700

    // 修复:clearForExternalControl 后 → 回 .physics,从落点重力下落,不弹回。
    controller.clearForExternalControl()
    #expect(controller.mode == .physics)
    let afterDrop = controller.resolved(
        previousPosition: draggedPos, physicsCandidate: draggedPos,
        input: PetMotionInput(deltaTime: dt, cursorPosition: draggedPos, windows: [bigWindow], screenBounds: bounds, idleSeconds: 10))
    #expect(afterDrop.frame.mode != .perched)          // 不 snap 回 perch
    #expect(afterDrop.frame.position.y < draggedPos.y)  // 重力下落
}

// MARK: - mood 漫步 + 屏幕边吸附

@Test("高活跃度漫步比低活跃度走得更远(暂停短 + 步速快)")
func livelinessAffectsRoamDistance() {
    func roamSpan(_ liveliness: Double) -> Double {
        var c = PetMotionController(seed: 0xA1)
        var pos = Point(x: 500, y: 100); var total = 0.0
        for _ in 0..<1200 {
            let r = c.resolved(
                previousPosition: pos, physicsCandidate: pos,
                input: PetMotionInput(deltaTime: dt, cursorPosition: pos, screenBounds: bounds,
                                      idleSeconds: 10, liveliness: liveliness))
            c = r.controller; total += abs(r.frame.position.x - pos.x); pos = r.frame.position
        }
        return total
    }
    #expect(roamSpan(0.9) > roamSpan(0.1))   // 活泼累计行走距离更大
}

@Test("落到地面 x 贴屏幕左边(<阈值)→ 吸附爬屏幕边到 clingHeight 并保持(不掉回)")
func clingsToScreenEdgeNearLeft() {
    var c = PetMotionController(seed: 0x55)
    var pos = Point(x: bounds.origin.x + 3, y: bounds.origin.y)   // x=3 贴左,在地面(模拟拖到极左释放)
    var sawClimbing = false; var perchedY: Double?
    for _ in 0..<400 {
        let r = c.resolved(
            previousPosition: pos, physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [], screenBounds: bounds, idleSeconds: 10))
        c = r.controller; pos = r.frame.position
        if r.frame.mode == .climbing { sawClimbing = true }
        if r.frame.mode == .perched { perchedY = pos.y; break }
    }
    #expect(sawClimbing)                                            // 有逐帧攀爬过程
    #expect(perchedY == bounds.origin.y + PetMotionController.screenEdgeClingHeight)  // 吸附在 clingHeight
    #expect(abs(pos.x - bounds.origin.x) < 1)                      // 锚定屏幕左边
    // 保持:再跑一帧仍 perched 且位置不变(不掉回地面)
    let hold = c.resolved(
        previousPosition: pos, physicsCandidate: pos,
        input: PetMotionInput(deltaTime: dt, cursorPosition: pos, windows: [], screenBounds: bounds, idleSeconds: 10))
    #expect(hold.frame.mode == .perched)
    #expect(hold.frame.position == pos)
}
