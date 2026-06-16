import Foundation
import Testing
import PetBehavior

/// 覆盖 actions.xml 全保真解析:叶子动作(pose 字段/边界/参数脚本)、多 Animation Condition 分支、
/// IsTurn、Sequence/Select(引用参数覆盖 + 匿名内联混排)、Embedded、多 ActionList 合并、
/// 悬空引用、pose 取模推进。fixture 仿真实 DefaultMascot 结构。
@Suite("ShimejiActionLibraryParser")
struct ShimejiActionLibraryParserTests {
    static let fixture = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <ActionList>
            <Action Name="Look" Type="Embedded" Class="com.group_finity.mascot.action.Look" />
            <Action Name="Stand" Type="Stay" BorderType="Floor">
                <Animation>
                    <Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
                </Animation>
            </Action>
            <Action Name="Walk" Type="Move" BorderType="Floor">
                <Animation>
                    <Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="-2,0" Duration="6" />
                    <Pose Image="/shime2.png" ImageAnchor="64,128" Velocity="-2,0" Duration="6" />
                    <Pose Image="/shime3.png" ImageAnchor="64,128" Velocity="-2,0" Duration="4" />
                </Animation>
                <Animation IsTurn="true">
                    <Pose Image="/shime4.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" />
                </Animation>
            </Action>
            <Action Name="SitAndLookAtMouse" Type="Stay" BorderType="Floor">
                <Animation Condition="#{mascot.environment.cursor.y &lt; mascot.environment.screen.height/2}">
                    <Pose Image="/shime26.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
                </Animation>
                <Animation>
                    <Pose Image="/shime11.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
                </Animation>
            </Action>
            <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall"
                    InitialVX="0" InitialVY="0">
                <Animation>
                    <Pose Image="/shime4.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" />
                </Animation>
            </Action>
            <Action Name="Bouncing" Type="Animate" BorderType="Floor">
                <Animation>
                    <Pose Image="/shime18.png" ImageAnchor="64,128" Velocity="0,0" Duration="2" />
                    <Pose Image="/shime19.png" ImageAnchor="64,128" Velocity="0,0" Duration="2" />
                </Animation>
            </Action>
            <Action Name="GrabWall" Type="Stay" BorderType="Wall">
                <Animation>
                    <Pose Image="/shime13.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
                </Animation>
            </Action>
        </ActionList>
        <ActionList>
            <Action Name="Fall" Type="Sequence" Loop="false">
                <ActionReference Name="Falling"/>
                <Action Type="Select">
                    <Action Type="Sequence" Condition="${mascot.environment.floor.isOn(mascot.anchor)}">
                        <ActionReference Name="Bouncing"/>
                        <ActionReference Name="Stand" Duration="${100+Math.random()*100}" />
                    </Action>
                    <ActionReference Name="GrabWall" Duration="100" />
                </Action>
            </Action>
            <Action Name="Thrown" Type="Sequence" Loop="false">
                <ActionReference Name="Falling" InitialVX="${mascot.environment.cursor.dx}" InitialVY="${mascot.environment.cursor.dy}"/>
            </Action>
            <Action Name="WalkAlongWorkAreaFloor" Type="Sequence" Loop="false">
                <ActionReference Name="Walk" TargetX="${mascot.environment.workArea.left+64+Math.random()*(mascot.environment.workArea.width-128)}" />
            </Action>
        </ActionList>
    </Mascot>
    """

    private func parsedLibrary() throws -> ShimejiActionLibrary {
        try #require(ShimejiActionLibraryParser.parse(Data(Self.fixture.utf8)))
    }

    @Test("多 ActionList 块合并 + 全部命名动作入库")
    func multipleActionListsMerged() throws {
        let lib = try parsedLibrary()
        #expect(lib.actions.count == 10)
        #expect(lib.action(named: "Stand") != nil)         // 第一块
        #expect(lib.action(named: "Fall") != nil)          // 第二块
    }

    @Test("叶子动作:类型/边界/pose 字段(路径归一/锚点/速度/时长)")
    func leafActionFields() throws {
        let lib = try parsedLibrary()
        let walk = try #require(lib.action(named: "Walk"))
        #expect(walk.type == .move)
        #expect(walk.borderType == .floor)
        #expect(walk.animations.count == 2)

        let main = walk.animations[0]
        #expect(main.isTurn == false)
        #expect(main.poses.count == 3)
        #expect(main.poses[0].image == "shime1.png")       // 去前导 /
        #expect(main.poses[0].imageAnchorX == 64)
        #expect(main.poses[0].imageAnchorY == 128)
        #expect(main.poses[0].velocityX == -2)
        #expect(main.poses[0].velocityY == 0)
        #expect(main.poses[0].durationTicks == 6)
        #expect(main.durationTicks == 16)                  // 6+6+4

        #expect(walk.animations[1].isTurn == true)
    }

    @Test("多 Animation Condition 分支保留原文 + 顺序")
    func animationConditionBranches() throws {
        let lib = try parsedLibrary()
        let sit = try #require(lib.action(named: "SitAndLookAtMouse"))
        #expect(sit.animations.count == 2)
        // XMLDocument 已解码 &lt; → <
        #expect(sit.animations[0].condition == "#{mascot.environment.cursor.y < mascot.environment.screen.height/2}")
        #expect(sit.animations[1].condition == nil)
    }

    @Test("Embedded 带 Class 原文 + 参数入 params")
    func embeddedAction() throws {
        let lib = try parsedLibrary()
        let falling = try #require(lib.action(named: "Falling"))
        #expect(falling.type == .embedded(className: "com.group_finity.mascot.action.Fall"))
        #expect(falling.params["InitialVX"] == "0")
        #expect(falling.animations.count == 1)
    }

    @Test("Sequence:引用参数覆盖 + 匿名内联 Select 混排(真实 Fall 结构)")
    func sequenceWithInlineSelect() throws {
        let lib = try parsedLibrary()
        let fall = try #require(lib.action(named: "Fall"))
        #expect(fall.type == .sequence)
        #expect(fall.params["Loop"] == "false")
        #expect(fall.children.count == 2)

        guard case .reference(let fallingRef) = fall.children[0] else {
            Issue.record("children[0] 应是 Falling 引用"); return
        }
        #expect(fallingRef.name == "Falling")
        #expect(fallingRef.paramOverrides.isEmpty)

        guard case .inline(let select) = fall.children[1] else {
            Issue.record("children[1] 应是匿名内联 Select"); return
        }
        #expect(select.type == .select)
        #expect(select.name == "")
        #expect(select.children.count == 2)

        guard case .inline(let landSeq) = select.children[0] else {
            Issue.record("Select children[0] 应是匿名内联 Sequence"); return
        }
        #expect(landSeq.type == .sequence)
        #expect(landSeq.params["Condition"] == "${mascot.environment.floor.isOn(mascot.anchor)}")
        guard case .reference(let standRef) = landSeq.children[1] else {
            Issue.record("落地序列第二项应是 Stand 引用"); return
        }
        #expect(standRef.paramOverrides["Duration"] == "${100+Math.random()*100}")

        guard case .reference(let grabRef) = select.children[1] else {
            Issue.record("Select children[1] 应是 GrabWall 引用"); return
        }
        #expect(grabRef.name == "GrabWall")
        #expect(grabRef.paramOverrides["Duration"] == "100")
    }

    @Test("Thrown:引用覆盖 InitialVX/VY 为光标速度脚本")
    func thrownOverridesInitialVelocity() throws {
        let lib = try parsedLibrary()
        let thrown = try #require(lib.action(named: "Thrown"))
        guard case .reference(let ref) = thrown.children[0] else {
            Issue.record("Thrown children[0] 应是 Falling 引用"); return
        }
        #expect(ref.paramOverrides["InitialVX"] == "${mascot.environment.cursor.dx}")
        #expect(ref.paramOverrides["InitialVY"] == "${mascot.environment.cursor.dy}")
    }

    @Test("引用闭合(含嵌套 inline 内的引用)")
    func referencesResolve() throws {
        #expect(try parsedLibrary().danglingReferences().isEmpty)
    }

    @Test("悬空引用检出(嵌套 inline 内)")
    func danglingDetected() throws {
        let xml = """
        <Mascot><ActionList>
            <Action Name="A" Type="Sequence">
                <Action Type="Select">
                    <ActionReference Name="Ghost"/>
                </Action>
            </Action>
        </ActionList></Mascot>
        """
        let lib = try #require(ShimejiActionLibraryParser.parse(Data(xml.utf8)))
        #expect(lib.danglingReferences() == ["Ghost"])
    }

    @Test("pose 取模推进(Shimeji getPoseAt 公式)")
    func poseAdvancement() throws {
        let lib = try parsedLibrary()
        let walk = try #require(lib.action(named: "Walk"))
        let anim = walk.animations[0]   // 时长 6,6,4 = 16
        #expect(anim.pose(atTick: 0)?.image == "shime1.png")
        #expect(anim.pose(atTick: 5)?.image == "shime1.png")
        #expect(anim.pose(atTick: 6)?.image == "shime2.png")
        #expect(anim.pose(atTick: 11)?.image == "shime2.png")
        #expect(anim.pose(atTick: 12)?.image == "shime3.png")
        #expect(anim.pose(atTick: 15)?.image == "shime3.png")
        #expect(anim.pose(atTick: 16)?.image == "shime1.png")   // 取模回绕
        #expect(anim.pose(atTick: 38)?.image == "shime2.png")   // 38%16=6
    }

    @Test("非法结构返回 nil(无 ActionList)")
    func malformedReturnsNil() {
        #expect(ShimejiActionLibraryParser.parse(Data("<Mascot></Mascot>".utf8)) == nil)
        #expect(ShimejiActionLibraryParser.parse(Data("<not-xml".utf8)) == nil)
    }
}
