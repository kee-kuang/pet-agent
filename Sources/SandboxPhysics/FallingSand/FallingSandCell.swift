/// Falling-sand cell 的 32-bit payload 编解码。参照 sandspiel 的
/// `Cell { species, ra, rb, clock }` 字节布局重新实现（数据约定，未拷贝源码）：
/// ```
///   byte0 = species | byte1 = ra | byte2 = rb | byte3 = clock
/// ```
/// 全部纯函数（无变更），供 CPU 参考引擎 + 测试使用；GPU 端的 MSL
/// accessor 必须与此逐位一致（GPU 对拍测试做闸）。
public enum FallingSandCell {
    /// 空 cell（species=empty，全 0）。
    public static let empty: UInt32 = 0

    @inline(__always)
    public static func make(_ s: FallingSandSpecies, ra: UInt8 = 0, rb: UInt8 = 0, clock: UInt8 = 0) -> UInt32 {
        UInt32(s.rawValue) | (UInt32(ra) << 8) | (UInt32(rb) << 16) | (UInt32(clock) << 24)
    }

    @inline(__always)
    public static func species(_ p: UInt32) -> FallingSandSpecies {
        FallingSandSpecies(rawValue: UInt8(p & 0xFF)) ?? .empty
    }

    @inline(__always)
    public static func ra(_ p: UInt32) -> UInt8 { UInt8((p >> 8) & 0xFF) }

    @inline(__always)
    public static func rb(_ p: UInt32) -> UInt8 { UInt8((p >> 16) & 0xFF) }

    @inline(__always)
    public static func clock(_ p: UInt32) -> UInt8 { UInt8((p >> 24) & 0xFF) }

    @inline(__always)
    public static func isEmpty(_ p: UInt32) -> Bool { (p & 0xFF) == 0 }

    @inline(__always)
    public static func withClock(_ p: UInt32, _ c: UInt8) -> UInt32 {
        (p & 0x00FF_FFFF) | (UInt32(c) << 24)
    }

    @inline(__always)
    public static func withRb(_ p: UInt32, _ v: UInt8) -> UInt32 {
        (p & 0xFF00_FFFF) | (UInt32(v) << 16)
    }

    @inline(__always)
    public static func withSpecies(_ p: UInt32, _ s: FallingSandSpecies) -> UInt32 {
        (p & 0xFFFF_FF00) | UInt32(s.rawValue)
    }
}
