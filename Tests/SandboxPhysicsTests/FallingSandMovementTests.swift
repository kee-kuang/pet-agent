import Testing
@testable import SandboxPhysics

@Suite("FallingSandMovement 重力 pass")
struct FallingSandMovementFallTests {
    /// 在 (x,y) 放一个元素。
    func grid(_ w: Int, _ h: Int, _ place: [(Int, Int, FallingSandSpecies)]) -> FallingSandGrid {
        var g = FallingSandGrid(width: w, height: h)
        for (x, y, s) in place { g.set(x, y, FallingSandCell.make(s, ra: 100)) }
        return g
    }

    @Test("单个雪 cell 下落一格")
    func singleSnowFalls() {
        var g = grid(3, 3, [(1, 2, .snow)])
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        #expect(FallingSandCell.species(g.at(1, 2)) == .empty)
        #expect(FallingSandCell.species(g.at(1, 1)) == .snow)
    }

    @Test("落到底行停住")
    func restsOnFloor() {
        var g = grid(3, 1, [(1, 0, .snow)])
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        #expect(FallingSandCell.species(g.at(1, 0)) == .snow)
    }

    @Test("下方被占 → 不下落（无对角空位时）")
    func blockedBelowStays() {
        // 三列全堵在底，雪在 (1,1) 上方，下/下左/下右都堵
        var g = grid(3, 2, [(0, 0, .ice), (1, 0, .ice), (2, 0, .ice), (1, 1, .snow)])
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        #expect(FallingSandCell.species(g.at(1, 1)) == .snow)
    }

    @Test("质量守恒：纯移动后占用数不变")
    func massConserved() {
        var g = FallingSandGrid(width: 8, height: 8)
        var seed = FallingSandRandom(seed: 99)
        for _ in 0..<20 {
            let x = seed.int(8), y = seed.int(8)
            g.set(x, y, FallingSandCell.make(.snow, ra: UInt8(seed.int(256))))
        }
        let before = g.occupiedCount()
        var rng = FallingSandRandom(seed: 5)
        for _ in 0..<30 {
            FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        }
        #expect(g.occupiedCount() == before)
    }

    @Test("无复制：两个源争一个空位只有一个成功")
    func noDuplicationUnderContention() {
        // (0,1) 和 (2,1) 两个雪，都想走对角到 (1,0)；(1,1) 也是雪走直下到 (1,0)
        // 验证 (1,0) 最终只被一个占据，且总占用数守恒
        var g = grid(3, 2, [(0, 1, .snow), (1, 1, .snow), (2, 1, .snow)])
        let before = g.occupiedCount()
        var rng = FallingSandRandom(seed: 3)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        #expect(g.occupiedCount() == before)
    }
}

@Suite("FallingSandMovement 堆积坡形")
struct FallingSandMovementSlopeTests {
    @Test("尖顶雪会向对角下滑")
    func peakSlidesDiagonally() {
        // 底行全堵，(1,1) 上有一颗雪，(0,0)/(2,0) 空 → 应能下滑到对角
        var g = FallingSandGrid(width: 3, height: 2)
        g.set(1, 0, FallingSandCell.make(.ice))   // (1,1) 正下方堵
        g.set(1, 1, FallingSandCell.make(.snow, ra: 100))
        var rng = FallingSandRandom(seed: 2)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
        // 直下堵 → 走对角到 (0,0) 或 (2,0)
        let landed = FallingSandCell.species(g.at(0, 0)) == .snow
                  || FallingSandCell.species(g.at(2, 0)) == .snow
        #expect(landed)
        #expect(FallingSandCell.species(g.at(1, 1)) == .empty)
    }

    @Test("一柱雪塌成有界坡（不堆成一柱）")
    func columnCollapsesToSlope() {
        // 在 11 宽网格中间叠 6 高一柱雪，跑足够多帧，断言底层铺开 > 1 格宽
        var g = FallingSandGrid(width: 11, height: 8)
        for y in 0..<6 { g.set(5, y, FallingSandCell.make(.snow, ra: 100)) }
        var rng = FallingSandRandom(seed: 11)
        for _ in 0..<60 {
            FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
            FallingSandMovement.gravityPass(&g, leftFirst: false, rng: &rng, snowFallForced: true)
        }
        // 底行占用宽度应 > 1（塌开了）
        var bottomWidth = 0
        for x in 0..<11 where !FallingSandCell.isEmpty(g.at(x, 0)) { bottomWidth += 1 }
        #expect(bottomWidth > 1)
        // 守恒：6 颗还在
        #expect(g.occupiedCount() == 6)
    }
}

@Suite("FallingSandMovement 水漫流")
struct FallingSandMovementFlowTests {
    @Test("一堆水向两侧漫开找平")
    func waterSpreadsLevel() {
        // 底行中间堆 3 格高的水柱，跑重力 + 漫流，断言底行水变宽
        var g = FallingSandGrid(width: 9, height: 5)
        for y in 0..<3 { g.set(4, y, FallingSandCell.make(.water, ra: 80)) }
        var rng = FallingSandRandom(seed: 21)
        for _ in 0..<50 {
            FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng)
            FallingSandMovement.flowPass(&g, leftFirst: true, rng: &rng)
            FallingSandMovement.flowPass(&g, leftFirst: false, rng: &rng)
        }
        var bottomWidth = 0
        for x in 0..<9 where FallingSandCell.species(g.at(x, 0)) == .water { bottomWidth += 1 }
        #expect(bottomWidth >= 3)         // 至少铺开
        #expect(g.occupiedCount() == 3)   // 守恒
    }

    @Test("雪不参与水平漫流")
    func snowDoesNotFlow() {
        var g = FallingSandGrid(width: 5, height: 1)
        g.set(2, 0, FallingSandCell.make(.snow, ra: 100))
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.flowPass(&g, leftFirst: true, rng: &rng)
        #expect(FallingSandCell.species(g.at(2, 0)) == .snow)   // 没动
    }
}

@Suite("FallingSandMovement 堆积对称性")
struct FallingSandMovementSymmetryTests {
    /// 中心丢一柱雪，跑塌落，量最终雪堆质心 x 是否偏离中心（诊断 tie-break 单向偏置）。
    @Test("中心雪柱塌成对称堆（质心不偏）")
    func centerColumnCollapsesSymmetric() {
        let w = 81, h = 40   // 奇数宽，中心 = 40
        let cx = w / 2
        var g = FallingSandGrid(width: w, height: h)
        for y in 0..<30 { g.set(cx, y, FallingSandCell.make(.snow, ra: 100)) }
        var rng = FallingSandRandom(seed: 7)
        for f in 0..<400 {
            let leftFirst = (f & 1) == 0
            FallingSandMovement.gravityPass(&g, leftFirst: leftFirst, rng: &rng, snowFallForced: true)
        }
        // 质心 x
        var sumX = 0, n = 0
        for y in 0..<h {
            for x in 0..<w where FallingSandCell.species(g.at(x, y)) == .snow { sumX += x; n += 1 }
        }
        #expect(n > 0)
        let comX = Double(sumX) / Double(n)
        let offset = abs(comX - Double(cx))
        print("[FS-SYM] 雪堆质心 x=\(String(format: "%.2f", comX))，中心 \(cx)，偏移 \(String(format: "%.2f", offset)) cell")
        // 对称：质心偏离中心 < 2 cell（min-index 偏置会让它显著偏一侧）
        #expect(offset < 2.0)
    }
}

@Suite("FallingSandMovement 窗口 floor 碰撞")
struct FallingSandMovementFloorTests {
    @Test("雪堆在 floor 线上，floor 下无雪")
    func snowRestsOnFloor() {
        var g = FallingSandGrid(width: 9, height: 12)
        g.columnFloor = [Int](repeating: 4, count: 9)   // 全列 floor = 4
        // 顶部撒一柱雪
        for y in 8..<12 { g.set(4, y, FallingSandCell.make(.snow, ra: 100)) }
        let before = g.occupiedCount()
        var rng = FallingSandRandom(seed: 5)
        for _ in 0..<60 {
            FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true)
            FallingSandMovement.gravityPass(&g, leftFirst: false, rng: &rng, snowFallForced: true)
        }
        // floor 下（y < 4）必须无雪
        for y in 0..<4 {
            for x in 0..<9 { #expect(FallingSandCell.isEmpty(g.at(x, y))) }
        }
        // floor 线 y=4 有雪（堆住了）
        var floorRowSnow = 0
        for x in 0..<9 where FallingSandCell.species(g.at(x, 4)) == .snow { floorRowSnow += 1 }
        #expect(floorRowSnow > 0)
        // 守恒
        #expect(g.occupiedCount() == before)
    }

    @Test("floor=0 时雪落到屏底（回归：默认无窗口）")
    func zeroFloorRestsAtBottom() {
        var g = FallingSandGrid(width: 5, height: 8)
        // columnFloor 默认全 0
        g.set(2, 7, FallingSandCell.make(.snow, ra: 100))
        var rng = FallingSandRandom(seed: 1)
        for _ in 0..<20 { FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng, snowFallForced: true) }
        #expect(FallingSandCell.species(g.at(2, 0)) == .snow)   // 落到 y=0
    }
}

@Suite("FallingSandMovement 蒸汽上升")
struct FallingSandMovementSteamTests {
    @Test("蒸汽向上移动")
    func steamRises() {
        var g = FallingSandGrid(width: 3, height: 3)
        g.set(1, 0, FallingSandCell.make(.steam, ra: 100))
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng)
        #expect(FallingSandCell.species(g.at(1, 0)) == .empty)
        #expect(FallingSandCell.species(g.at(1, 1)) == .steam)
    }

    @Test("蒸汽升到顶停住")
    func steamRestsAtCeiling() {
        var g = FallingSandGrid(width: 3, height: 1)
        g.set(1, 0, FallingSandCell.make(.steam, ra: 100))
        var rng = FallingSandRandom(seed: 1)
        FallingSandMovement.gravityPass(&g, leftFirst: true, rng: &rng)
        #expect(FallingSandCell.species(g.at(1, 0)) == .steam)   // 顶就是 height-1
    }
}
