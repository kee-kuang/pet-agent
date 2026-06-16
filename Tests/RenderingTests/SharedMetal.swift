import Metal

/// Shared Metal `MTLDevice` and `MTLCommandQueue` for the rendering test target.
///
/// Why a shared device / queue?
///
/// `MTLCreateSystemDefaultDevice()` plus the first kernel compilation is expensive
/// (~1–3s per fresh device on Apple Silicon when the Metal pipeline cache is cold).
/// Creating a brand new device for every single test multiplied that cost by 30+
/// across the rendering suite, dominating overall `swift test` wall time.
///
/// Swift Testing has no `setUp/tearDown` — every test gets a fresh suite instance —
/// so we keep the device on a top-level `let` that the Swift runtime initialises
/// exactly once per test process. Subsequent accesses are O(1).
///
/// Tests that genuinely need a freshly created device (for example, exercising
/// the "device init returned nil" path on headless CI) MUST call
/// `MTLCreateSystemDefaultDevice()` directly and add a comment explaining why a
/// shared device is unsuitable.
///
/// On headless CI without GPU access, both properties resolve to `nil` and tests
/// already use `try #require(SharedMetal.device)` to early-skip cleanly.
enum SharedMetal {
    /// Process-wide singleton Metal device — created exactly once on first
    /// access, reused by every rendering test thereafter.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Process-wide singleton command queue paired with `device`.
    ///
    /// Command queues are cheap to create relative to device + pipeline state,
    /// but reusing one across tests is still strictly faster and matches how
    /// the app uses a single long-lived queue at runtime.
    static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()
}
