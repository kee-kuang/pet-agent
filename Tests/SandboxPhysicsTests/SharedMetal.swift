import Metal

/// Shared Metal `MTLDevice` and `MTLCommandQueue` for the SandboxPhysics test target.
///
/// 与 `RenderingTests/SharedMetal.swift` 是有意的双份拷贝 —— 两个 test target 各自
/// 需要进程级共享 Metal 设备,而 test target 之间无法共享 internal 符号(各自独立模块)。
/// 这是个 34 行、几乎不变的稳定 helper,复制比为它单建 public 的 TestSupport target 更轻。
/// 若将来出现多个跨 test target 共享的 helper,再抽 TestSupport target 收口。
///
/// Why a shared device / queue?
///
/// `MTLCreateSystemDefaultDevice()` plus the first kernel compilation is expensive
/// (~1–3s per fresh device on Apple Silicon when the Metal pipeline cache is cold).
/// Creating a brand new device for every single test multiplied that cost by 30+
/// across the physics suite, dominating overall `swift test` wall time.
///
/// Swift Testing has no `setUp/tearDown` — every test gets a fresh suite instance —
/// so we keep the device on a top-level `let` that the Swift runtime initialises
/// exactly once per test process. Subsequent accesses are O(1).
///
/// On headless CI without GPU access, both properties resolve to `nil` and tests
/// already use `try #require(SharedMetal.device)` to early-skip cleanly.
enum SharedMetal {
    /// Process-wide singleton Metal device — created exactly once on first
    /// access, reused by every physics test thereafter.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Process-wide singleton command queue paired with `device`.
    static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()
}
