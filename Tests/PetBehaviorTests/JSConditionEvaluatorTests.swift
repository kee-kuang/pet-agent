import Foundation
import Testing
import PetBehavior

/// 用**真实 Shimeji 条件串**对构造的 mascot 求值,验证 JSC 求值器 + isOn 派生(floor/ceiling/wall)
/// 1:1 还原 Shimeji 语义。坐标 top-origin:screen/workArea top=0,floor=workArea.bottom(y=1040)。
@Suite("JSConditionEvaluator")
struct JSConditionEvaluatorTests {
    // 标准桌面:1920×1080 屏,workArea 底留 40px Dock(bottom=1040),活动窗 [500,300,900,700]。
    private func mascot(
        anchor: BehaviorPoint,
        lookRight: Bool = true,
        totalCount: Int = 1,
        windowVisible: Bool = true
    ) -> BehaviorMascot {
        BehaviorMascot(
            anchor: anchor,
            lookRight: lookRight,
            totalCount: totalCount,
            environment: BehaviorEnvironment(
                workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
                activeWindow: BehaviorArea(left: 500, top: 300, right: 900, bottom: 700, visible: windowVisible),
                screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080)
            )
        )
    }

    private func eval(_ m: BehaviorMascot, _ condition: String) -> Bool {
        JSConditionEvaluator(mascot: m).isSatisfied(condition)
    }

    @Test("floor.isOn:站在工作区地面(workArea.bottom)")
    func onWorkAreaFloor() {
        let cond = "#{mascot.environment.floor.isOn(mascot.anchor)}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 960, y: 1040)), cond) == true)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 960, y: 500)), cond) == false)   // 半空
        #expect(eval(mascot(anchor: BehaviorPoint(x: 2100, y: 1040)), cond) == false) // x 出界(floor x 范围 0..1920)
    }

    @Test("floor.isOn:站在活动窗口顶边(activeIE.topBorder)")
    func onActiveWindowTop() {
        let cond = "#{mascot.environment.floor.isOn(mascot.anchor)}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 700, y: 300)), cond) == true)   // 窗顶 y=300,x∈[500,900]
        #expect(eval(mascot(anchor: BehaviorPoint(x: 450, y: 300)), cond) == false)  // x 在窗左外
    }

    @Test("ceiling.isOn:工作区顶")
    func onCeiling() {
        let cond = "#{mascot.environment.ceiling.isOn(mascot.anchor)}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 960, y: 0)), cond) == true)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 960, y: 500)), cond) == false)
    }

    @Test("wall 派生:lookRight 取右墙(workArea.rightBorder)")
    func wallLookRight() {
        // On the Wall 条件(真实 behaviors.xml 摘录)
        let cond = """
        #{ mascot.lookRight ? (
            mascot.environment.workArea.rightBorder.isOn(mascot.anchor) ||
            mascot.environment.activeIE.leftBorder.isOn(mascot.anchor) ) : (
            mascot.environment.workArea.leftBorder.isOn(mascot.anchor) ||
            mascot.environment.activeIE.rightBorder.isOn(mascot.anchor) ) }
        """
        // 面右 + 贴工作区右墙(x=1920,y∈[0,1040]) → true
        #expect(eval(mascot(anchor: BehaviorPoint(x: 1920, y: 500), lookRight: true), cond) == true)
        // 面右但在左墙 → false(面右不看左墙)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 500), lookRight: true), cond) == false)
        // 面左 + 贴左墙 → true
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 500), lookRight: false), cond) == true)
    }

    @Test("totalCount 比较")
    func totalCountComparison() {
        let cond = "#{mascot.totalCount < 50}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0), totalCount: 1), cond) == true)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0), totalCount: 60), cond) == false)
    }

    @Test("anchor.x 在活动窗口水平范围内(JumpFromBottomOfIE 条件)")
    func anchorWithinActiveWindowX() {
        let cond = "#{mascot.anchor.x >= mascot.environment.activeIE.left && mascot.anchor.x < mascot.environment.activeIE.right}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 700, y: 1040)), cond) == true)   // 500<=700<900
        #expect(eval(mascot(anchor: BehaviorPoint(x: 950, y: 1040)), cond) == false)  // >=900
        #expect(eval(mascot(anchor: BehaviorPoint(x: 900, y: 1040)), cond) == false)  // 严格 < right
    }

    @Test("${} 包裹与 #{} 等价 + 直接访问 area 边")
    func dollarWrapperAndDirectBorder() {
        let cond = "${mascot.environment.activeIE.topBorder.isOn(mascot.anchor)}"
        #expect(eval(mascot(anchor: BehaviorPoint(x: 700, y: 300)), cond) == true)
    }

    @Test("不可见区域 → 所有 isOn 恒 false")
    func invisibleAreaNeverOn() {
        let cond = "#{mascot.environment.activeIE.topBorder.isOn(mascot.anchor)}"
        // 坐标精确落在窗顶,但窗不可见 → false
        #expect(eval(mascot(anchor: BehaviorPoint(x: 700, y: 300), windowVisible: false), cond) == false)
    }

    @Test("空条件恒成立")
    func emptyConditionAlwaysTrue() {
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0)), "") == true)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0)), "   ") == true)
    }

    @Test("出错表达式保守降级 false")
    func malformedExpressionFallsBackFalse() {
        // 访问不存在的属性的方法 → JS 抛异常 → false
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0)), "#{mascot.bogus.thing()}") == false)
        #expect(eval(mascot(anchor: BehaviorPoint(x: 0, y: 0)), "#{这不是合法 js (((}") == false)
    }

    @Test("同一求值器复用于多条候选条件(pickNext 内场景)")
    func reuseAcrossConditions() {
        let evaluator = JSConditionEvaluator(mascot: mascot(anchor: BehaviorPoint(x: 960, y: 1040)))
        #expect(evaluator.isSatisfied("#{mascot.environment.floor.isOn(mascot.anchor)}") == true)
        #expect(evaluator.isSatisfied("#{mascot.environment.ceiling.isOn(mascot.anchor)}") == false)
        #expect(evaluator.isSatisfied("#{mascot.totalCount < 50}") == true)
        #expect(evaluator.isSatisfied("#{bogus()}") == false)            // 出错不污染后续
        #expect(evaluator.isSatisfied("#{mascot.totalCount < 50}") == true)
    }
}
