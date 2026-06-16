import Testing
@testable import Rendering

@Suite("SpritePackGeometry —— sheet 行数几何推导(climb 行)")
struct SpritePackGeometryTests {

    @Test("经典 8×9(192×208)→ 9")
    func classicNine() {
        #expect(SpritePackGeometry.rows(width: 1536, height: 1872) == 9)   // 8*192 × 9*208
    }

    @Test("8×10(192×208,含 climb)→ 10")
    func tenWithClimb() {
        #expect(SpritePackGeometry.rows(width: 1536, height: 2080) == 10)  // 8*192 × 10*208
    }

    @Test("等比缩放 8×9 → 9 / 8×10 → 10")
    func scaled() {
        #expect(SpritePackGeometry.rows(width: 96, height: 117) == 9)      // 8*12 × 9*13
        #expect(SpritePackGeometry.rows(width: 96, height: 130) == 10)     // 8*12 × 10*13
    }

    @Test("非标准 cell 比例(非 192×208)→ 回退 9(零回归保护,不误判成 10+)")
    func nonStandardFallsBack() {
        // 9 行但 cell 高 260 → 几何推 11.25,不严丝合缝(>0.12)→ 回退 defaultRows。
        #expect(SpritePackGeometry.rows(width: 1536, height: 9 * 260) == 9)
    }

    @Test("异常尺寸 → 回退 9")
    func degenerate() {
        #expect(SpritePackGeometry.rows(width: 0, height: 100) == 9)
        #expect(SpritePackGeometry.rows(width: 100, height: 0) == 9)
    }
}
