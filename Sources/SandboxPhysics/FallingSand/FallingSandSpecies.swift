import simd

/// Falling-sand 元素种类。rawValue 直接进 cell payload 的 byte 0。
/// 0-5 是 Phase 1 天气元素；6-255 留给 Phase 2（沙/火/油/植物…）。
public enum FallingSandSpecies: UInt8, CaseIterable, Sendable {
    case empty = 0
    case wall = 1   // 留给后续 pet body mask；窗口碰撞用按列 floor buffer，不用 wall
    case snow = 2
    case water = 3
    case ice = 4
    case steam = 5

    /// 是否参与重力下落（snow/water）。ice 静态，steam 反重力，empty/wall 不动。
    public var fallsDown: Bool { self == .snow || self == .water }

    /// 是否是液体（参与水平漫流）。
    public var isLiquid: Bool { self == .water }

    /// 是否反重力上升（steam）。
    public var risesUp: Bool { self == .steam }
}

/// 每个元素的基色（RGBA, 0..1）。渲染时叠 `ra` 变体微抖动，避免像素场死板。
public enum FallingSandPalette {
    public static func baseColor(_ s: FallingSandSpecies) -> SIMD4<Float> {
        switch s {
        case .empty:  return SIMD4<Float>(0, 0, 0, 0)
        case .wall:   return SIMD4<Float>(0.30, 0.30, 0.34, 1)
        case .snow:   return SIMD4<Float>(0.95, 0.96, 0.99, 1)
        case .water:  return SIMD4<Float>(0.26, 0.52, 0.92, 0.92)
        case .ice:    return SIMD4<Float>(0.72, 0.85, 0.95, 1)
        case .steam:  return SIMD4<Float>(0.85, 0.88, 0.92, 0.45)
        }
    }

    /// 用 cell 的 `ra`（0..255）对基色做亮度微抖动（±6%），返回最终颜色。
    public static func shaded(_ s: FallingSandSpecies, ra: UInt8) -> SIMD4<Float> {
        let base = baseColor(s)
        let jitter = 0.94 + (Float(ra) / 255.0) * 0.12   // 0.94..1.06
        return SIMD4<Float>(base.x * jitter, base.y * jitter, base.z * jitter, base.w)
    }
}
