import Foundation

/// JavaScriptCore 实现的条件求值器。`ShimejiScriptEngine` 的薄适配器:
/// init 绑定一帧 mascot 快照,`isSatisfied` 对各候选条件复用同一 context。
///
/// 为何 JS 能直接求值 Shimeji 条件:Shimeji EL(`mascot.x >= a && b || c ? d : e`、`.isOn(p)`、
/// `< 50`)是 JS 兼容子集;XMLDocument 已把 `&lt;`/`&amp;&amp;` 解码成真 `<`/`&&`。
/// 空条件 = 无门控 = 恒成立;无法求值/出错保守降级 `false`(不触发条件错误的行为)。
///
/// 生命周期:每次行为转移构造一个(绑定当帧快照);执行器长持 `ShimejiScriptEngine`
/// 每 tick `sync` 后用 `init(engine:)` 包装复用。条件只在转移/动画分支选取时求值。
public final class JSConditionEvaluator: ConditionEvaluator {
    private let engine: ShimejiScriptEngine

    public init(mascot: BehaviorMascot) {
        engine = ShimejiScriptEngine()
        engine.sync(mascot: mascot)
    }

    /// 包装一个已 sync 的常驻引擎(执行器每 tick 复用,免重建 context)。
    public init(engine: ShimejiScriptEngine) {
        self.engine = engine
    }

    public func isSatisfied(_ condition: String) -> Bool {
        let expr = ShimejiScriptEngine.unwrap(condition)
        guard !expr.isEmpty else { return true }   // 空条件 = 无门控 = 恒成立
        return engine.evalBool(condition, fallback: false)
    }
}
