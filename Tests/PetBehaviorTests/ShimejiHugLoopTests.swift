import Foundation
import Testing
import PetBehavior

/// 端到端「拥抱」回路证明:真实包结构(`HugAffordance=Sequence[Look, StandAffordance(Broadcast)]`、
/// `HugSearch=Sequence[Stand, RunAffordance(ScanMove)]`、`HuggingSolid/HuggedSolid=Sequence[Look, Interact]`)
/// 两个独立引擎经 host 桥接(广播者 `offeredAffordance` → 扫描者 `env.scanTarget`;扫描者到达产配对 →
/// 切目标 `TargetBehavior`)跑完整握抱。
///
/// 存在意义:之前 `ShimejiHugTests` 只测裸 ScanMove 与裸 Broadcast 动作,**没测 Sequence 包裹**
/// (真实包都是 Sequence,首子动作是 instant `Look`)。本套补上,证明
/// 「Sequence 首子是 instant Look 时 seek 能跳到 StandAffordance 并广播」+ 跨引擎配对落地。
@MainActor
@Suite("Hug 端到端回路(双引擎桥接)")
struct ShimejiHugLoopTests {

    private static let floorY: Double = 1040

    private func floorEnv() -> BehaviorEnvironment {
        BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: Self.floorY),
            activeWindow: .invisible,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080))
    }

    // MARK: - 真实包结构的最小复刻

    private func pose(_ image: String, vx: Double = 0, dur: Int = 1) -> ShimejiPose {
        ShimejiPose(image: image, imageAnchorX: 64, imageAnchorY: 128, velocityX: vx, durationTicks: dur)
    }

    private func anim(_ poses: ShimejiPose...) -> ShimejiAnimation {
        ShimejiAnimation(condition: nil, poses: poses)
    }

    /// 叶子动作 + Sequence 行为动作的全集(键 = 动作名,Sequence 经 ActionReference 引用叶子)。
    private func hugLibrary() -> ShimejiActionLibrary {
        let look = ShimejiActionDefinition(
            name: "Look", type: .embedded(className: "com.group_finity.mascot.action.Look"),
            params: ["LookRight": "false"], animations: [])
        let stand = ShimejiActionDefinition(
            name: "Stand", type: .stay, borderType: .floor,
            animations: [anim(pose("stand.png", dur: 2))])
        let standAffordance = ShimejiActionDefinition(
            name: "StandAffordance", type: .embedded(className: "com.group_finity.mascot.action.Broadcast"),
            borderType: .floor, params: ["Affordance": "Hug"],
            animations: [anim(pose("stand.png", dur: 250))])
        let runAffordance = ShimejiActionDefinition(
            name: "RunAffordance", type: .embedded(className: "com.group_finity.mascot.action.ScanMove"),
            borderType: .floor,
            params: ["Affordance": "Hug", "Behavior": "HuggingSolid", "TargetBehavior": "HuggedSolid"],
            animations: [anim(pose("run.png", vx: -18, dur: 2))])
        let huggingAction = ShimejiActionDefinition(
            name: "HuggingSolidAction", type: .embedded(className: "com.group_finity.mascot.action.Interact"),
            borderType: .floor, animations: [anim(pose("hugging01.png", dur: 60))])
        let huggedAction = ShimejiActionDefinition(
            name: "HuggedSolidAction", type: .embedded(className: "com.group_finity.mascot.action.Interact"),
            borderType: .floor, animations: [anim(pose("hugged01.png", dur: 60))])

        func seq(_ name: String, _ refs: ShimejiActionReference...) -> ShimejiActionDefinition {
            ShimejiActionDefinition(name: name, type: .sequence, children: refs.map { .reference($0) })
        }
        let hugAffordance = seq("HugAffordance",
            ShimejiActionReference(name: "Look", paramOverrides: ["LookRight": "false"]),
            ShimejiActionReference(name: "StandAffordance"))
        let hugSearch = seq("HugSearch",
            ShimejiActionReference(name: "Stand", paramOverrides: ["Duration": "3"]),   // 真实包是 ${20+rand*20}
            ShimejiActionReference(name: "RunAffordance"))
        let huggingSolid = seq("HuggingSolid",
            ShimejiActionReference(name: "Look", paramOverrides: ["LookRight": "true"]),
            ShimejiActionReference(name: "HuggingSolidAction"))
        let huggedSolid = seq("HuggedSolid",
            ShimejiActionReference(name: "Look", paramOverrides: ["LookRight": "false"]),
            ShimejiActionReference(name: "HuggedSolidAction"))

        return ShimejiActionLibrary(actions: [
            "Look": look, "Stand": stand, "StandAffordance": standAffordance, "RunAffordance": runAffordance,
            "HuggingSolidAction": huggingAction, "HuggedSolidAction": huggedAction,
            "HugAffordance": hugAffordance, "HugSearch": hugSearch,
            "HuggingSolid": huggingSolid, "HuggedSolid": huggedSolid,
        ])
    }

    private func hugGraph() -> ShimejiBehaviorGraph {
        func b(_ name: String, freq: Int, hidden: Bool) -> ShimejiBehavior {
            ShimejiBehavior(name: name, actionName: name, frequency: freq, hidden: hidden,
                            conditions: [], nextAdditive: true, nextBehaviors: [])
        }
        return ShimejiBehaviorGraph(behaviors: [
            "HugAffordance": b("HugAffordance", freq: 120, hidden: false),
            "HugSearch": b("HugSearch", freq: 1000, hidden: false),
            "HuggingSolid": b("HuggingSolid", freq: 0, hidden: true),
            "HuggedSolid": b("HuggedSolid", freq: 0, hidden: true),
        ], topLevelOrder: ["HugAffordance", "HugSearch"])
    }

    private func engine(at x: Double, seed: UInt64) -> ShimejiMascotEngine {
        ShimejiMascotEngine(graph: hugGraph(), library: hugLibrary(),
                            anchor: BehaviorPoint(x: x, y: Self.floorY), environment: floorEnv(), seed: seed)
    }

    // MARK: - 测试

    /// 关键缺口:`HugAffordance` 是 `Sequence[Look(instant), StandAffordance(Broadcast)]`。
    /// 证明 seek 能跨过 instant 首子 `Look` 落到 `StandAffordance`,引擎首拍即广播 `off=Hug`。
    /// (live 实测「off=Hug 从不出现」的根因排查:此处证明**被选中时**广播链是好的,从不出现 = 极少被选中。)
    @Test("Sequence[Look, StandAffordance] 被选中 → 首拍即广播 Hug(seek 跨过 instant Look)")
    func sequenceWrappedBroadcastOffersHug() {
        let e = engine(at: 600, seed: 1)
        e.triggerBehavior(named: "HugAffordance")
        _ = e.tick(environment: floorEnv())
        #expect(e.behaviorName == "HugAffordance")
        #expect(e.offeredAffordance == "Hug")     // 广播者真的在广播
        #expect(e.seekingAffordance == nil)
        // 持续广播(StandAffordance Duration=250):跑 50 拍仍 Hug。
        for _ in 0..<50 { _ = e.tick(environment: floorEnv()) }
        #expect(e.offeredAffordance == "Hug")
    }

    /// 端到端:A 广播 Hug、B 扫描 → host 桥接 → B 跑向 A 到达 → 配对:B→HuggingSolid、A→HuggedSolid。
    /// 这是 live 桌面双宠**条件齐备时**应发生的完整握抱;证明回路本身正确(从不发生 = 触发条件极罕见,非链路坏)。
    @Test("双引擎桥接:A 广播 + B 扫描 → 跑近 → 配对(B=HuggingSolid, A=HuggedSolid)")
    func twoEngineHugLoopPairs() {
        let a = engine(at: 600, seed: 1)     // 广播者
        let b = engine(at: 400, seed: 2)     // 扫描者(在 A 左侧 200px,同地面)
        a.triggerBehavior(named: "HugAffordance")
        b.triggerBehavior(named: "HugSearch")

        var paired = false
        for _ in 0..<200 {
            // host 桥接:把 A 的广播喂给 B 的 scanTarget(就近匹配,同 live scanTarget())。
            var envB = floorEnv()
            if let aff = a.offeredAffordance {
                envB.scanTarget = BehaviorPeer(id: "A", anchor: a.anchor, affordance: aff)
            }
            _ = a.tick(environment: floorEnv())
            _ = b.tick(environment: envB)
            // host 落地 B 产出的配对 → 切 A 到 TargetBehavior。
            if let pairing = b.consumeOutgoingPairing() {
                #expect(pairing.targetID == "A")
                #expect(pairing.behavior == "HuggedSolid")
                a.triggerBehavior(named: pairing.behavior)
                paired = true
            }
            if b.behaviorName == "HuggingSolid", a.behaviorName == "HuggedSolid" { break }
        }
        #expect(paired)                                 // 配对触发了
        #expect(b.behaviorName == "HuggingSolid")       // 扫描者进入「抱」
        #expect(a.behaviorName == "HuggedSolid")        // 广播者被切到「被抱」
        // 二者最终吸附到同一 x(到达即 snap 到目标 x)。
        #expect(Int(a.anchor.x.rounded()) == Int(b.anchor.x.rounded()))
    }
}
