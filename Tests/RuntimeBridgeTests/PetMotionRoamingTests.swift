import Testing
@testable import RuntimeBridge
import Context

// MARK: - PetMotionController 漫步测试
//
// 漫步状态机:idle ≥ 阈值 → .roaming → 先重力降到地面(.falling)→ 沿地面走向
// 随机路点(.walking)→ 到点暂停(.idle)→ 换路点。确定性 PRNG(给定 seed)让
// 多帧轨迹可断言。

private let dt = 1.0 / 60.0
private let testBounds = Rect(origin: Point(x: 0, y: 100), width: 1000, height: 700)

/// 在恒定输入下驱动控制器 N 帧,返回逐帧位置轨迹(线程权威 previousPosition)。
private func driveRoam(
    seed: UInt64 = 0x1234_5678,
    start: Point,
    idleSeconds: Double,
    frames: Int,
    bounds: Rect = testBounds
) -> (controller: PetMotionController, trajectory: [PetMotionFrame]) {
    var controller = PetMotionController(seed: seed)
    var position = start
    var frameList: [PetMotionFrame] = []
    for _ in 0..<frames {
        let input = PetMotionInput(
            deltaTime: dt,
            cursorPosition: position, // 漫步忽略候选,光标无关
            windows: [],
            screenBounds: bounds,
            idleSeconds: idleSeconds
        )
        let result = controller.resolved(
            previousPosition: position,
            physicsCandidate: position,
            input: input
        )
        controller = result.controller
        position = result.frame.position
        frameList.append(result.frame)
    }
    return (controller, frameList)
}

@Test("空闲 ≥ 阈值 → 进 .roaming")
func idleAboveThresholdEntersRoaming() {
    let (_, frames) = driveRoam(start: Point(x: 500, y: 100), idleSeconds: 10, frames: 1)
    #expect(frames[0].mode == .roaming)
}

@Test("空闲 < 阈值 → 留 .physics")
func idleBelowThresholdStaysPhysics() {
    let (_, frames) = driveRoam(start: Point(x: 500, y: 100), idleSeconds: 5, frames: 1)
    #expect(frames[0].mode == .physics)
}

@Test("漫步先重力降到地面(纯垂直下落,phase=.falling)")
func roamingDescendsToGroundFirst() {
    // 起点高出地面 300px
    let (_, frames) = driveRoam(start: Point(x: 500, y: 400), idleSeconds: 10, frames: 1)
    let f = frames[0]
    #expect(f.mode == .roaming)
    #expect(f.position.x == 500)          // 下落不改 x
    #expect(f.position.y < 400)           // y 减少
    #expect(f.position.y >= 100)          // 不穿地
    #expect(f.phase == .falling)
}

@Test("落地后沿地面行走(y 锁地面,每帧位移 ≤ 行走步长)")
func roamingWalksAlongGroundOnce() {
    // 起点已在地面
    let (_, frames) = driveRoam(start: Point(x: 500, y: 100), idleSeconds: 10, frames: 1)
    let f = frames[0]
    #expect(f.position.y == 100)          // 锁地面
    let stepBudget = PetMotionController.roamSpeed * dt + 0.001
    #expect(abs(f.position.x - 500) <= stepBudget)
    // 走或(极小概率)正好到点暂停;无论哪种都不是 falling/perching
    #expect(f.phase == .walking(.left) || f.phase == .walking(.right) || f.phase == .idle)
}

@Test("长程漫步全程不越屏内边距,且 y 锁地面")
func roamingStaysInBounds() {
    let margin = PetMotionController.roamEdgeMargin
    let (_, frames) = driveRoam(start: Point(x: 500, y: 100), idleSeconds: 10, frames: 1800)
    for f in frames {
        #expect(f.position.x >= testBounds.origin.x + margin - 0.001)
        #expect(f.position.x <= testBounds.origin.x + testBounds.width - margin + 0.001)
        #expect(f.position.y == 100)
    }
}

@Test("长程漫步会真的走动(位移显著)且触发到点暂停(出现 idle 帧)")
func roamingMovesAndPauses() {
    let (_, frames) = driveRoam(start: Point(x: 500, y: 100), idleSeconds: 10, frames: 1800)
    let xs = frames.map(\.position.x)
    let span = (xs.max() ?? 0) - (xs.min() ?? 0)
    #expect(span > 100)                                   // 确实溜达了一段
    #expect(frames.contains { $0.phase == .idle })        // 到点暂停过
    #expect(frames.contains { if case .walking = $0.phase { return true } else { return false } })
}

@Test("离开漫步(回 physics)清空溜达状态")
func leavingRoamingClearsState() {
    var controller = PetMotionController(seed: 0xABCD)
    // 漫步若干帧让它选好路点 + 走起来
    var pos = Point(x: 500, y: 100)
    for _ in 0..<30 {
        let r = controller.resolved(
            previousPosition: pos,
            physicsCandidate: pos,
            input: PetMotionInput(deltaTime: dt, cursorPosition: pos, screenBounds: testBounds, idleSeconds: 10)
        )
        controller = r.controller
        pos = r.frame.position
    }
    // 用户回来 → physics 一帧,透传候选
    let candidate = Point(x: 800, y: 300)
    let back = controller.resolved(
        previousPosition: pos,
        physicsCandidate: candidate,
        input: PetMotionInput(deltaTime: dt, cursorPosition: candidate, screenBounds: testBounds, idleSeconds: 0)
    )
    #expect(back.frame.mode == .physics)
    #expect(back.frame.position == candidate)
}

@Test("漫步轨迹对 seed 确定(同 seed 两次跑完全一致)")
func roamingDeterministicForSeed() {
    let a = driveRoam(seed: 0x55AA, start: Point(x: 500, y: 100), idleSeconds: 10, frames: 600).trajectory
    let b = driveRoam(seed: 0x55AA, start: Point(x: 500, y: 100), idleSeconds: 10, frames: 600).trajectory
    #expect(a == b)
}

@Test("不同 seed 漫步路点不同(PRNG 真起作用)")
func roamingDiffersBySeed() {
    let a = driveRoam(seed: 0x1111, start: Point(x: 500, y: 100), idleSeconds: 10, frames: 600).trajectory
    let b = driveRoam(seed: 0x2222, start: Point(x: 500, y: 100), idleSeconds: 10, frames: 600).trajectory
    #expect(a != b)
}
