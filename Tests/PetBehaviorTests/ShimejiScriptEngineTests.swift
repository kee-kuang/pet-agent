import Foundation
import Testing
import PetBehavior

/// 覆盖脚本引擎:数值求值(字面量快通道/真实包参数脚本/Math.random 范围)、sync 重绑翻转派生边、
/// 变量写回供条件读、cursor 速度、出错降级。
@Suite("ShimejiScriptEngine")
struct ShimejiScriptEngineTests {
    private func mascot(anchorY: Double = 1040, cursorDX: Double = 0) -> BehaviorMascot {
        BehaviorMascot(
            anchor: BehaviorPoint(x: 960, y: anchorY), lookRight: true, totalCount: 1,
            environment: BehaviorEnvironment(
                workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
                activeWindow: .invisible,
                screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080),
                cursor: BehaviorCursor(x: 500, y: 400, dx: cursorDX, dy: -3.5)
            )
        )
    }

    @Test("数值字面量快通道")
    func literalFastPath() {
        let engine = ShimejiScriptEngine()   // 未 sync 也能算字面量
        #expect(engine.evalDouble("250", fallback: 0) == 250)
        #expect(engine.evalDouble("-2.5", fallback: 0) == -2.5)
        #expect(engine.evalInt("${100}", fallback: 0) == 100)
    }

    @Test("真实包参数脚本:workArea 路点范围(含 Math.random)")
    func realParamScript() {
        let engine = ShimejiScriptEngine()
        engine.sync(mascot: mascot())
        let script = "${mascot.environment.workArea.left+64+Math.random()*(mascot.environment.workArea.width-128)}"
        for _ in 0..<20 {
            let x = engine.evalDouble(script, fallback: -1)
            #expect(x >= 64 && x <= 1856)   // [left+64, right-64]
        }
    }

    @Test("Thrown 初速:cursor.dx/dy 可读")
    func cursorVelocity() {
        let engine = ShimejiScriptEngine()
        engine.sync(mascot: mascot(cursorDX: 12.5))
        #expect(engine.evalDouble("${mascot.environment.cursor.dx}", fallback: 0) == 12.5)
        #expect(engine.evalDouble("${mascot.environment.cursor.dy}", fallback: 0) == -3.5)
        #expect(engine.evalBool("#{mascot.environment.cursor.y < mascot.environment.screen.height/2}", fallback: false) == true)   // 400 < 540
    }

    @Test("sync 重绑:anchor 变化翻转 floor.isOn")
    func resyncUpdatesDerivedBorders() {
        let engine = ShimejiScriptEngine()
        let onFloor = "#{mascot.environment.floor.isOn(mascot.anchor)}"
        engine.sync(mascot: mascot(anchorY: 1040))
        #expect(engine.evalBool(onFloor, fallback: false) == true)
        engine.sync(mascot: mascot(anchorY: 500))           // 升到半空
        #expect(engine.evalBool(onFloor, fallback: true) == false)
        engine.sync(mascot: mascot(anchorY: 1040))          // 回地面
        #expect(engine.evalBool(onFloor, fallback: false) == true)
    }

    @Test("变量写回:动作写 VelocityX/FootDX,动画条件可读,且 sync 后存活")
    func actionVariables() {
        let engine = ShimejiScriptEngine()
        engine.sync(mascot: mascot())
        engine.setVariable("VelocityX", -7)
        engine.setVariable("FootDX", 2.5)
        #expect(engine.evalBool("#{VelocityX < 0}", fallback: false) == true)
        #expect(engine.evalDouble("${FootDX*2}", fallback: 0) == 5)
        engine.sync(mascot: mascot(anchorY: 500))           // 重绑 mascot 不清动作变量
        #expect(engine.evalBool("#{VelocityX < 0}", fallback: false) == true)
    }

    @Test("出错/NaN/空降级 fallback")
    func errorFallback() {
        let engine = ShimejiScriptEngine()
        engine.sync(mascot: mascot())
        #expect(engine.evalDouble("${mascot.bogus.thing()}", fallback: 42) == 42)
        #expect(engine.evalDouble("${0/0}", fallback: 7) == 7)              // NaN
        #expect(engine.evalDouble(nil, fallback: 1) == 1)
        #expect(engine.evalDouble("  ", fallback: 2) == 2)
        #expect(engine.evalBool("#{((", fallback: true) == true)
        #expect(engine.evalInt("${1e99}", fallback: 5) == 5)                // 超 Int 範围
    }
}
