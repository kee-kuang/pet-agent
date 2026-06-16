import Foundation
import Testing
import PetBehavior

/// 端到端:behaviors.xml 解析 → JSC 条件求值 → 加权随机选取,验证解析层与条件求值层串起来真按位置门控行为。
/// 合成 fixture(许可干净):地面/天花板各自条件门控的行为 + 兜底。
@Suite("行为引擎集成(解析→条件求值→加权选取)")
struct BehaviorEngineIntegrationTests {
    static let behaviorsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <BehaviorList>
            <Behavior Name="Fall" Frequency="0" Hidden="true" />
            <Condition Condition="#{mascot.environment.floor.isOn(mascot.anchor)}">
                <Behavior Name="WalkOnFloor" Frequency="100" />
                <Behavior Name="SitOnFloor" Frequency="100" />
            </Condition>
            <Condition Condition="#{mascot.environment.ceiling.isOn(mascot.anchor)}">
                <Behavior Name="HangFromCeiling" Frequency="100" />
            </Condition>
        </BehaviorList>
    </Mascot>
    """

    // top-origin:workArea [0,0,1920,1040](floor=bottom y=1040,ceiling=top y=0)。
    private func mascot(at anchor: BehaviorPoint) -> BehaviorMascot {
        BehaviorMascot(
            anchor: anchor, lookRight: true, totalCount: 1,
            environment: BehaviorEnvironment(
                workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
                activeWindow: .invisible,
                screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080)
            )
        )
    }

    private func graph() throws -> ShimejiBehaviorGraph {
        try #require(ShimejiBehaviorParser.parse(Data(Self.behaviorsXML.utf8)))
    }

    @Test("地面 mascot 只选地面行为,绝不选天花板行为")
    func floorMascotPicksFloorBehaviors() throws {
        let scheduler = ShimejiBehaviorScheduler(graph: try graph())
        let evaluator = JSConditionEvaluator(mascot: mascot(at: BehaviorPoint(x: 960, y: 1040)))
        var rng = SeededRNG(seed: 1)
        var seen: Set<String> = []
        for _ in 0..<200 {
            seen.insert(scheduler.pickNext(previous: nil, evaluator: evaluator, using: &rng))
        }
        #expect(seen.isSubset(of: ["WalkOnFloor", "SitOnFloor"]))
        #expect(seen.contains("WalkOnFloor"))
        #expect(seen.contains("SitOnFloor"))
        #expect(!seen.contains("HangFromCeiling"))
    }

    @Test("天花板 mascot 只选天花板行为")
    func ceilingMascotPicksCeilingBehavior() throws {
        let scheduler = ShimejiBehaviorScheduler(graph: try graph())
        let evaluator = JSConditionEvaluator(mascot: mascot(at: BehaviorPoint(x: 960, y: 0)))
        var rng = SeededRNG(seed: 2)
        for _ in 0..<50 {
            #expect(scheduler.pickNext(previous: nil, evaluator: evaluator, using: &rng) == "HangFromCeiling")
        }
    }

    @Test("半空 mascot:全条件 false → 兜底 Fall")
    func midAirFallsBack() throws {
        let scheduler = ShimejiBehaviorScheduler(graph: try graph())
        let evaluator = JSConditionEvaluator(mascot: mascot(at: BehaviorPoint(x: 960, y: 500)))
        var rng = SeededRNG(seed: 3)
        #expect(scheduler.pickNext(previous: nil, evaluator: evaluator, using: &rng) == "Fall")
    }
}
