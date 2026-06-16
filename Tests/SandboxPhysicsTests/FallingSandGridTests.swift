import Testing
@testable import SandboxPhysics

@Suite("FallingSandGrid 存储")
struct FallingSandGridTests {
    @Test("index 行主序")
    func indexRowMajor() {
        let g = FallingSandGrid(width: 4, height: 3)
        #expect(g.index(0, 0) == 0)
        #expect(g.index(3, 0) == 3)
        #expect(g.index(0, 1) == 4)
        #expect(g.index(2, 2) == 10)
    }

    @Test("初始全空")
    func initiallyEmpty() {
        let g = FallingSandGrid(width: 4, height: 4)
        for c in g.cells { #expect(c == 0) }
    }

    @Test("set / at roundtrip")
    func setAtRoundtrip() {
        var g = FallingSandGrid(width: 4, height: 4)
        let p = FallingSandCell.make(.snow, ra: 50)
        g.set(2, 1, p)
        #expect(g.at(2, 1) == p)
    }

    @Test("越界读返回 wall")
    func outOfBoundsReadsWall() {
        let g = FallingSandGrid(width: 4, height: 4)
        #expect(FallingSandCell.species(g.at(-1, 0)) == .wall)
        #expect(FallingSandCell.species(g.at(0, -1)) == .wall)
        #expect(FallingSandCell.species(g.at(4, 0)) == .wall)
        #expect(FallingSandCell.species(g.at(0, 4)) == .wall)
    }

    @Test("越界写被忽略，不崩")
    func outOfBoundsWriteIgnored() {
        var g = FallingSandGrid(width: 4, height: 4)
        g.set(-1, 0, FallingSandCell.make(.water))   // 不应崩溃
        g.set(99, 99, FallingSandCell.make(.water))
        for c in g.cells { #expect(c == 0) }
    }
}
