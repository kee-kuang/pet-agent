import Foundation

/// 边界派生 + isOn + move 跟随的 Swift 侧实现(执行器内部用,与 JS 侧 setup 脚本同语义)。
/// 参照 Shimeji-Desktop 的 `Wall`/`FloorCeiling.isOn`/`move` + `MascotEnvironment.getFloor/getCeiling/getWall`
/// 重新实现边界派生逻辑(逻辑级,未拷贝源码)。
/// JS 侧负责用户脚本条件;这里负责引擎内部检查(边界绑定/失地判定/Fall 落地扫描),
/// 用 live anchor,不经 JS。坐标整数像素语义 → 比较前取整。

/// 一条具体边:所属区域 + 哪一侧。
public struct ShimejiBorder: Sendable, Equatable {
    public enum Area: Sendable, Equatable {
        case workArea
        case activeWindow
    }

    public enum Side: Sendable, Equatable {
        case top      // FloorCeiling(workArea.top=天花板;window.top=可站的窗顶)
        case bottom   // FloorCeiling(workArea.bottom=地面;window.bottom=窗底=天花板)
        case left     // Wall
        case right    // Wall
    }

    public let area: Area
    public let side: Side

    public init(area: Area, side: Side) {
        self.area = area
        self.side = side
    }
}

extension BehaviorEnvironment {
    func area(of border: ShimejiBorder) -> BehaviorArea {
        switch border.area {
        case .workArea: return workArea
        case .activeWindow: return activeWindow
        }
    }

    /// 点是否精确在边上(Shimeji `FloorCeiling/Wall.isOn`:area 可见 + 坐标恰等边值 + 区间内)。
    public func isOn(_ border: ShimejiBorder, _ p: BehaviorPoint) -> Bool {
        let a = area(of: border)
        guard a.visible else { return false }
        let px = Int(p.x.rounded()), py = Int(p.y.rounded())
        switch border.side {
        case .top:
            return py == Int(a.top.rounded()) && Int(a.left.rounded()) <= px && px <= Int(a.right.rounded())
        case .bottom:
            return py == Int(a.bottom.rounded()) && Int(a.left.rounded()) <= px && px <= Int(a.right.rounded())
        case .left:
            return px == Int(a.left.rounded()) && Int(a.top.rounded()) <= py && py <= Int(a.bottom.rounded())
        case .right:
            return px == Int(a.right.rounded()) && Int(a.top.rounded()) <= py && py <= Int(a.bottom.rounded())
        }
    }

    /// 派生 floor(`MascotEnvironment.getFloor`):activeIE 顶边(站窗顶)优先,其次 workArea 底边。
    public func floorBorder(at p: BehaviorPoint) -> ShimejiBorder? {
        let windowTop = ShimejiBorder(area: .activeWindow, side: .top)
        if isOn(windowTop, p) { return windowTop }
        let ground = ShimejiBorder(area: .workArea, side: .bottom)
        if isOn(ground, p) { return ground }
        return nil
    }

    /// 派生 ceiling(`getCeiling`):activeIE 底边优先,其次 workArea 顶边。
    public func ceilingBorder(at p: BehaviorPoint) -> ShimejiBorder? {
        let windowBottom = ShimejiBorder(area: .activeWindow, side: .bottom)
        if isOn(windowBottom, p) { return windowBottom }
        let top = ShimejiBorder(area: .workArea, side: .top)
        if isOn(top, p) { return top }
        return nil
    }

    /// 派生 wall(`getWall`):朝右看 activeIE 左边/workArea 右边,朝左对称。
    public func wallBorder(at p: BehaviorPoint, lookRight: Bool) -> ShimejiBorder? {
        let candidates: [ShimejiBorder] = lookRight
            ? [ShimejiBorder(area: .activeWindow, side: .left), ShimejiBorder(area: .workArea, side: .right)]
            : [ShimejiBorder(area: .activeWindow, side: .right), ShimejiBorder(area: .workArea, side: .left)]
        return candidates.first { isOn($0, p) }
    }

    public func isOnAnyFloor(_ p: BehaviorPoint) -> Bool { floorBorder(at: p) != nil }
    public func isOnAnyWall(_ p: BehaviorPoint, lookRight: Bool) -> Bool { wallBorder(at: p, lookRight: lookRight) != nil }

    /// 解析 BorderType → 当前所站的具体边(BorderedAction.init 的绑定语义)。
    public func resolveBorder(_ type: ShimejiBorderType, at p: BehaviorPoint, lookRight: Bool) -> ShimejiBorder? {
        switch type {
        case .floor: return floorBorder(at: p)
        case .ceiling: return ceilingBorder(at: p)
        case .wall: return wallBorder(at: p, lookRight: lookRight)
        }
    }
}

extension ShimejiBorder {
    /// 边随窗口/区域移动时点的跟随(Shimeji `FloorCeiling.move`/`Wall.move`)。
    /// 位移过大(疑似窗口瞬移)放弃跟随返回原点 —— 水平边 |Δx|≥80 或 Δy>20 或 Δy<−80;
    /// 垂直边 |Δx|≥80 或 |Δy|≥80。区域不可见原样返回。
    public func moved(
        _ p: BehaviorPoint,
        from previous: BehaviorEnvironment,
        to current: BehaviorEnvironment
    ) -> BehaviorPoint {
        let prev = previous.area(of: self)
        let cur = current.area(of: self)
        guard cur.visible else { return p }
        guard prev != cur else { return p }   // 没动

        switch side {
        case .top, .bottom:
            // FloorCeiling:x 按区域水平伸缩重映射,y 平移边的 Δy。
            let prevWidth = prev.width
            guard prevWidth > 0 else { return p }
            let newX = (p.x - prev.left) * cur.width / prevWidth + cur.left
            let edgeDY = (side == .top) ? cur.top - prev.top : cur.bottom - prev.bottom
            let newY = p.y + edgeDY
            let dx = newX - p.x, dy = newY - p.y
            if abs(dx) >= 80 || dy > 20 || dy < -80 { return p }
            return BehaviorPoint(x: newX, y: newY)
        case .left, .right:
            // Wall:y 按区域垂直伸缩重映射,x 平移边的 Δx。
            let prevHeight = prev.height
            guard prevHeight > 0 else { return p }
            let newY = (p.y - prev.top) * cur.height / prevHeight + cur.top
            let edgeDX = (side == .left) ? cur.left - prev.left : cur.right - prev.right
            let newX = p.x + edgeDX
            let dx = newX - p.x, dy = newY - p.y
            if abs(dx) >= 80 || abs(dy) >= 80 { return p }
            return BehaviorPoint(x: newX, y: newY)
        }
    }
}
