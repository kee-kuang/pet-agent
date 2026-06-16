import Testing
import simd
@testable import SandboxPhysics

@Suite("FallingSandCell payload")
struct FallingSandCellTests {
    @Test("empty 是全 0")
    func emptyIsZero() {
        #expect(FallingSandCell.empty == 0)
        #expect(FallingSandCell.species(0) == .empty)
        #expect(FallingSandCell.isEmpty(0))
    }

    @Test("四字段 roundtrip")
    func roundtrip() {
        let p = FallingSandCell.make(.water, ra: 137, rb: 42, clock: 1)
        #expect(FallingSandCell.species(p) == .water)
        #expect(FallingSandCell.ra(p) == 137)
        #expect(FallingSandCell.rb(p) == 42)
        #expect(FallingSandCell.clock(p) == 1)
        #expect(!FallingSandCell.isEmpty(p))
    }

    @Test("withClock 只改 clock 字节")
    func withClockPreservesRest() {
        let p = FallingSandCell.make(.snow, ra: 200, rb: 5, clock: 0)
        let q = FallingSandCell.withClock(p, 1)
        #expect(FallingSandCell.clock(q) == 1)
        #expect(FallingSandCell.species(q) == .snow)
        #expect(FallingSandCell.ra(q) == 200)
        #expect(FallingSandCell.rb(q) == 5)
    }

    @Test("withRb 只改 rb 字节")
    func withRbPreservesRest() {
        let p = FallingSandCell.make(.steam, ra: 9, rb: 0, clock: 3)
        let q = FallingSandCell.withRb(p, 99)
        #expect(FallingSandCell.rb(q) == 99)
        #expect(FallingSandCell.species(q) == .steam)
        #expect(FallingSandCell.ra(q) == 9)
        #expect(FallingSandCell.clock(q) == 3)
    }
}
