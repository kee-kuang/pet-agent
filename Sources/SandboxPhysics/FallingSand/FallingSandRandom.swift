/// 确定性 SplitMix64 RNG（参照 sandspiel 用到的 rand_xoshiro SplitMix64 算法重新实现，未拷贝源码）。
/// 值类型 → 每个 cell / 每帧可携带独立 seed 复现。GPU 端的 MSL hash 必须
/// 与此一致才能通过 GPU 对拍。
public struct FallingSandRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    @inline(__always)
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 的 Float（24-bit 尾数）。
    @inline(__always)
    public mutating func unit() -> Float {
        Float(next() >> 40) * (1.0 / Float(1 << 24))
    }

    /// [0, n) 的 Int。n 必须 > 0。
    @inline(__always)
    public mutating func int(_ n: Int) -> Int {
        precondition(n > 0, "int(n) 需要 n > 0")
        return Int(next() % UInt64(n))
    }

    @inline(__always)
    public mutating func bool() -> Bool { (next() & 1) == 0 }
}
