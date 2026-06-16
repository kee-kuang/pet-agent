import Foundation
import Testing
import PetBehavior

/// Runtime 级外科测试:边界绑定/跟随/失地、Move 朝向+吸附+pose 翻转、Sequence/Select 推进、
/// Fall 物理落地、Instant(Look/Offset)。直接构造 ShimejiTickContext,逐 tick 驱动。
@Suite("ShimejiActionRuntime(外科)")
struct ShimejiActionRuntimeTests {
    // workArea [0,0,1920,1040](地面 y=1040),活动窗 [500,300,900,700](窗顶 y=300)。
    private func env(
        window: BehaviorArea = BehaviorArea(left: 500, top: 300, right: 900, bottom: 700),
        cursor: BehaviorCursor = BehaviorCursor()
    ) -> BehaviorEnvironment {
        BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
            activeWindow: window,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080),
            cursor: cursor
        )
    }

    private func makeContext(anchor: BehaviorPoint, env environment: BehaviorEnvironment) -> ShimejiTickContext {
        ShimejiTickContext(
            state: ShimejiMascotState(anchor: anchor),
            engine: ShimejiScriptEngine(),
            environment: environment,
            rng: ShimejiRandom(seed: 1)
        )
    }

    /// 驱动 runtime n tick(模拟引擎主循环:hasNext → next → time++)。返回实际跑的 tick 数。
    @discardableResult
    private func run(
        _ runtime: ShimejiActionRuntime,
        _ ctx: ShimejiTickContext,
        maxTicks: Int
    ) throws -> Int {
        var ran = 0
        for _ in 0..<maxTicks {
            guard runtime.hasNext(ctx) else { break }
            try runtime.next(ctx)
            ctx.state.time += 1
            ran += 1
        }
        return ran
    }

    private func stayDef(border: ShimejiBorderType, duration: String? = nil) -> ShimejiActionDefinition {
        ShimejiActionDefinition(
            name: "Stand", type: .stay, borderType: border,
            params: duration.map { ["Duration": $0] } ?? [:],
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "stand.png", imageAnchorX: 64, imageAnchorY: 128, durationTicks: 10),
            ])]
        )
    }

    @Test("Stay 站窗顶:窗口平移 → anchor 跟随(border.move)")
    func stayFollowsWindowMove() throws {
        let ctx = makeContext(anchor: BehaviorPoint(x: 700, y: 300), env: env())
        let stay = ShimejiStayRuntime(definition: stayDef(border: .floor, duration: "50"))
        stay.start(ctx)
        try run(stay, ctx, maxTicks: 3)
        #expect(ctx.state.anchor == BehaviorPoint(x: 700, y: 300))   // 窗没动

        // 窗口右移 10px
        ctx.previousEnvironment = ctx.environment
        ctx.environment = env(window: BehaviorArea(left: 510, top: 300, right: 910, bottom: 700))
        #expect(stay.hasNext(ctx))
        try stay.next(ctx)
        #expect(ctx.state.anchor.x == 710)   // (700-500)*400/400+510
        #expect(ctx.state.anchor.y == 300)
    }

    @Test("Stay 站窗顶:窗口消失 → lostGround")
    func stayLosesGroundWhenWindowVanishes() throws {
        let ctx = makeContext(anchor: BehaviorPoint(x: 700, y: 300), env: env())
        let stay = ShimejiStayRuntime(definition: stayDef(border: .floor, duration: "50"))
        stay.start(ctx)
        try run(stay, ctx, maxTicks: 2)

        ctx.previousEnvironment = ctx.environment
        ctx.environment = env(window: .invisible)
        #expect(throws: ShimejiActionInterruption.self) {
            try stay.next(ctx)
        }
    }

    @Test("Move 向右目标:自动朝右 + pose 速度翻转 + 越过吸附 + 到达即止")
    func moveToTargetRight() throws {
        let walkDef = ShimejiActionDefinition(
            name: "Walk", type: .move, borderType: .floor,
            params: ["TargetX": "1005"],   // 起点 960,速度 2/tick → 22 tick 到 1004,吸附 1005
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "walk1.png", velocityX: -2, durationTicks: 2),
                ShimejiPose(image: "walk2.png", velocityX: -2, durationTicks: 2),
            ])]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 960, y: 1040), env: env())
        let move = ShimejiMoveRuntime(definition: walkDef)
        move.start(ctx)
        let ran = try run(move, ctx, maxTicks: 100)
        #expect(ctx.state.lookRight == true)              // 目标在右 → 朝右
        #expect(ctx.state.anchor.x == 1005)               // 吸附到目标
        #expect(ctx.state.anchor.y == 1040)               // 沿地面
        #expect(ran < 100)                                 // 到达终止,非耗尽
        #expect(move.hasNext(ctx) == false)
        #expect(ctx.currentPose?.image?.hasPrefix("walk") == true)
    }

    @Test("Move 向左目标:朝左 + 原速直用")
    func moveToTargetLeft() throws {
        let walkDef = ShimejiActionDefinition(
            name: "Walk", type: .move, borderType: .floor,
            params: ["TargetX": "900"],
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "walk1.png", velocityX: -2, durationTicks: 2),
            ])]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 960, y: 1040), env: env())
        let move = ShimejiMoveRuntime(definition: walkDef)
        move.start(ctx)
        try run(move, ctx, maxTicks: 100)
        #expect(ctx.state.lookRight == false)
        #expect(ctx.state.anchor.x == 900)
    }

    @Test("Fall 物理:半空起落到地面,速度受重力+阻力")
    func fallLandsOnGround() throws {
        let fallDef = ShimejiActionDefinition(
            name: "Falling", type: .embedded(className: "com.group_finity.mascot.action.Fall"),
            animations: [ShimejiAnimation(condition: nil, poses: [
                ShimejiPose(image: "fall.png", durationTicks: 4),
            ])]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 200, y: 500), env: env())
        let fall = ShimejiFallRuntime(definition: fallDef)
        fall.start(ctx)
        let ran = try run(fall, ctx, maxTicks: 200)
        #expect(Int(ctx.state.anchor.y.rounded()) == 1040)   // 精确落在地面
        #expect(ran > 5 && ran < 100)                         // 有下落过程,非瞬移
        #expect(fall.hasNext(ctx) == false)
    }

    @Test("Fall 带 InitialVX(Thrown 语义):横向漂移 + 朝向跟速度")
    func fallWithInitialVelocityDrifts() throws {
        let fallDef = ShimejiActionDefinition(
            name: "Falling", type: .embedded(className: "Fall"),
            params: ["InitialVX": "15"],
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "fall.png", durationTicks: 4)])]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 400, y: 800), env: env())
        let fall = ShimejiFallRuntime(definition: fallDef)
        fall.start(ctx)
        try run(fall, ctx, maxTicks: 200)
        #expect(ctx.state.anchor.x > 450)                     // 右漂
        #expect(ctx.state.lookRight == true)                  // 朝速度方向
        #expect(Int(ctx.state.anchor.y.rounded()) == 1040)
    }

    @Test("Sequence:子动作顺序推进 + Loop 回绕")
    func sequenceAdvancesAndLoops() throws {
        let blink = ShimejiActionDefinition(
            name: "", type: .animate,
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "a.png", durationTicks: 2)])]
        )
        let nod = ShimejiActionDefinition(
            name: "", type: .animate,
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "b.png", durationTicks: 3)])]
        )
        let factory = ShimejiActionRuntimeFactory(library: ShimejiActionLibrary(actions: [:]))

        // 非 Loop:2+3 tick 跑完即止
        let seq = ShimejiSequenceRuntime(
            definition: ShimejiActionDefinition(name: "S", type: .sequence),
            children: [factory.makeRuntime(for: blink, depth: 1), factory.makeRuntime(for: nod, depth: 1)]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        seq.start(ctx)
        var images: [String] = []
        for _ in 0..<20 {
            guard seq.hasNext(ctx) else { break }
            try seq.next(ctx)
            ctx.state.time += 1
            if let img = ctx.currentPose?.image { images.append(img) }
        }
        #expect(images == ["a.png", "a.png", "b.png", "b.png", "b.png"])
        #expect(seq.hasNext(ctx) == false)

        // Loop:外层 Duration 终止前一直回绕
        let loop = ShimejiSequenceRuntime(
            definition: ShimejiActionDefinition(name: "L", type: .sequence, params: ["Loop": "true", "Duration": "12"]),
            children: [factory.makeRuntime(for: blink, depth: 1), factory.makeRuntime(for: nod, depth: 1)]
        )
        let ctx2 = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        loop.start(ctx2)
        var count = 0
        for _ in 0..<40 {
            guard loop.hasNext(ctx2) else { break }
            try loop.next(ctx2)
            ctx2.state.time += 1
            count += 1
        }
        #expect(count == 12)   // 被外层 Duration 收口,期间 2+3 循环回绕
    }

    @Test("Select:按子动作 Condition 选首个可跑分支并锁定")
    func selectPicksFirstViableBranch() throws {
        let onFloorBranch = ShimejiActionDefinition(
            name: "", type: .animate, params: ["Condition": "#{mascot.environment.floor.isOn(mascot.anchor)}"],
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "land.png", durationTicks: 3)])]
        )
        let fallbackBranch = ShimejiActionDefinition(
            name: "", type: .animate,
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "grab.png", durationTicks: 3)])]
        )
        let factory = ShimejiActionRuntimeFactory(library: ShimejiActionLibrary(actions: [:]))

        // 在地面:engine sync 后 floor.isOn = true → 选第一分支
        let ctxFloor = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        ctxFloor.engine.sync(mascot: BehaviorMascot(
            anchor: ctxFloor.state.anchor, lookRight: false, totalCount: 1, environment: ctxFloor.environment
        ))
        let selFloor = ShimejiSelectRuntime(
            definition: ShimejiActionDefinition(name: "Sel", type: .select),
            children: [factory.makeRuntime(for: onFloorBranch, depth: 1), factory.makeRuntime(for: fallbackBranch, depth: 1)]
        )
        selFloor.start(ctxFloor)
        try selFloor.next(ctxFloor)
        #expect(ctxFloor.currentPose?.image == "land.png")

        // 半空:第一分支条件 false → 选第二分支
        let ctxAir = makeContext(anchor: BehaviorPoint(x: 100, y: 500), env: env())
        ctxAir.engine.sync(mascot: BehaviorMascot(
            anchor: ctxAir.state.anchor, lookRight: false, totalCount: 1, environment: ctxAir.environment
        ))
        let selAir = ShimejiSelectRuntime(
            definition: ShimejiActionDefinition(name: "Sel", type: .select),
            children: [factory.makeRuntime(for: onFloorBranch, depth: 1), factory.makeRuntime(for: fallbackBranch, depth: 1)]
        )
        selAir.start(ctxAir)
        try selAir.next(ctxAir)
        #expect(ctxAir.currentPose?.image == "grab.png")
    }

    @Test("地面动作在半空被选中 → 立即 LostGround(真实包验出:Trip 半空不卡桩)")
    func borderedActionMidAirLosesGround() {
        // BorderType=Floor 的 Stay,起点在半空(y=500,非地面 1040)→ start 解析不到 floor 边 →
        // 首 tick ensureOnBorder 抛 lostGround(对齐 Shimeji NotOnBorder 语义)。
        let ctx = makeContext(anchor: BehaviorPoint(x: 960, y: 500), env: env())
        let stay = ShimejiStayRuntime(definition: stayDef(border: .floor, duration: "250"))
        stay.start(ctx)
        #expect(throws: ShimejiActionInterruption.self) {
            try stay.next(ctx)
        }
    }

    @Test("静态 \\${} 参数只求值一次(摆头回归):Walk 目标固定,不追移动目标")
    func staticParamEvaluatedOnce() throws {
        // TargetX 引用 anchor.x(出发 100)→ 静态缓存 = 200。若每 tick 重求值(动态)则目标随
        // anchor 后退、lookRight 反复翻(摆头)、永不到达。静态缓存 → 锁 200 → 走到即停。
        let walkDef = ShimejiActionDefinition(
            name: "Walk", type: .move, borderType: .floor,
            params: ["TargetX": "${mascot.anchor.x + 100}"],
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "w.png", velocityX: -4, durationTicks: 2)])])
        let ctx = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        let move = ShimejiMoveRuntime(definition: walkDef)
        move.start(ctx)
        var ran = 0
        for _ in 0..<200 {
            // 每 tick 重 sync(模拟引擎)—— 动态会看到 anchor 变化;静态 TargetX 仍锁首值
            ctx.engine.sync(mascot: BehaviorMascot(
                anchor: ctx.state.anchor, lookRight: ctx.state.lookRight, totalCount: 1, environment: ctx.environment))
            guard move.hasNext(ctx) else { break }
            try move.next(ctx)
            ctx.state.time += 1
            ran += 1
        }
        #expect(ctx.state.anchor.x == 200)   // 到达固定目标(静态缓存生效)
        #expect(ran < 200)                    // 没耗尽 = 到达终止(动态会永不到达)
    }

    @Test("动作参数喂进脚本上下文(爬墙卡死回归):动画 Condition 能读 TargetY 等参数")
    func actionParamsBoundToScript() throws {
        // ClimbWall 的动画 Condition 是 `#{TargetY < mascot.anchor.y}` —— 引用动作参数。
        // 不绑则 JS 里参数未定义 → 两分支条件都 false → 选不出动画 → currentPose 不更新 → 卡死。
        let def = ShimejiActionDefinition(
            name: "ClimbLike", type: .animate,
            params: ["TargetY": "600"],
            animations: [
                ShimejiAnimation(condition: "#{TargetY < mascot.anchor.y}", poses: [ShimejiPose(image: "up.png", durationTicks: 5)]),
                ShimejiAnimation(condition: "#{TargetY >= mascot.anchor.y}", poses: [ShimejiPose(image: "down.png", durationTicks: 5)]),
            ])
        // anchor.y=1040 > TargetY=600 → 第一分支(向上爬)成立
        let ctx = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        ctx.engine.sync(mascot: BehaviorMascot(   // 条件引用 mascot.anchor.y,需先绑 mascot
            anchor: ctx.state.anchor, lookRight: false, totalCount: 1, environment: ctx.environment))
        let anim = ShimejiAnimateRuntime(definition: def)
        anim.start(ctx)
        try anim.next(ctx)
        #expect(ctx.currentPose?.image == "up.png")   // 参数绑定生效 → 动画选出 → 不卡死
    }

    @Test("无 BorderType 的动作在半空正常播(不误抛 LostGround)")
    func borderlessActionMidAirRunsNormally() throws {
        let def = ShimejiActionDefinition(
            name: "FloatAnim", type: .animate,   // 无 borderType
            animations: [ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "f.png", durationTicks: 5)])])
        let ctx = makeContext(anchor: BehaviorPoint(x: 960, y: 500), env: env())
        let anim = ShimejiAnimateRuntime(definition: def)
        anim.start(ctx)
        try anim.next(ctx)   // 不抛
        #expect(ctx.currentPose?.image == "f.png")
    }

    @Test("Move 转向兜底(F-1 回归):turn 分支条件不成立 → 退普通态继续走,不卡死")
    func moveTurningFallbackWhenTurnBranchGated() throws {
        // turn 动画带恒 false 条件;起点在目标右侧且初始朝右 → 首 tick 需转向 → turn 分支不可用。
        let walkDef = ShimejiActionDefinition(
            name: "Walk", type: .move, borderType: .floor,
            params: ["TargetX": "900"],
            animations: [
                ShimejiAnimation(condition: nil, poses: [ShimejiPose(image: "walk1.png", velocityX: -2, durationTicks: 2)]),
                ShimejiAnimation(condition: "#{false}", isTurn: true, poses: [ShimejiPose(image: "turn.png", durationTicks: 4)]),
            ]
        )
        let ctx = makeContext(anchor: BehaviorPoint(x: 960, y: 1040), env: env())
        ctx.state.lookRight = true   // 初始朝右,目标在左 → 触发转向
        let move = ShimejiMoveRuntime(definition: walkDef)
        move.start(ctx)
        let ran = try run(move, ctx, maxTicks: 200)
        #expect(ctx.state.anchor.x == 900)    // 走到目标(没卡死站桩)
        #expect(ran < 200)                     // 到达终止,非耗尽
        #expect(move.hasNext(ctx) == false)
    }

    @Test("Look/Offset 即时动作:start 当帧生效,hasNext 恒 false")
    func instantActions() {
        let ctx = makeContext(anchor: BehaviorPoint(x: 100, y: 1040), env: env())
        let look = ShimejiLookRuntime(definition: ShimejiActionDefinition(
            name: "Look", type: .embedded(className: "Look"), params: ["LookRight": "true"]
        ))
        look.start(ctx)
        #expect(ctx.state.lookRight == true)
        #expect(look.hasNext(ctx) == false)

        let offset = ShimejiOffsetRuntime(definition: ShimejiActionDefinition(
            name: "Offset", type: .embedded(className: "Offset"), params: ["X": "-1", "Y": "2"]
        ))
        offset.start(ctx)
        #expect(ctx.state.anchor == BehaviorPoint(x: 99, y: 1042))
        #expect(offset.hasNext(ctx) == false)
    }
}
