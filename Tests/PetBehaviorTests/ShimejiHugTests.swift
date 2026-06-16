import Foundation
import Testing
import PetBehavior

/// 多宠互动「拥抱(Hug)」参照 Shimeji 的 ScanMove 行为重新实现(逻辑级,未拷贝源码):ScanMove 跑向广播 affordance 的邻居 → 到达触发配对
/// (self→Behavior、target→TargetBehavior)。Broadcast/Interact 走 Animate(affordance 由引擎从 leaf 读)。
@Suite("ShimejiScanMove / Hug 配对")
struct ShimejiHugTests {
    private func floorEnv(scanTarget: BehaviorPeer? = nil) -> BehaviorEnvironment {
        var e = BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
            activeWindow: .invisible,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080))
        e.scanTarget = scanTarget
        return e
    }

    private func ctx(anchor: BehaviorPoint, env: BehaviorEnvironment) -> ShimejiTickContext {
        ShimejiTickContext(state: ShimejiMascotState(anchor: anchor, lookRight: false),
                           engine: ShimejiScriptEngine(), environment: env, rng: ShimejiRandom(seed: 1))
    }

    /// RunAffordance(ScanMove,Affordance="Hug")—— run 帧 Velocity=-18(原图朝左约定:朝右走时 +18)。
    private func scanMoveDef() -> ShimejiActionDefinition {
        ShimejiActionDefinition(
            name: "RunAffordance",
            type: .embedded(className: "com.group_finity.mascot.action.ScanMove"),
            borderType: .floor,
            params: ["Affordance": "Hug", "Behavior": "HuggingSolid", "TargetBehavior": "HuggedSolid"],
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "run.png", imageAnchorX: 64, imageAnchorY: 128, velocityX: -18, durationTicks: 2)])])
    }

    @Test("factory: ScanMove → ShimejiScanMoveRuntime(不再降级 Animate)")
    func factoryMapsScanMove() {
        let factory = ShimejiActionRuntimeFactory(library: ShimejiActionLibrary(actions: [:]))
        #expect(factory.makeRuntime(for: scanMoveDef()) is ShimejiScanMoveRuntime)
    }

    @Test("ScanMove 跑向 scanTarget,到达 → pendingInteraction(self/target/targetID + 吸附到目标 x)")
    func scanMoveReachesAndPairs() throws {
        let target = BehaviorPeer(id: "B", anchor: BehaviorPoint(x: 600, y: 1040), affordance: "Hug")
        let c = ctx(anchor: BehaviorPoint(x: 200, y: 1040), env: floorEnv(scanTarget: target))
        let rt = ShimejiScanMoveRuntime(definition: scanMoveDef())
        rt.start(c)
        for _ in 0..<80 {
            guard rt.hasNext(c) else { break }
            try rt.next(c)
            c.state.time += 1
            if c.pendingInteraction != nil { break }
        }
        let pi = try #require(c.pendingInteraction)
        #expect(pi.selfBehavior == "HuggingSolid")
        #expect(pi.targetBehavior == "HuggedSolid")
        #expect(pi.targetID == "B")
        #expect(Int(c.state.anchor.x.rounded()) == 600)   // 吸附到目标
        #expect(c.state.lookRight == true)                // 朝目标(右)
    }

    @Test("ScanMove affordance 不匹配 scanTarget → 无目标 → hasNext false(空转即止,不瞎跑)")
    func scanMoveMismatchIdle() {
        let mismatch = BehaviorPeer(id: "B", anchor: BehaviorPoint(x: 600, y: 1040), affordance: "Pinch")
        let c = ctx(anchor: BehaviorPoint(x: 200, y: 1040), env: floorEnv(scanTarget: mismatch))
        let rt = ShimejiScanMoveRuntime(definition: scanMoveDef())
        rt.start(c)
        #expect(rt.hasNext(c) == false)
    }

    @Test("ScanMove 无 scanTarget(单宠)→ hasNext false")
    func scanMoveNoTargetIdle() {
        let c = ctx(anchor: BehaviorPoint(x: 200, y: 1040), env: floorEnv(scanTarget: nil))
        let rt = ShimejiScanMoveRuntime(definition: scanMoveDef())
        rt.start(c)
        #expect(rt.hasNext(c) == false)
    }

    @Test("引擎 offeredAffordance/seekingAffordance:广播者报 Hug,扫描者报 seeking")
    @MainActor
    func engineReportsAffordances() {
        // 广播包:StandAffordance(Broadcast,Affordance="Hug")唯一顶层行为。
        let stand = ShimejiActionDefinition(
            name: "StandAffordance", type: .embedded(className: "com.group_finity.mascot.action.Broadcast"),
            borderType: .floor, params: ["Affordance": "Hug", "Duration": "250"],
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "stand.png", imageAnchorX: 64, imageAnchorY: 128, durationTicks: 250)])])
        let offerLib = ShimejiActionLibrary(actions: ["StandAffordance": stand])
        let offerGraph = ShimejiBehaviorGraph(
            behaviors: ["Offer": ShimejiBehavior(name: "Offer", actionName: "StandAffordance",
                                                 frequency: 100, hidden: false, conditions: [],
                                                 nextAdditive: true, nextBehaviors: [])],
            topLevelOrder: ["Offer"])
        let env = floorEnv()
        let offerEngine = ShimejiMascotEngine(graph: offerGraph, library: offerLib,
                                              anchor: BehaviorPoint(x: 300, y: 1040), environment: env)
        _ = offerEngine.tick(environment: env)
        #expect(offerEngine.offeredAffordance == "Hug")     // 广播 Hug
        #expect(offerEngine.seekingAffordance == nil)

        // 扫描包:RunAffordance(ScanMove)唯一顶层行为,有 scanTarget。
        let scanLib = ShimejiActionLibrary(actions: ["RunAffordance": scanMoveDef()])
        let scanGraph = ShimejiBehaviorGraph(
            behaviors: ["Seek": ShimejiBehavior(name: "Seek", actionName: "RunAffordance",
                                                frequency: 100, hidden: false, conditions: [],
                                                nextAdditive: true, nextBehaviors: [])],
            topLevelOrder: ["Seek"])
        var scanEnv = floorEnv(scanTarget: BehaviorPeer(id: "B", anchor: BehaviorPoint(x: 900, y: 1040), affordance: "Hug"))
        let scanEngine = ShimejiMascotEngine(graph: scanGraph, library: scanLib,
                                             anchor: BehaviorPoint(x: 300, y: 1040), environment: scanEnv)
        _ = scanEngine.tick(environment: scanEnv)
        #expect(scanEngine.seekingAffordance == "Hug")      // 扫描态报 seeking,不广播
        #expect(scanEngine.offeredAffordance == nil)
    }
}
