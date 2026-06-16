import Foundation
import Testing
import PetBehavior

/// 引擎级端到端叙事:完整 conf(解析而来)驱动 ShimejiMascotEngine —— 半空出生 → Fall 兜底
/// → 物理落地 → Select 落地分支反弹 → 行为图选 Walk → 走向目标;拖拽 hijack → 跟光标 →
/// 甩出 → 带光标速度落地。全程确定性(种子 RNG)。
@MainActor
@Suite("ShimejiMascotEngine(端到端)")
struct ShimejiMascotEngineTests {
    static let actionsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <ActionList>
            <Action Name="Stand" Type="Stay" BorderType="Floor">
                <Animation><Pose Image="/stand.png" ImageAnchor="64,128" Velocity="0,0" Duration="10" /></Animation>
            </Action>
            <Action Name="Walk" Type="Move" BorderType="Floor">
                <Animation>
                    <Pose Image="/walk1.png" ImageAnchor="64,128" Velocity="-2,0" Duration="2" />
                    <Pose Image="/walk2.png" ImageAnchor="64,128" Velocity="-2,0" Duration="2" />
                </Animation>
            </Action>
            <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall">
                <Animation><Pose Image="/fall.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" /></Animation>
            </Action>
            <Action Name="Bouncing" Type="Animate" BorderType="Floor">
                <Animation>
                    <Pose Image="/bounce1.png" ImageAnchor="64,128" Velocity="0,0" Duration="2" />
                    <Pose Image="/bounce2.png" ImageAnchor="64,128" Velocity="0,0" Duration="2" />
                </Animation>
            </Action>
            <Action Name="GrabWall" Type="Stay" BorderType="Wall">
                <Animation><Pose Image="/grab.png" ImageAnchor="64,128" Velocity="0,0" Duration="10" /></Animation>
            </Action>
            <Action Name="Pinched" Type="Embedded" Class="com.group_finity.mascot.action.Dragged">
                <Animation><Pose Image="/pinch.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" /></Animation>
            </Action>
            <Action Name="Resisting" Type="Embedded" Class="com.group_finity.mascot.action.Regist">
                <Animation><Pose Image="/resist.png" ImageAnchor="64,128" Velocity="0,0" Duration="8" /></Animation>
            </Action>
        </ActionList>
        <ActionList>
            <Action Name="Fall" Type="Sequence" Loop="false">
                <ActionReference Name="Falling"/>
                <Action Type="Select">
                    <Action Type="Sequence" Condition="${mascot.environment.floor.isOn(mascot.anchor)}">
                        <ActionReference Name="Bouncing"/>
                        <ActionReference Name="Stand" Duration="5" />
                    </Action>
                    <ActionReference Name="GrabWall" Duration="5" />
                </Action>
            </Action>
            <Action Name="Dragged" Type="Sequence" Loop="true">
                <ActionReference Name="Pinched"/>
                <ActionReference Name="Resisting" />
            </Action>
            <Action Name="Thrown" Type="Sequence" Loop="false">
                <ActionReference Name="Falling" InitialVX="${mascot.environment.cursor.dx}" InitialVY="${mascot.environment.cursor.dy}"/>
                <Action Type="Select">
                    <Action Type="Sequence" Condition="${mascot.environment.floor.isOn(mascot.anchor)}">
                        <ActionReference Name="Bouncing"/>
                    </Action>
                    <ActionReference Name="GrabWall" Duration="5" />
                </Action>
            </Action>
            <Action Name="WalkRight" Type="Sequence" Loop="false">
                <ActionReference Name="Walk" TargetX="1400" />
            </Action>
        </ActionList>
    </Mascot>
    """

    static let behaviorsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <BehaviorList>
            <Behavior Name="Fall" Frequency="0" Hidden="true" />
            <Behavior Name="Dragged" Frequency="0" Hidden="true" />
            <Behavior Name="Thrown" Frequency="0" Hidden="true" />
            <Condition Condition="#{mascot.environment.floor.isOn(mascot.anchor)}">
                <Behavior Name="WalkRight" Frequency="100" />
            </Condition>
        </BehaviorList>
    </Mascot>
    """

    private func makeEngine(anchor: BehaviorPoint, env: BehaviorEnvironment) throws -> ShimejiMascotEngine {
        let library = try #require(ShimejiActionLibraryParser.parse(Data(Self.actionsXML.utf8)))
        let graph = try #require(ShimejiBehaviorParser.parse(Data(Self.behaviorsXML.utf8)))
        #expect(library.danglingReferences().isEmpty)
        #expect(graph.danglingReferences().isEmpty)
        return ShimejiMascotEngine(graph: graph, library: library, anchor: anchor, environment: env, seed: 7)
    }

    private func env(cursor: BehaviorCursor = BehaviorCursor()) -> BehaviorEnvironment {
        BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
            activeWindow: .invisible,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080),
            cursor: cursor
        )
    }

    @Test("叙事:半空出生 → Fall 落地 → 反弹 → 行为图选 WalkRight → 走到目标")
    func fallLandBounceWalk() throws {
        let engine = try makeEngine(anchor: BehaviorPoint(x: 700, y: 400), env: env())
        var landedTick: Int?
        var sawBounce = false
        var sawWalkBehavior = false
        var images: Set<String> = []

        for tick in 0..<400 {
            let frame = engine.tick(environment: env())
            if let img = frame.image { images.insert(img) }
            if landedTick == nil, Int(frame.anchor.y.rounded()) == 1040 { landedTick = tick }
            if frame.image?.hasPrefix("bounce") == true { sawBounce = true }
            if frame.behaviorName == "WalkRight" { sawWalkBehavior = true }
            if Int(frame.anchor.x.rounded()) == 1400 { break }   // 走到目标
        }

        #expect(landedTick != nil && landedTick! < 100)           // 物理下落落地
        #expect(sawBounce)                                         // 落地分支(Select 条件命中)
        #expect(sawWalkBehavior)                                   // 行为图按地面条件选中
        #expect(Int(engine.anchor.x.rounded()) == 1400)            // Move 吸附到目标
        #expect(Int(engine.anchor.y.rounded()) == 1040)
        #expect(engine.lookRight == true)                          // 目标在右
        #expect(images.contains("fall.png") && images.contains("walk1.png"))
    }

    @Test("hijack:拖拽跟光标(+默认 OffsetY 120) → 甩出带光标速度 → 落地")
    func dragThenThrow() throws {
        let engine = try makeEngine(anchor: BehaviorPoint(x: 700, y: 1040), env: env())
        for _ in 0..<5 { _ = engine.tick(environment: env()) }     // 先正常活动

        engine.pointerPressed()
        #expect(engine.behaviorName == "Dragged")
        #expect(engine.isDragging)

        // 拖到 (300, 200):anchor 应贴 (cursor.x, cursor.y+120)
        let dragEnv = env(cursor: BehaviorCursor(x: 300, y: 200))
        for _ in 0..<5 { _ = engine.tick(environment: dragEnv) }
        #expect(Int(engine.anchor.x.rounded()) == 300)
        #expect(Int(engine.anchor.y.rounded()) == 320)

        // 甩出:光标速度向右 → Thrown → Falling InitialVX=cursor.dx → 右漂落地
        let throwEnv = env(cursor: BehaviorCursor(x: 300, y: 200, dx: 18, dy: -6))
        _ = engine.tick(environment: throwEnv)                     // 让 sync 吃到光标速度
        engine.pointerReleased()
        #expect(engine.behaviorName == "Thrown")
        #expect(engine.isDragging == false)

        var maxX: Double = 300
        for _ in 0..<300 {
            let frame = engine.tick(environment: env(cursor: BehaviorCursor(x: 300, y: 200)))
            maxX = max(maxX, frame.anchor.x)
            if Int(frame.anchor.y.rounded()) == 1040, frame.behaviorName != "Thrown" { break }
        }
        #expect(maxX > 360)                                        // 横向动量可见
        #expect(Int(engine.anchor.y.rounded()) == 1040)            // 最终落地
    }

    @Test("左边界坠落不无限循环(实机真实包验出):x 夹进 workArea,落地不坠穿")
    func leftEdgeFallDoesNotLoop() throws {
        // 出生在 workArea 左外(x<0)半空 —— 此前 floor x-range 不含负 x → 永坠 → 出屏吸回 → 循环。
        let engine = try makeEngine(anchor: BehaviorPoint(x: -150, y: 300), env: env())
        var topResets = 0
        var lastY = 300.0
        var maxY = 300.0
        for _ in 0..<600 {
            let frame = engine.tick(environment: env())
            // x 恒被夹进 workArea [0,1920](根因:wallBorder 漏检对侧墙 → x 越界 → floor 不命中)
            #expect(frame.anchor.x >= 0 && frame.anchor.x <= 1920)
            // 「坠穿后被吸回屏顶」的循环特征:y 从大突降到小
            if lastY > 600 && frame.anchor.y < 100 { topResets += 1 }
            lastY = frame.anchor.y
            maxY = max(maxY, frame.anchor.y)
        }
        #expect(topResets == 0)                                  // 核心:不再无限吸回屏顶
        #expect(maxY <= 1040 + 256)                              // 未坠穿到出屏阈值(floor 恒在脚下接住)
        #expect(engine.anchor.y >= 0 && engine.anchor.y <= 1040) // 最终稳在屏内
    }

    @Test("出屏防护:anchor 远超屏幕 → 收回屏内 + 强制 Fall")
    func offscreenRecovery() throws {
        let engine = try makeEngine(anchor: BehaviorPoint(x: 5000, y: -2000), env: env())
        _ = engine.tick(environment: env())
        #expect(engine.anchor.x <= 1920 && engine.anchor.x >= 0)
        #expect(engine.behaviorName == "Fall")
        // 续跑落回地面
        for _ in 0..<200 {
            _ = engine.tick(environment: env())
            if Int(engine.anchor.y.rounded()) == 1040 { break }
        }
        #expect(Int(engine.anchor.y.rounded()) == 1040)
    }

    @Test("真实 DefaultMascot conf 驱动引擎 300 tick 不崩 + 落地 + 行为流转(无包则跳过)")
    func realConfSmoke() throws {
        // 真实 conf 目录由环境变量提供(公开仓库不内置任何绝对路径);未设或文件不存在 → 跳过。
        // 本地可:export VIVARIUM_TEST_MASCOT_DIR=<含 actions.xml/behaviors.xml 的 Shimeji 包目录>
        guard let base = ProcessInfo.processInfo.environment["VIVARIUM_TEST_MASCOT_DIR"] else { return }
        guard let actionsData = try? Data(contentsOf: URL(fileURLWithPath: base + "/actions.xml")),
              let behaviorsData = try? Data(contentsOf: URL(fileURLWithPath: base + "/behaviors.xml"))
        else { return }   // 参考目录不在(他机/CI)→ 跳过

        let library = try #require(ShimejiActionLibraryParser.parse(actionsData))
        let graph = try #require(ShimejiBehaviorParser.parse(behaviorsData))
        let engine = ShimejiMascotEngine(
            graph: graph, library: library,
            anchor: BehaviorPoint(x: 960, y: 300), environment: env(), seed: 99
        )
        var behaviors: Set<String> = []
        var landed = false
        for _ in 0..<300 {
            let frame = engine.tick(environment: env())
            if let b = frame.behaviorName { behaviors.insert(b) }
            if Int(frame.anchor.y.rounded()) == 1040 { landed = true }
        }
        #expect(landed)                                            // 真实 conf 的 Fall 也能落地
        #expect(behaviors.count >= 2)                              // 行为有流转(非卡死单行为)
        #expect(behaviors.contains("Fall"))
        // 视野内(出屏防护没把它丢出去)
        #expect(engine.anchor.x >= 0 && engine.anchor.x <= 1920)
    }
}
