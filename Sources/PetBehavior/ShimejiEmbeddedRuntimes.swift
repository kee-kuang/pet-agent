import Foundation

/// Embedded 动作运行时:Fall(重力物理)/Jump(定向跳)/Dragged(跟光标弹簧)/Regist(挣扎)/
/// Look/Offset(即时)。参照 Shimeji-Desktop 的 `action/{Fall,Jump,Dragged,Regist,Look,Offset}.java`
/// 重新实现各动作物理公式(逻辑级,未拷贝源码)。scaling 恒 1(无 Shimeji 缩放设置,声明简化)。

// MARK: - InstantAction

/// ≙ Java `InstantAction`:start 当帧 apply 一次,hasNext 恒 false,tick no-op。
public class ShimejiInstantRuntime: ShimejiActionRuntime {
    override public func start(_ ctx: ShimejiTickContext) {
        super.start(ctx)
        if super.hasNext(ctx) { apply(ctx) }
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool { false }

    /// 子类实现一次性效果。
    func apply(_ ctx: ShimejiTickContext) {}
}

/// ≙ Java `Look`:置朝向(`LookRight` 参数,缺省取反当前朝向)。
public final class ShimejiLookRuntime: ShimejiInstantRuntime {
    override func apply(_ ctx: ShimejiTickContext) {
        ctx.state.lookRight = paramBool(ctx, "LookRight", fallback: !ctx.state.lookRight)
    }
}

/// ≙ Java `Offset`:anchor 平移 `X`/`Y`(缺省 0;Java 未乘 scaling,保持)。
public final class ShimejiOffsetRuntime: ShimejiInstantRuntime {
    override func apply(_ ctx: ShimejiTickContext) {
        ctx.state.anchor.x += paramDouble(ctx, "X", fallback: 0)
        ctx.state.anchor.y += paramDouble(ctx, "Y", fallback: 0)
    }
}

// MARK: - Fall

/// ≙ Java `Fall`:重力 + 空气阻力积分、亚像素累积、路径分步碰撞(防穿地/穿墙)、
/// 落地/撞墙即止。InitialVX/VY **start 时求值一次**(Thrown 经引用覆盖为光标速度);
/// Registance/Gravity 每 tick 重求值。**不靠 pose velocity 移动**(动画只是视觉)。
public final class ShimejiFallRuntime: ShimejiActionRuntime {
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private var modX: Double = 0
    private var modY: Double = 0

    override public func start(_ ctx: ShimejiTickContext) {
        super.start(ctx)
        velocityX = paramDouble(ctx, "InitialVX", fallback: 0)
        velocityY = paramDouble(ctx, "InitialVY", fallback: 0)
        modX = 0
        modY = 0
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        let a = ctx.state.anchor
        // 仍在下落:有上升速度时无视脚下地板;否则不在地板上;且没扒在墙上。
        let aboveGround = velocityY < 0 || !ctx.environment.isOnAnyFloor(a)
        return aboveGround && !ctx.environment.isOnAnyWall(a, lookRight: ctx.state.lookRight)
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        if velocityX != 0 { ctx.state.lookRight = velocityX > 0 }

        let registanceX = paramDouble(ctx, "RegistanceX", fallback: 0.05)
        let registanceY = paramDouble(ctx, "RegistanceY", fallback: 0.1)
        let gravity = paramDouble(ctx, "Gravity", fallback: 2)
        velocityX -= velocityX * registanceX
        velocityY += -velocityY * registanceY + gravity
        ctx.engine.setVariable("VelocityX", velocityX)
        ctx.engine.setVariable("VelocityY", velocityY)

        // 亚像素累积(Java:modX += vX % 1; dx = round(vX + modX); modX %= 1)。
        modX += velocityX.truncatingRemainder(dividingBy: 1)
        modY += velocityY.truncatingRemainder(dividingBy: 1)
        let dx = Int((velocityX + modX).rounded())
        let dy = Int((velocityY + modY).rounded())
        modX = modX.truncatingRemainder(dividingBy: 1)
        modY = modY.truncatingRemainder(dividingBy: 1)

        // 路径分步碰撞:沿位移逐点探测;下落时每点向上扫 80px 找地板(窗口可能移进路径)。
        let startX = ctx.state.anchor.x
        let startY = ctx.state.anchor.y
        let dev = max(1, max(abs(dx), abs(dy)))
        outer: for i in 0...dev {
            let x = startX + Double(dx * i) / Double(dev)
            let y = startY + Double(dy * i) / Double(dev)
            if dy > 0 {
                for j in -80...0 {
                    ctx.state.anchor = BehaviorPoint(x: x, y: y + Double(j))
                    if ctx.environment.isOnAnyFloor(ctx.state.anchor) { break outer }   // 落地
                }
            } else {
                ctx.state.anchor = BehaviorPoint(x: x, y: y)
            }
            if ctx.environment.isOnAnyWall(ctx.state.anchor, lookRight: ctx.state.lookRight) {
                break   // 撞墙
            }
        }

        applyAnimation(ctx, animation(ctx))
    }
}

// MARK: - Jump

/// ≙ Java `Jump`:以恒速 `VelocityParam`(默认 20)直线奔向「目标 + |Δx|/2 抬升」的抛物视点,
/// 距离 ≤ 一步即吸附目标结束。
public final class ShimejiJumpRuntime: ShimejiActionRuntime {
    private func targetX(_ ctx: ShimejiTickContext) -> Double { paramDouble(ctx, "TargetX", fallback: 0) }
    private func targetY(_ ctx: ShimejiTickContext) -> Double { paramDouble(ctx, "TargetY", fallback: 0) }

    private func offsetVector(_ ctx: ShimejiTickContext) -> (dx: Double, dy: Double) {
        let a = ctx.state.anchor
        let dx = targetX(ctx) - a.x
        let dy = targetY(ctx) - a.y - abs(dx) / 2   // 抛物弧:目标视点抬高 |Δx|/2
        return (dx, dy)
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        let (dx, dy) = offsetVector(ctx)
        return (dx * dx + dy * dy).squareRoot() != 0
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        let tX = targetX(ctx)
        let tY = targetY(ctx)
        if Int(ctx.state.anchor.x.rounded()) != Int(tX.rounded()) {
            ctx.state.lookRight = ctx.state.anchor.x < tX
        }

        let (dx, dy) = offsetVector(ctx)
        let distance = (dx * dx + dy * dy).squareRoot()
        let speed = paramDouble(ctx, "VelocityParam", fallback: 20)

        if distance != 0 {
            let vX = speed * dx / distance
            let vY = speed * dy / distance
            ctx.engine.setVariable("VelocityX", vX)
            ctx.engine.setVariable("VelocityY", vY)
            ctx.state.anchor.x += vX.rounded()
            ctx.state.anchor.y += vY.rounded()
            applyAnimation(ctx, animation(ctx))
        }
        if distance <= speed {
            ctx.state.anchor = BehaviorPoint(x: tX, y: tY)   // 最后一步吸附
        }
    }
}

// MARK: - Dragged

/// ≙ Java `Dragged`:anchor 硬贴光标(+偏移),`FootDX` 弹簧(k=0.1,阻尼 0.8)驱动摇摆动画;
/// 光标拉远(≥5px)重置计时;~250 tick 后挣扎(转 Regist)。
/// 声明简化:`OffsetType="Origin"` 需图像中心(引擎不持图)→ 按 ImageAnchor 模式处理。
public final class ShimejiDraggedRuntime: ShimejiActionRuntime {
    private var footX: Double = 0
    private var footDx: Double = 0
    private var timeToResist = 250

    override public func start(_ ctx: ShimejiTickContext) {
        super.start(ctx)
        footX = ctx.environment.cursor.x + paramDouble(ctx, "OffsetX", fallback: 0).rounded()
        footDx = 0
        timeToResist = 250
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        super.hasNext(ctx) && time(ctx) < timeToResist
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        ctx.state.lookRight = false
        ctx.state.dragging = true

        let cursor = ctx.environment.cursor
        let offsetX = paramDouble(ctx, "OffsetX", fallback: 0).rounded()
        let offsetY = paramDouble(ctx, "OffsetY", fallback: 120).rounded()

        // 光标拉远 → 重置局部计时(防过早 resist)。
        if abs(cursor.x + offsetX - ctx.state.anchor.x) >= 5 { setTime(ctx, 0) }

        footDx = (footDx + (cursor.x - footX) * 0.1) * 0.8
        footX += footDx
        ctx.engine.setVariable("FootDX", footDx)
        ctx.engine.setVariable("FootX", footX)

        applyAnimation(ctx, animation(ctx))
        ctx.state.anchor = BehaviorPoint(x: cursor.x + offsetX, y: cursor.y + offsetY)

        // Java quirk:到点前一帧 90% 概率延一帧(保留原版随机手感)。
        if time(ctx) == timeToResist - 1, ctx.rng.nextUnit() >= 0.1 { timeToResist += 1 }
    }
}

// MARK: - Regist

/// ≙ Java `Regist`(拖拽后挣扎):光标仍在身边(<5px)时播挣扎动画;放完 → 随机朝向 + 抛
/// lostGround 脱手落下;光标离开 → hasNext false(回 Dragged 循环)。
public final class ShimejiRegistRuntime: ShimejiActionRuntime {
    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        guard super.hasNext(ctx) else { return false }
        let offsetX = paramDouble(ctx, "OffsetX", fallback: 0).rounded()
        return abs(ctx.environment.cursor.x - ctx.state.anchor.x + offsetX) < 5
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        ctx.state.dragging = true
        let anim = animation(ctx)
        applyAnimation(ctx, anim)
        if let anim, time(ctx) + 1 >= anim.durationTicks {
            ctx.state.lookRight = ctx.rng.nextUnit() < 0.5
            throw ShimejiActionInterruption.lostGround   // 挣脱 → 引擎转 Fall
        }
    }
}
