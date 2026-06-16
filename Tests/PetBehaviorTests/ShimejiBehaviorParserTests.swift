import Foundation
import Testing
import PetBehavior

/// 覆盖 behaviors.xml 解析的全部分支:频率/隐藏/动作名、Condition 分组继承(顶层 + NextBehavior 内)、
/// NextBehavior Add、BehaviorReference 自带频率、顶层文档序、两遍式悬空引用校验、非法结构。
@Suite("ShimejiBehaviorParser")
struct ShimejiBehaviorParserTests {
    /// 综合 fixture:命名空间 + Condition 分组(顶层与嵌套)+ NextBehavior(Add true/false)+
    /// ref 嵌套 Condition + 自身 Condition 属性叠加。
    static let fixture = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <BehaviorList>
            <Behavior Name="ChaseMouse" Frequency="0" Hidden="true">
                <NextBehavior Add="false">
                    <BehaviorReference Name="SitDown" Frequency="1" />
                </NextBehavior>
            </Behavior>
            <Behavior Name="Walk" Frequency="100" Action="WalkAction" />
            <Condition Condition="onFloor">
                <Behavior Name="SitDown" Frequency="200">
                    <NextBehavior Add="true">
                        <BehaviorReference Name="LieDown" Frequency="100" />
                        <Condition Condition="nearCeiling">
                            <BehaviorReference Name="Crawl" Frequency="50" />
                        </Condition>
                    </NextBehavior>
                </Behavior>
                <Condition Condition="canSplit">
                    <Behavior Name="Split" Frequency="50" Condition="ownCond" />
                </Condition>
            </Condition>
            <Behavior Name="LieDown" Frequency="0" />
            <Behavior Name="Crawl" Frequency="0" />
            <Behavior Name="Fall" Frequency="0" Hidden="true" />
        </BehaviorList>
    </Mascot>
    """

    private func parsedFixture() throws -> ShimejiBehaviorGraph {
        try #require(ShimejiBehaviorParser.parse(xmlData(Self.fixture)))
    }

    @Test("顶层文档序保序")
    func topLevelOrderPreserved() throws {
        let graph = try parsedFixture()
        #expect(graph.topLevelOrder == ["ChaseMouse", "Walk", "SitDown", "Split", "LieDown", "Crawl", "Fall"])
    }

    @Test("基础属性:频率/动作名缺省/隐藏")
    func basicAttributes() throws {
        let graph = try parsedFixture()
        let walk = try #require(graph.behavior(named: "Walk"))
        #expect(walk.frequency == 100)
        #expect(walk.actionName == "WalkAction")
        #expect(walk.hidden == false)
        #expect(walk.conditions.isEmpty)
        #expect(walk.nextAdditive == true)       // 无 NextBehavior → 默认 additive
        #expect(walk.nextBehaviors.isEmpty)

        let chase = try #require(graph.behavior(named: "ChaseMouse"))
        #expect(chase.frequency == 0)
        #expect(chase.hidden == true)
        #expect(chase.actionName == "ChaseMouse")  // 无 Action 属性 → 缺省 = name
    }

    @Test("Condition 分组继承到子 Behavior + 自身 Condition 叠加")
    func conditionInheritance() throws {
        let graph = try parsedFixture()
        // SitDown 在 <Condition Condition="onFloor"> 内
        let sit = try #require(graph.behavior(named: "SitDown"))
        #expect(sit.conditions == ["onFloor"])
        #expect(sit.frequency == 200)
        // Split 嵌在 <Condition onFloor> → <Condition canSplit> 双层内 + 自身 Condition="ownCond"
        // → AND-链按外到内 + 自身追加(顺序保真)。
        let split = try #require(graph.behavior(named: "Split"))
        #expect(split.conditions == ["onFloor", "canSplit", "ownCond"])
    }

    @Test("NextBehavior Add=false + ref 自带频率")
    func nextBehaviorAddFalse() throws {
        let graph = try parsedFixture()
        let chase = try #require(graph.behavior(named: "ChaseMouse"))
        #expect(chase.nextAdditive == false)
        #expect(chase.nextBehaviors.count == 1)
        #expect(chase.nextBehaviors[0].name == "SitDown")
        #expect(chase.nextBehaviors[0].frequency == 1)
        #expect(chase.nextBehaviors[0].conditions.isEmpty)
    }

    @Test("NextBehavior Add=true + 内层 Condition 继承到 ref")
    func nextBehaviorConditionInheritance() throws {
        let graph = try parsedFixture()
        let sit = try #require(graph.behavior(named: "SitDown"))
        #expect(sit.nextAdditive == true)
        #expect(sit.nextBehaviors.count == 2)

        let lie = try #require(sit.nextBehaviors.first { $0.name == "LieDown" })
        #expect(lie.frequency == 100)
        #expect(lie.conditions.isEmpty)               // 直接在 NextBehavior 下,无内层 Condition

        let crawl = try #require(sit.nextBehaviors.first { $0.name == "Crawl" })
        #expect(crawl.frequency == 50)
        #expect(crawl.conditions == ["nearCeiling"])  // 内层 <Condition nearCeiling> 继承
    }

    @Test("引用闭合:所有 ref 指向存在的 behavior")
    func referencesResolve() throws {
        let graph = try parsedFixture()
        #expect(graph.danglingReferences().isEmpty)
    }

    @Test("两遍式校验:悬空引用被检出")
    func danglingReferenceDetected() throws {
        let xml = """
        <Mascot xmlns="http://www.group-finity.com/Mascot">
            <BehaviorList>
                <Behavior Name="A" Frequency="100">
                    <NextBehavior Add="false">
                        <BehaviorReference Name="Ghost" Frequency="1" />
                    </NextBehavior>
                </Behavior>
            </BehaviorList>
        </Mascot>
        """
        let graph = try #require(ShimejiBehaviorParser.parse(xmlData(xml)))
        #expect(graph.danglingReferences() == ["Ghost"])
    }

    @Test("非法结构返回 nil", arguments: [
        "<not-xml",
        "<Mascot xmlns=\"http://www.group-finity.com/Mascot\"></Mascot>",   // 无 BehaviorList
        "<Root><BehaviorList/></Root>",                                      // 无 Mascot 根但有 BehaviorList? 仍解析(localName 匹配)
    ])
    func malformedHandling(xml: String) {
        let graph = ShimejiBehaviorParser.parse(xmlData(xml))
        // 前两个应为 nil;第三个 BehaviorList 空 → 解析成功但 0 行为。分别断言。
        if xml.contains("not-xml") || xml.contains("</Mascot>") {
            #expect(graph == nil)
        } else {
            #expect(graph?.topLevelOrder.isEmpty == true)
        }
    }
}
