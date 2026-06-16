import Foundation

/// 复合动作运行时:Sequence(顺序 + Loop)与 Select(条件选首个可跑分支)。
/// 参照 Shimeji-Desktop 的 `ComplexAction`/`Sequence`/`Select` 重新实现复合动作语义(逻辑级,未拷贝源码):
/// - `setCurrentAction(i)` **内部 init 新子动作**(切换即初始化,Loop 取模回绕重 init)。
/// - `seek()` 经 setCurrentAction(+1) 跳过已结束子动作(逐个 init 后判 hasNext)。
/// - **Sequence.hasNext 先 seek**(每 tick 推进点);**Select 只在 start 时 seek 一次**
///   (选中即锁定 —— 这正是「按条件选分支」机制:子动作 Condition 不成立 → hasNext false → 跳过)。
public class ShimejiComplexRuntime: ShimejiActionRuntime {
    let children: [ShimejiActionRuntime]
    var currentIndex = 0

    public init(definition: ShimejiActionDefinition, children: [ShimejiActionRuntime]) {
        self.children = children
        super.init(definition: definition)
    }

    var currentChild: ShimejiActionRuntime? {
        currentIndex < children.count ? children[currentIndex] : nil
    }

    /// 下钻到当前正在执行的叶子动作(读 Affordance / 判 ScanMove 用)。
    override var currentLeaf: ShimejiActionRuntime { currentChild?.currentLeaf ?? self }

    override public func start(_ ctx: ShimejiTickContext) {
        super.start(ctx)
        guard !children.isEmpty, super.hasNext(ctx) else {
            currentIndex = children.count   // 直接判结束
            return
        }
        setCurrentChild(ctx, 0)
        seek(ctx)
    }

    /// ≙ Java `setCurrentAction`:换当前子动作并 init 它(Loop 语义由 Sequence 重写取模)。
    func setCurrentChild(_ ctx: ShimejiTickContext, _ index: Int) {
        currentIndex = index
        guard super.hasNext(ctx), let child = currentChild else { return }
        child.start(ctx)
    }

    /// ≙ Java `seek`:跳过已结束的子动作(切换即 init,init 后仍不 hasNext 继续跳)。
    func seek(_ ctx: ShimejiTickContext) {
        guard super.hasNext(ctx) else { return }
        var safety = children.count + 1   // Loop 取模下防无限(全部子动作都瞬完时跳出)
        while currentIndex < children.count, safety > 0 {
            if currentChild?.hasNext(ctx) == true { break }
            safety -= 1
            setCurrentChild(ctx, currentIndex + 1)
        }
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        super.hasNext(ctx) && currentChild?.hasNext(ctx) == true
    }

    override func tick(_ ctx: ShimejiTickContext) throws {
        guard let child = currentChild, child.hasNext(ctx) else { return }
        try child.next(ctx)
    }

    /// 复合动作的可拖拽性委托当前子动作(Java ComplexAction.isDraggable)。
    override public func isDraggable(_ ctx: ShimejiTickContext) -> Bool {
        currentChild?.isDraggable(ctx) ?? true
    }
}

/// ≙ Java `Sequence`:hasNext 先 seek(推进到下一未结束子动作);`Loop="true"` 时索引取模回绕
/// (子动作被重 init → 无限循环,靠外层 Duration/Condition 终止)。
public final class ShimejiSequenceRuntime: ShimejiComplexRuntime {
    private func isLoop(_ ctx: ShimejiTickContext) -> Bool {
        paramBool(ctx, "Loop", fallback: false)
    }

    override func setCurrentChild(_ ctx: ShimejiTickContext, _ index: Int) {
        let resolved = (isLoop(ctx) && !children.isEmpty) ? index % children.count : index
        super.setCurrentChild(ctx, resolved)
    }

    override public func hasNext(_ ctx: ShimejiTickContext) -> Bool {
        seek(ctx)
        return super.hasNext(ctx)
    }
}

/// ≙ Java `Select`:纯 ComplexAction —— start 时 seek 选中第一个可跑分支后锁定,
/// 该分支结束整个 Select 结束(不回头试其它分支)。
public final class ShimejiSelectRuntime: ShimejiComplexRuntime {}
