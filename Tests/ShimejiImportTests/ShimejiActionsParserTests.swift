import Testing
import Foundation
@testable import ShimejiImport

@Suite("ShimejiActionsParser")
struct ShimejiActionsParserTests {

    /// 仿真实 Shimeji actions.xml:带命名空间 + 自定义帧名(火柴人 dance/bounce)+ 叶子动作
    /// (Stay/Move/Animate)+ 应跳过的编排(Sequence)/引擎(Embedded)动作。
    private let xml = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <Mascot xmlns="http://www.group-finity.com/Mascot">
      <ActionList>
        <Action Name="Stand" Type="Stay" BorderType="Floor">
          <Animation>
            <Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
          </Animation>
        </Action>
        <Action Name="Walk" Type="Move" BorderType="Floor">
          <Animation>
            <Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="-2,0" Duration="6" />
            <Pose Image="/shime2.png" ImageAnchor="64,128" Velocity="-2,0" Duration="6" />
            <Pose Image="/shime3.png" ImageAnchor="64,128" Velocity="-2,0" Duration="6" />
          </Animation>
        </Action>
        <Action Name="Dance" Type="Animate" BorderType="Floor">
          <Animation>
            <Pose Image="/dance01.png" Velocity="0,0" Duration="4" />
            <Pose Image="/dance02.png" Velocity="0,0" Duration="4" />
          </Animation>
        </Action>
        <Action Name="SitAndLookAtMouse" Type="Stay" BorderType="Floor">
          <Animation Condition="#{cursor.y &lt; 100}">
            <Pose Image="/look_up.png" Duration="10" />
          </Animation>
          <Animation>
            <Pose Image="/look_down.png" Duration="10" />
          </Animation>
        </Action>
        <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall" Gravity="2" />
        <Action Name="WalkAndSit" Type="Sequence">
          <ActionReference Name="Walk" />
          <ActionReference Name="Stand" />
        </Action>
      </ActionList>
    </Mascot>
    """

    @Test("解析叶子动作 Pose 帧序(自定义帧名 + 去前导/ + Duration/Velocity)")
    func parsesLeafActions() throws {
        let actions = ShimejiActionsParser.parse(Data(xml.utf8))
        // Stand:单帧 shime1。
        #expect(actions["Stand"]?.map(\.image) == ["shime1.png"])
        #expect(actions["Stand"]?.first?.durationTicks == 250)
        // Walk:三帧 + 位移 -2(左)。
        #expect(actions["Walk"]?.map(\.image) == ["shime1.png", "shime2.png", "shime3.png"])
        #expect(actions["Walk"]?.first?.velocityX == -2)
        // Dance:自定义帧名(火柴人核心 —— 证明非 shimeN 命名也能解析)。
        #expect(actions["Dance"]?.map(\.image) == ["dance01.png", "dance02.png"])
    }

    @Test("多 Animation Condition → 取第一个分支")
    func picksFirstAnimationBranch() {
        let actions = ShimejiActionsParser.parse(Data(xml.utf8))
        #expect(actions["SitAndLookAtMouse"]?.map(\.image) == ["look_up.png"])   // 首个(条件)分支
    }

    @Test("跳过 Embedded(引擎)/ Sequence(编排)动作 —— 无 sprite 行可落")
    func skipsNonLeafActions() {
        let actions = ShimejiActionsParser.parse(Data(xml.utf8))
        #expect(actions["Falling"] == nil)       // Embedded
        #expect(actions["WalkAndSit"] == nil)    // Sequence
    }

    @Test("无效 XML → 空表(不崩)")
    func malformedYieldsEmpty() {
        #expect(ShimejiActionsParser.parse(Data("not xml <<".utf8)).isEmpty)
        #expect(ShimejiActionsParser.parse(Data()).isEmpty)
    }

    @Test("normalizeImage / velocityX 边界")
    func helpers() {
        #expect(ShimejiActionsParser.normalizeImage("/a/b.png") == "a/b.png")
        #expect(ShimejiActionsParser.normalizeImage("c.png") == "c.png")
        #expect(ShimejiActionsParser.velocityX("-4,0") == -4)
        #expect(ShimejiActionsParser.velocityX("${expr},0") == 0)   // 表达式 → 0
        #expect(ShimejiActionsParser.velocityX(nil) == 0)
    }
}
