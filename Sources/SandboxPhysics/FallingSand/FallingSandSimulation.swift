/// Falling-sand CPU 参考引擎编排器。一个 `step` 顺序跑：
///   spawn（外部调用）→ 重力 pass（左右优先级每帧翻转）→ 漫流 pass ×2
///   → 相变（若提供温度场）。clock parity 每帧翻转，供 GPU 端的
///   双 pass 去重；CPU 版顺序执行天然 race-free，clock 仅作 GPU 对拍同步位。
public struct FallingSandSimulation {
    public private(set) var grid: FallingSandGrid
    private var rng: FallingSandRandom
    private var frame: UInt64 = 0

    public init(width: Int, height: Int, seed: UInt64) {
        self.grid = FallingSandGrid(width: width, height: height)
        self.rng = FallingSandRandom(seed: seed)
    }

    /// 直接读写网格（测试 / spawn 用）。
    public mutating func setCell(_ x: Int, _ y: Int, _ p: UInt32) { grid.set(x, y, p) }

    /// 设置每列 floor（cell-y 下限，窗口碰撞）。
    public mutating func setColumnFloor(_ floor: [Int]) {
        precondition(floor.count == grid.width, "floor 数量需等于 width")
        grid.columnFloor = floor
    }

    /// 在顶行（y = height-1）按比例铺元素。fillRatio 1.0 = 铺满。
    public mutating func spawnTopRow(_ s: FallingSandSpecies, fillRatio: Float) {
        let y = grid.height - 1
        for x in 0..<grid.width where rng.unit() < fillRatio {
            grid.set(x, y, FallingSandCell.make(s, ra: UInt8(rng.int(256))))
        }
    }

    /// 只跑确定性移动（gravity forceSnowFall + flowL + flowR，无相变、无概率门）。
    /// 与 `FallingSandGPUEngine.stepMovementOnly()` 语义一一对应，供 GPU 逐格对拍。
    public mutating func stepMovementOnly() {
        let leftFirst = (frame & 1) == 0
        FallingSandMovement.gravityPass(&grid, leftFirst: leftFirst, rng: &rng, snowFallForced: true)
        FallingSandMovement.flowPass(&grid, leftFirst: leftFirst, rng: &rng)
        FallingSandMovement.flowPass(&grid, leftFirst: !leftFirst, rng: &rng)
        frame &+= 1
    }

    /// 推进一帧。`temperatures` 为 nil 时跳过相变（纯移动测试用）。
    public mutating func step(dt: Float, temperatures: [Float]?) {
        let leftFirst = (frame & 1) == 0
        FallingSandMovement.gravityPass(&grid, leftFirst: leftFirst, rng: &rng)
        FallingSandMovement.flowPass(&grid, leftFirst: leftFirst, rng: &rng)
        FallingSandMovement.flowPass(&grid, leftFirst: !leftFirst, rng: &rng)
        if let temps = temperatures {
            FallingSandPhase.apply(&grid, temperatures: temps, dt: dt, rng: &rng)
        }
        frame &+= 1
    }
}
