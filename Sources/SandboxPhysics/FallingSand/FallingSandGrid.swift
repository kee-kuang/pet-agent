/// Falling-sand 网格存储。行主序 `[UInt32]`，`y=0` 底行，`+y` 朝上。
/// 越界读返回 `wall`（cell 不会移出网格边界）；越界写静默忽略。
public struct FallingSandGrid: Sendable {
    public let width: Int
    public let height: Int
    public var cells: [UInt32]
    /// 每列 cell-y 下限（窗口碰撞）：`y < columnFloor[x]` 的 cell 视为「窗口内部」，
    /// 元素不能落入 → 雪/水堆在窗口顶。默认全 0（无窗口，落到屏底 y=0）。
    public var columnFloor: [Int]

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.cells = [UInt32](repeating: 0, count: width * height)
        self.columnFloor = [Int](repeating: 0, count: width)
    }

    @inline(__always)
    public func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    @inline(__always)
    public func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    @inline(__always)
    public func at(_ x: Int, _ y: Int) -> UInt32 {
        inBounds(x, y) ? cells[index(x, y)] : FallingSandCell.make(.wall)
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ payload: UInt32) {
        if inBounds(x, y) { cells[index(x, y)] = payload }
    }

    /// 该 cell 是否在窗口 floor 之下（不可进入）。越界返回 false（越界由 at() 的
    /// wall 处理）。
    @inline(__always)
    public func belowFloor(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y < columnFloor[x]
    }

    /// 占用 cell 计数（species != empty）。守恒测试用。
    public func occupiedCount() -> Int {
        cells.reduce(0) { $0 + (FallingSandCell.isEmpty($1) ? 0 : 1) }
    }
}
