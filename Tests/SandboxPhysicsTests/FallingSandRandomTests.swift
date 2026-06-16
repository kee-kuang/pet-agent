import Testing
@testable import SandboxPhysics

@Suite("FallingSandRandom 确定性")
struct FallingSandRandomTests {
    @Test("同 seed 产出同序列")
    func sameSeedSameSequence() {
        var a = FallingSandRandom(seed: 0x1234)
        var b = FallingSandRandom(seed: 0x1234)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
    }

    @Test("不同 seed 产出不同序列")
    func differentSeedDiffers() {
        var a = FallingSandRandom(seed: 1)
        var b = FallingSandRandom(seed: 2)
        var anyDiff = false
        for _ in 0..<10 where a.next() != b.next() { anyDiff = true }
        #expect(anyDiff)
    }

    @Test("unit 落在 [0,1)")
    func unitInRange() {
        var r = FallingSandRandom(seed: 42)
        for _ in 0..<1000 {
            let u = r.unit()
            #expect(u >= 0.0)
            #expect(u < 1.0)
        }
    }

    @Test("int(n) 落在 [0,n)")
    func intInRange() {
        var r = FallingSandRandom(seed: 7)
        for _ in 0..<1000 {
            let v = r.int(5)
            #expect(v >= 0)
            #expect(v < 5)
        }
    }
}
