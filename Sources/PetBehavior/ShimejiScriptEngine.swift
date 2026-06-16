import Foundation
import JavaScriptCore

/// Shimeji 脚本引擎:单 `JSContext` 复用 + 每 tick `sync(mascot:)` 重绑状态 + bool/数值求值。
///
/// 动作执行器的求值底座 —— Shimeji 语义是**参数每 tick 重求值**(`Duration`/`TargetX`/
/// `Condition` 都是脚本,可含 `Math.random()`/环境量),且动作把 `VelocityX`/`FootDX` 等变量
/// 写回供动画条件读。相比每次转移新建 JSContext 的求值方式,这里 context 常驻、每 tick 只重跑一小段
/// setup 脚本(绑定 mascot 快照),便宜且变量可跨求值存活。
///
/// 求值失败一律返回 fallback(保守降级,不崩不传播);数值求值带**字面量快通道**
/// (`"250"`/`"-2"` 直接 parse,不进 JS —— 真实包参数大半是字面量)。
public final class ShimejiScriptEngine {
    private let context: JSContext

    public init() {
        let ctx = JSContext()!
        ctx.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        self.context = ctx
    }

    /// 每 tick(或每次状态变化后)重绑 mascot 快照。重复调用安全(setup 脚本幂等覆盖)。
    public func sync(mascot: BehaviorMascot) {
        context.exception = nil
        context.evaluateScript(Self.setupScript(mascot))
    }

    /// 写一个全局脚本变量(动作写回 `VelocityX`/`VelocityY`/`FootX`/`FootDX`,动画条件可读)。
    /// 注意 `sync` 不清这些变量(独立全局名),与 Shimeji VariableMap put 语义一致。
    public func setVariable(_ name: String, _ value: Double) {
        context.setObject(value, forKeyedSubscript: name as NSString)
    }

    /// bool 求值。`script` nil/空 → fallback;出错 → fallback。
    public func evalBool(_ script: String?, fallback: Bool) -> Bool {
        guard let script else { return fallback }
        let expr = Self.unwrap(script)
        guard !expr.isEmpty else { return fallback }

        context.exception = nil
        let result = context.evaluateScript(expr)
        if context.exception != nil {
            context.exception = nil
            return fallback
        }
        return result?.toBool() ?? fallback
    }

    /// 数值求值(字面量快通道 → JS)。nil/空/出错/NaN → fallback。
    public func evalDouble(_ script: String?, fallback: Double) -> Double {
        guard let script else { return fallback }
        let expr = Self.unwrap(script)
        guard !expr.isEmpty else { return fallback }
        if let literal = Double(expr) { return literal }   // 快通道:"250"/"-2.5"

        context.exception = nil
        let result = context.evaluateScript(expr)
        if context.exception != nil {
            context.exception = nil
            return fallback
        }
        guard let value = result?.toDouble(), value.isFinite else { return fallback }
        return value
    }

    /// 整数求值(evalDouble 取整)。
    public func evalInt(_ script: String?, fallback: Int) -> Int {
        let value = evalDouble(script, fallback: Double(fallback))
        guard value.isFinite, value < Double(Int.max), value > Double(Int.min) else { return fallback }
        return Int(value.rounded())
    }

    // MARK: - setup 脚本(mascot 状态 → JS 对象图)

    /// 生成绑定 mascot 状态的 setup 脚本。`isOn` 与 floor/ceiling/wall 派生参照 Shimeji-Desktop 的
    /// `Wall`/`FloorCeiling.isOn` + `MascotEnvironment.getFloor/getCeiling/getWall` 重新实现(逻辑级,未拷贝源码)。
    /// 坐标取整(Shimeji 整数像素语义 → `===` 稳健,免浮点边界)。
    static func setupScript(_ mascot: BehaviorMascot) -> String {
        let a = mascot.anchor
        let env = mascot.environment
        let wa = env.workArea, ie = env.activeWindow, scr = env.screen, cur = env.cursor
        return """
        function _fc(y,l,r,v){return{value:y,left:l,right:r,isOn:function(p){return v&&y===p.y&&l<=p.x&&p.x<=r;}};}
        function _wl(x,t,b,v){return{value:x,top:t,bottom:b,isOn:function(p){return v&&x===p.x&&t<=p.y&&p.y<=b;}};}
        function _notOn(){return{isOn:function(){return false;}};}
        function _area(l,t,r,b,v){return{left:l,top:t,right:r,bottom:b,width:r-l,height:b-t,visible:v,leftBorder:_wl(l,t,b,v),rightBorder:_wl(r,t,b,v),topBorder:_fc(t,l,r,v),bottomBorder:_fc(b,l,r,v)};}
        var _anchor={x:\(int(a.x)),y:\(int(a.y))};
        var _lookRight=\(bool(mascot.lookRight));
        var _wa=_area(\(int(wa.left)),\(int(wa.top)),\(int(wa.right)),\(int(wa.bottom)),\(bool(wa.visible)));
        var _ie=_area(\(int(ie.left)),\(int(ie.top)),\(int(ie.right)),\(int(ie.bottom)),\(bool(ie.visible)));
        var _scr=_area(\(int(scr.left)),\(int(scr.top)),\(int(scr.right)),\(int(scr.bottom)),\(bool(scr.visible)));
        var _cursor={x:\(int(cur.x)),y:\(int(cur.y)),dx:\(num(cur.dx)),dy:\(num(cur.dy))};
        function _floor(){if(_ie.topBorder.isOn(_anchor))return _ie.topBorder;if(_wa.bottomBorder.isOn(_anchor))return _wa.bottomBorder;return _notOn();}
        function _ceiling(){if(_ie.bottomBorder.isOn(_anchor))return _ie.bottomBorder;if(_wa.topBorder.isOn(_anchor))return _wa.topBorder;return _notOn();}
        function _wall(){if(_lookRight){if(_ie.leftBorder.isOn(_anchor))return _ie.leftBorder;if(_wa.rightBorder.isOn(_anchor))return _wa.rightBorder;}else{if(_ie.rightBorder.isOn(_anchor))return _ie.rightBorder;if(_wa.leftBorder.isOn(_anchor))return _wa.leftBorder;}return _notOn();}
        var mascot={anchor:_anchor,lookRight:_lookRight,totalCount:\(mascot.totalCount),environment:{workArea:_wa,activeIE:_ie,screen:_scr,cursor:_cursor,floor:_floor(),ceiling:_ceiling(),wall:_wall()}};
        """
    }

    /// Shimeji EL 静态/动态:`${...}` = **静态**(整个动作生命周期只求值一次,如 Walk 的随机
    /// TargetX、Sit 的随机 Duration);`#{...}` = **动态**(每 tick 重求值,如 `floor.isOn(anchor)`)。
    /// 不区分会让 `${...Math.random()...}` 每帧重掷 → 目标/时长抖动(摆头、行为时长不稳)。
    static func isStatic(_ script: String) -> Bool {
        script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("${")
    }

    /// 去 `#{...}` / `${...}` 包裹,取内层表达式;无包裹则原样(已 trim)。
    static func unwrap(_ condition: String) -> String {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("#{") || trimmed.hasPrefix("${")), trimmed.hasSuffix("}") {
            return String(trimmed.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func int(_ v: Double) -> String { String(Int(v.rounded())) }
    private static func num(_ v: Double) -> String { v.isFinite ? String(v) : "0" }
    private static func bool(_ v: Bool) -> String { v ? "true" : "false" }
}
