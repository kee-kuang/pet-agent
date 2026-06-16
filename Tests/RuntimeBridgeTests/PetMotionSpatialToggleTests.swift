import Testing
@testable import RuntimeBridge
import Context

// MARK: - 跟随 / 漫游 两开关解耦
//
// 关键新行为:跟随**关** + 漫游**开** → 即使用户活跃(idle<阈值)也连续漫游
// (用户显式要「自由漫步」);跟随**开**时才用 idle 阈值分流(活跃追光标 / 空闲漫游)。

private let dt = 1.0 / 60.0
private let bounds = Rect(origin: Point(x: 0, y: 100), width: 1000, height: 700)

private func step(
    following: Bool,
    roaming: Bool,
    idleSeconds: Double,
    previous: Point,
    candidate: Point,
    seed: UInt64 = 0x1234
) -> PetMotionFrame {
    var controller = PetMotionController(seed: seed)
    let input = PetMotionInput(
        deltaTime: dt, cursorPosition: candidate, windows: [], screenBounds: bounds,
        idleSeconds: idleSeconds, followingEnabled: following, roamingEnabled: roaming
    )
    return controller.resolved(previousPosition: previous, physicsCandidate: candidate, input: input).frame
}

@Test("跟随关 + 漫游开 + 用户活跃 → 仍连续漫游(不冻结、不追光标)")
func roamingOnlyRoamsEvenWhenUserActive() {
    // 起点高出地面 → 漫游第一步重力下落;若没漫游(冻结/追光标)则不会下落。
    let f = step(following: false, roaming: true, idleSeconds: 0,
                 previous: Point(x: 500, y: 400), candidate: Point(x: 900, y: 400))
    #expect(f.mode == .roaming)
    #expect(f.position.y < 400)          // 重力下落 = 漫游确实在跑
    #expect(f.position.x == 500)         // 没去追光标候选(900)
}

@Test("跟随关 + 漫游关 → 原地不动(physics,忽略光标候选)")
func bothOffHoldsInPlace() {
    let prev = Point(x: 500, y: 100)
    let f = step(following: false, roaming: false, idleSeconds: 0,
                 previous: prev, candidate: Point(x: 900, y: 300))
    #expect(f.mode == .physics)
    #expect(f.position == prev)          // 不追光标,停在原地
}

@Test("跟随开 + 漫游关 + 用户活跃 → 追光标候选")
func followingOnlyActiveFollowsCursor() {
    let candidate = Point(x: 820, y: 260)
    let f = step(following: true, roaming: false, idleSeconds: 0,
                 previous: Point(x: 500, y: 100), candidate: candidate)
    #expect(f.mode == .physics)
    #expect(f.position == candidate)
}

@Test("跟随开 + 漫游关 + 用户空闲 → 不漫游,仍停在光标候选")
func followingOnlyIdleDoesNotRoam() {
    let candidate = Point(x: 700, y: 100)
    let f = step(following: true, roaming: false, idleSeconds: 30,
                 previous: Point(x: 500, y: 100), candidate: candidate)
    #expect(f.mode == .physics)
    #expect(f.position == candidate)     // 漫游关 → 不进 .roaming
}

@Test("跟随开 + 漫游开 + 用户活跃 → 追光标(跟随优先,不漫游)")
func bothOnActiveFollowsCursor() {
    let candidate = Point(x: 640, y: 220)
    let f = step(following: true, roaming: true, idleSeconds: 0,
                 previous: Point(x: 500, y: 100), candidate: candidate)
    #expect(f.mode == .physics)
    #expect(f.position == candidate)
}

@Test("跟随开 + 漫游开 + 用户空闲 → 漫游(原有行为保留)")
func bothOnIdleRoams() {
    let f = step(following: true, roaming: true, idleSeconds: 30,
                 previous: Point(x: 500, y: 400), candidate: Point(x: 500, y: 400))
    #expect(f.mode == .roaming)
    #expect(f.position.y < 400)          // 下落 = 漫游
}
