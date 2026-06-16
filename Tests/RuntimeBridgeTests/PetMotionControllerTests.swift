import Testing
@testable import RuntimeBridge
import Context

// MARK: - PetMotionController 基础仲裁与 phase 派生测试
//
// 不变式:仲裁恒为 .physics(透传上游候选)→ 位置零回归;运动态 phase
// 据 previousPosition → 最终位置 的位移正确派生(walking 朝向 / idle / falling)。
// 控制器位置无状态:phase 基准由调用方每帧传入(免 staleness)。漫步 / 爬窗
// 行为的测试见对应测试文件。

@Test("physics 模式透传候选位置,模式恒为 .physics")
func physicsModePassesThroughCandidate() {
    let controller = PetMotionController()
    let candidate = Point(x: 123, y: 456)
    let (next, frame) = controller.resolved(
        previousPosition: Point(x: 0, y: 0),
        physicsCandidate: candidate,
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: candidate)
    )

    #expect(frame.position == candidate)
    #expect(frame.mode == .physics)
    #expect(next.mode == .physics)
}

@Test("向右移动 → walking(.right)")
func walkingRightWhenMovingRight() {
    let controller = PetMotionController()
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 0, y: 0),
        physicsCandidate: Point(x: 30, y: 0),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 30, y: 0))
    )
    #expect(frame.phase == .walking(.right))
}

@Test("向左移动 → walking(.left)")
func walkingLeftWhenMovingLeft() {
    let controller = PetMotionController()
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 100, y: 0),
        physicsCandidate: Point(x: 70, y: 0),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 70, y: 0))
    )
    #expect(frame.phase == .walking(.left))
}

@Test("位移低于阈值 → idle")
func idlePhaseWhenStationary() {
    let controller = PetMotionController()
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 50, y: 50),
        physicsCandidate: Point(x: 50.1, y: 50.1),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 50.1, y: 50.1))
    )
    #expect(frame.phase == .idle)
}

@Test("纯垂直向上(无水平分量)→ idle,不误切走帧")
func verticalUpWithoutHorizontalIsIdle() {
    let controller = PetMotionController()
    // dx = 0, dy = +40(向上)→ 非下落、无朝向 → idle
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 10, y: 0),
        physicsCandidate: Point(x: 10, y: 40),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 10, y: 40))
    )
    #expect(frame.phase == .idle)
}

@Test("垂直向下主导 → falling")
func fallingPhaseWhenVerticalDown() {
    let controller = PetMotionController()
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 0, y: 100),
        physicsCandidate: Point(x: 0, y: 40),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 0, y: 40))
    )
    #expect(frame.phase == .falling)
}

@Test("斜向下(水平分量大)不误判 falling,走 walking")
func diagonalIsWalkingNotFalling() {
    let controller = PetMotionController()
    // dx = 60, dy = -20 → |dy| < |dx|*2 → 不下落,按 dx 符号走 walking(.right)
    let (_, frame) = controller.resolved(
        previousPosition: Point(x: 0, y: 100),
        physicsCandidate: Point(x: 60, y: 80),
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: Point(x: 60, y: 80))
    )
    #expect(frame.phase == .walking(.right))
}

@Test("phase 基准由调用方传入 —— 同候选不同 previousPosition 得不同朝向")
func phaseDerivesFromCallerProvidedPrevious() {
    let controller = PetMotionController()
    let candidate = Point(x: 50, y: 0)
    // 从左侧(20)来 → 向右走
    let (_, fromLeft) = controller.resolved(
        previousPosition: Point(x: 20, y: 0),
        physicsCandidate: candidate,
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: candidate)
    )
    #expect(fromLeft.phase == .walking(.right))
    // 从右侧(90)来 → 向左走(证明 phase 基准是传入的 previousPosition,非内部存储)
    let (_, fromRight) = controller.resolved(
        previousPosition: Point(x: 90, y: 0),
        physicsCandidate: candidate,
        input: PetMotionInput(deltaTime: 1.0 / 60.0, cursorPosition: candidate)
    )
    #expect(fromRight.phase == .walking(.left))
}

@Test("静态 phase helper —— perched 模式恒 .perching")
func perchedModeYieldsPerchingPhase() {
    let phase = PetMotionController.phase(
        from: Point(x: 0, y: 0),
        to: Point(x: 999, y: 999),
        mode: .perched
    )
    #expect(phase == .perching)
}
