import Foundation

// sprite 包几何 —— 8 列固定、petdex cell 192×208(宽×高)固定,故 sheet 行数可由尺寸反推。
// renderer / loader 缩略图 / Shimeji packer 共用,避免「行数」写死多处漂移。
//
// 为何按几何推而非读 pet.json:社区 petdex 包从不声明行数,几何推对它们也成立,无需打通元数据管线。
// **保守**:仅当尺寸严丝合缝匹配 ≥10 行(192×208 比例)时才返回该值,否则一律回退 9 ——
// 任何非标准 cell 比例 / 经典 8×9 包都安全走 9(与旧写死 rows=9 逐像素一致,零回归)。
public enum SpritePackGeometry {
    public static let cols = 8
    public static let defaultRows = 9
    /// cell 高/宽 = 208/192。
    private static let cellAspect = 208.0 / 192.0

    /// 按 8 列 + 192×208 比例推行数。只接受严丝合缝的 ≥10(带 climb 等扩展行),否则回退 9。
    public static func rows(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return defaultRows }
        let cellW = Double(width) / Double(cols)
        let implied = Double(height) / (cellW * cellAspect)
        let rounded = implied.rounded()
        if rounded >= 10, abs(implied - rounded) < 0.12 { return Int(rounded) }
        return defaultRows
    }
}
