import Foundation
import Testing
import PetBehavior

/// 覆盖加权随机状态机:全局池/转移候选选取、frequency=0 排除、nextAdditive 隔离、ref 自带权重、
/// 条件门控、total=0 兜底、自定义兜底名、未知 previous 退化、权重分布。
@Suite("ShimejiBehaviorScheduler")
struct ShimejiBehaviorSchedulerTests {
    // MARK: - builders

    private func makeGraph(_ behaviors: [ShimejiBehavior]) -> ShimejiBehaviorGraph {
        var dict: [String: ShimejiBehavior] = [:]
        var order: [String] = []
        for b in behaviors {
            if dict[b.name] == nil { order.append(b.name) }
            dict[b.name] = b
        }
        return ShimejiBehaviorGraph(behaviors: dict, topLevelOrder: order)
    }

    private func bb(
        _ name: String,
        freq: Int,
        conditions: [String] = [],
        nextAdditive: Bool = true,
        next: [ShimejiBehaviorReference] = []
    ) -> ShimejiBehavior {
        ShimejiBehavior(
            name: name, actionName: name, frequency: freq, hidden: false,
            conditions: conditions, nextAdditive: nextAdditive, nextBehaviors: next
        )
    }

    private func ref(_ name: String, freq: Int, conditions: [String] = []) -> ShimejiBehaviorReference {
        ShimejiBehaviorReference(name: name, frequency: freq, conditions: conditions, hidden: false)
    }

    private let allTrue = AlwaysTrueConditionEvaluator()

    // MARK: - 结构性(RNG 无关)

    @Test("单一 effective 候选恒被选中")
    func singleCandidate() {
        let scheduler = ShimejiBehaviorScheduler(graph: makeGraph([bb("Walk", freq: 100)]))
        var rng = SeededRNG(seed: 1)
        for _ in 0..<50 {
            #expect(scheduler.pickNext(previous: nil, evaluator: allTrue, using: &rng) == "Walk")
        }
    }

    @Test("frequency=0 不进全局池 → total=0 → 兜底 Fall")
    func zeroFrequencyExcluded() {
        let scheduler = ShimejiBehaviorScheduler(graph: makeGraph([bb("Idle", freq: 0)]))
        var rng = SeededRNG(seed: 1)
        #expect(scheduler.pickNext(previous: nil, evaluator: allTrue, using: &rng) == "Fall")
    }

    @Test("自定义兜底名")
    func customFallback() {
        let scheduler = ShimejiBehaviorScheduler(
            graph: makeGraph([bb("Idle", freq: 0)]),
            fallbackBehaviorName: "DropToGround"
        )
        var rng = SeededRNG(seed: 1)
        #expect(scheduler.pickNext(previous: nil, evaluator: allTrue, using: &rng) == "DropToGround")
    }

    @Test("nextAdditive=false → 只选转移引用,排除全局池;ref 自带频率可达 freq=0 目标")
    func additiveFalseIsolatesRefs() {
        let graph = makeGraph([
            bb("Walk", freq: 100),                                              // 全局池
            bb("SitDown", freq: 0, nextAdditive: false, next: [ref("LieDown", freq: 100)]),
            bb("LieDown", freq: 0),                                             // 自身 freq=0,只能经 ref 到达
        ])
        let scheduler = ShimejiBehaviorScheduler(graph: graph)
        var rng = SeededRNG(seed: 7)
        for _ in 0..<100 {
            // previous=SitDown(Add=false)→ 候选只有 [LieDown via ref],绝不出现全局池的 Walk
            #expect(scheduler.pickNext(previous: "SitDown", evaluator: allTrue, using: &rng) == "LieDown")
        }
    }

    @Test("nextAdditive=true → 转移引用 ∪ 全局池")
    func additiveTrueUnionsGlobalPool() {
        let graph = makeGraph([
            bb("Walk", freq: 100),
            bb("SitDown", freq: 0, nextAdditive: true, next: [ref("LieDown", freq: 100)]),
            bb("LieDown", freq: 0),
        ])
        let scheduler = ShimejiBehaviorScheduler(graph: graph)
        var rng = SeededRNG(seed: 3)
        var seen: Set<String> = []
        for _ in 0..<300 {
            seen.insert(scheduler.pickNext(previous: "SitDown", evaluator: allTrue, using: &rng))
        }
        #expect(seen == ["Walk", "LieDown"])   // 两者都可达
    }

    @Test("条件门控:条件不成立的行为被排除")
    func conditionGating() {
        let graph = makeGraph([
            bb("Sit", freq: 100, conditions: ["onFloor"]),
            bb("Climb", freq: 100, conditions: ["onWall"]),
        ])
        let scheduler = ShimejiBehaviorScheduler(graph: graph)
        let eval = StubConditionEvaluator(results: ["onFloor": true, "onWall": false], defaultValue: true)
        var rng = SeededRNG(seed: 9)
        for _ in 0..<100 {
            #expect(scheduler.pickNext(previous: nil, evaluator: eval, using: &rng) == "Sit")
        }
    }

    @Test("所有条件不成立 → total=0 → 兜底")
    func allConditionsFalseFallsBack() {
        let graph = makeGraph([
            bb("Sit", freq: 100, conditions: ["onFloor"]),
            bb("Climb", freq: 100, conditions: ["onWall"]),
        ])
        let scheduler = ShimejiBehaviorScheduler(graph: graph)
        let eval = StubConditionEvaluator(results: [:], defaultValue: false)
        var rng = SeededRNG(seed: 1)
        #expect(scheduler.pickNext(previous: nil, evaluator: eval, using: &rng) == "Fall")
    }

    @Test("未知 previous 名退化为初始(全局池)")
    func unknownPreviousFallsToGlobalPool() {
        let scheduler = ShimejiBehaviorScheduler(graph: makeGraph([bb("Walk", freq: 100)]))
        var rng = SeededRNG(seed: 5)
        #expect(scheduler.pickNext(previous: "Ghost", evaluator: allTrue, using: &rng) == "Walk")
    }

    // MARK: - 分布(种子 RNG,统计)

    @Test("权重决定分布:100:1 经验比 ≈ 100:1")
    func weightedDistribution() {
        let graph = makeGraph([bb("Common", freq: 100), bb("Rare", freq: 1)])
        let scheduler = ShimejiBehaviorScheduler(graph: graph)
        var rng = SeededRNG(seed: 42)
        var counts: [String: Int] = [:]
        let trials = 10_100
        for _ in 0..<trials {
            counts[scheduler.pickNext(previous: nil, evaluator: allTrue, using: &rng), default: 0] += 1
        }
        let common = counts["Common"] ?? 0
        let rare = counts["Rare"] ?? 0
        #expect(common + rare == trials)          // 无遗漏、无兜底
        #expect(rare > 0)                          // 稀有事件确实发生
        #expect(common > rare * 20)                // ≈100:1(预期 ~10000:100),宽松容差
    }
}
