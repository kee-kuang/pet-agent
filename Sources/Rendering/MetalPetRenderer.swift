import AppKit
import Metal
import QuartzCore

// MARK: - MetalPetRenderer
//
// 所有「Metal SDF 程序化形象」的共享基类 —— 从 OrbMetalRenderer / SlimeMetalRenderer
// 抽出逐字重复的样板（CAMetalLayer 装配 / CVDisplayLink 心跳 / 30Hz frame-skip /
// pipeline 创建 / tickAndRender 前后处理 / LifeSigns 体积呼吸 / perf log / layer-backed
// hosting view）。子类只需提供：
//   - `shaderSource` / `vertexFunctionName` / `fragmentFunctionName`（class var，
//     基类 init 用 `Self.xxx` 解析到子类的覆写）。
//   - `encodeFrame(...)`：在 `setRenderPipelineState` 与 `drawPrimitives(3)` 之间，
//     设自己的 fragment uniforms / 绑定自己的纹理。
//   - 按需覆写 `updateForState` / `updateForVelocity` / `supportedSignatures` / `trigger`。
//
// **init 顺序契约**：基类 init **不**启动 display link（保留「设备资源创建失败先于渲染
// 启动」的语义）。子类在 `super.init` 之后创建自己的设备相关资源、失败则 `return nil`，
// 全部就绪后调 `startRenderLoop()`。
//
// 无 Metal 设备 / 编译失败 → `init?` 返回 nil，Plugin Registry 让 Shell fallback 到 placeholder。

@MainActor
open class MetalPetRenderer: PetRenderer {

    // MARK: - Public (PetRenderer)

    public var contentLayer: CALayer { metalLayer }

    // MARK: - 子类可读的 Metal 资源

    public final let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let metalLayer: CAMetalLayer

    // MARK: - Display link / 帧节流

    private var displayLink: CVDisplayLink?
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    /// CVDisplayLink 跑显示器原生刷新率（60/120Hz）；隔帧跳过把渲染压到 30Hz 上限，
    /// 大幅降低 main-actor 压力（多个形象 + 30Hz app 帧循环时整 app 会卡）。
    private var renderFrameCounter: UInt64 = 0
    private static let renderFrameStride: UInt64 = 2

    /// Perf 诊断：`tickAndRender` 墙钟时间滚动均值（ms），`PETAGENT_PERF_LOG=1` 时每 ~30 帧打一行。
    public static var logPerf: Bool = ProcessInfo.processInfo.environment["PETAGENT_PERF_LOG"] == "1"
    private var perfFrameCounter: UInt64 = 0
    private var perfAccumulatedMs: Double = 0

    // MARK: - 子类提供的 pipeline 标识（class var → 基类 init 经 `Self` 解析到子类覆写）

    open nonisolated class var shaderSource: String { "" }
    open nonisolated class var vertexFunctionName: String { "pet_vertex" }
    open nonisolated class var fragmentFunctionName: String { "pet_fragment" }

    // MARK: - 子类 hook

    /// 每渲染帧调一次，在 `setRenderPipelineState` 与 `drawPrimitives(3)` 之间。
    /// 子类在此 `setFragmentBytes(自己的 uniforms)` + 按需 `setFragmentTexture/SamplerState`。
    /// `breathScale` 是 LifeSigns 体积呼吸倍率（基类统一算好），`dt` 供需要 ease 的子类用。
    open func encodeFrame(
        encoder: MTLRenderCommandEncoder,
        elapsed: Float,
        dt: Float,
        aspect: Float,
        breathScale: Float
    ) {}

    // MARK: - PetRenderer（子类按需覆写）

    open func updateForState(_ state: PetEmotionState) {}
    open func updateForVelocity(_ velocity: CGVector) {}
    open var supportedSignatures: Set<SignatureAction> { [] }
    open func trigger(_ signature: SignatureAction) {}

    // MARK: - Init

    /// 装配 device / queue / pipeline / CAMetalLayer / hosting view。**不**启动 display link。
    public init?(
        device candidate: MTLDevice? = MTLCreateSystemDefaultDevice(),
        initialSize: NSSize = NSSize(width: 64, height: 64)
    ) {
        guard
            let device = candidate,
            let queue = device.makeCommandQueue(),
            let pipeline = Self.makePipeline(
                device: device,
                source: Self.shaderSource,
                vertexName: Self.vertexFunctionName,
                fragmentName: Self.fragmentFunctionName
            )
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline

        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = false
        layer.presentsWithTransaction = false
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.metalLayer = layer
    }

    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }

    // MARK: - Display link 生命周期（final）

    /// 子类在自己的资源全部就绪后调用，启动渲染心跳。
    public final func startRenderLoop() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            // 基类指针：任何子类实例都是 MetalPetRenderer，takeUnretainedValue 取到动态类型。
            let renderer = Unmanaged<MetalPetRenderer>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                renderer.tickAndRender()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    public final func pauseDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    public final func resumeDisplayLink() {
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    // MARK: - 帧循环（final，公共前后处理）

    private func tickAndRender() {
        // 30Hz frame-skip gate。
        renderFrameCounter &+= 1
        guard renderFrameCounter % Self.renderFrameStride == 0 else { return }

        let perfStart = Self.logPerf ? CACurrentMediaTime() : 0
        let now = CACurrentMediaTime()
        let dt = Float(max(0.0, now - lastFrameTime))
        lastFrameTime = now

        // drawableSize 跟 view bounds（像素）同步。
        let viewSize = metalLayer.bounds.size
        let scale = metalLayer.contentsScale
        let drawableSize = CGSize(
            width: max(1.0, viewSize.width * scale),
            height: max(1.0, viewSize.height * scale)
        )
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }

        guard
            let drawable = metalLayer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipelineState)

        let elapsed = Float(now - startTime)
        let aspect = Float(drawableSize.height > 0 ? drawableSize.width / drawableSize.height : 1.0)
        // LifeSigns 体积呼吸：正弦振荡 SDF radius 倍率，跟五态切换正交（连续叠加）。
        let breathPhase = sinf(elapsed * 2.0 * .pi / Float(LifeSignsTokens.breathPeriod))
        let breathScale = 1.0 + breathPhase * LifeSignsTokens.breathAmplitude

        encodeFrame(encoder: encoder, elapsed: elapsed, dt: dt, aspect: aspect, breathScale: breathScale)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if Self.logPerf {
            let elapsedMs = (CACurrentMediaTime() - perfStart) * 1000.0
            perfFrameCounter &+= 1
            perfAccumulatedMs += elapsedMs
            if perfFrameCounter % 30 == 0 {
                let avg = perfAccumulatedMs / Double(perfFrameCounter)
                fputs("[\(type(of: self))Perf] avg=\(String(format: "%.2f", avg))ms over \(perfFrameCounter) frames\n", stderr)
                perfAccumulatedMs = 0
                perfFrameCounter = 0
            }
        }
    }

    // MARK: - Pipeline factory（共享：premultiplied straight-alpha blend，全屏三角形顶点）

    public static func makePipeline(
        device: MTLDevice,
        source: String,
        vertexName: String,
        fragmentName: String
    ) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        guard
            let vert = library.makeFunction(name: vertexName),
            let frag = library.makeFunction(name: fragmentName)
        else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
}
