import AppKit
import Metal
import MetalKit
import QuartzCore
// FallingSand 物理引擎(雪/雨/水/冰/汽 统一元胞自动机)已分出独立 SandboxPhysics
// target;此处 @_exported 再导出,让现有 `import Rendering` 的宿主(Shell/App)无需
// 改动即可继续用 FallingSandDriver 等类型(透明再导出,零调用方改动)。
@_exported import SandboxPhysics

/// 桌面雪 overlay 的 MTKView 宿主。**falling-sand CA 是唯一雪路径**（旧 GPU 粒子雪
/// 已移除）：`enableFallingSandMode` 按 overlay bounds + cellSize 建 FallingSandDriver，
/// `tickFallingSand` 每帧按天气写 spawn/温度/窗口遮挡矩形，`encodeFrame` 把 driver
/// 渲染（CA 积雪 + 飞行粒子两层）到 drawable。
@MainActor
public final class MetalSnowOverlayView: MTKView {
    private let renderCommandQueue: MTLCommandQueue

    public private(set) var fallingSandDriver: FallingSandDriver?
    public var useFallingSandMode: Bool = false

    public static func make(frame: CGRect) -> MetalSnowOverlayView? {
        guard
            let metalDevice = MTLCreateSystemDefaultDevice(),
            let queue = metalDevice.makeCommandQueue()
        else {
            return nil
        }
        return MetalSnowOverlayView(frame: frame, metalDevice: metalDevice, commandQueue: queue)
    }

    private init(frame: CGRect, metalDevice: MTLDevice, commandQueue: MTLCommandQueue) {
        self.renderCommandQueue = commandQueue
        super.init(frame: frame, device: metalDevice)
        configureView()
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func configureView() {
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
    }

    /// 挂载 falling-sand CA driver。需配合 `useFallingSandMode = true` 才渲染。
    public func attachFallingSandDriver(_ driver: FallingSandDriver?) {
        fallingSandDriver = driver
    }

    /// 开启 falling-sand 模式：按 overlay 当前 bounds + cellSize 建 driver（用本
    /// view 自己的 MTLDevice，保证与 drawable 同 device），切到该路径。幂等。
    @discardableResult
    public func enableFallingSandMode(cellSize: Float) -> Bool {
        if fallingSandDriver == nil {
            guard let device = self.device, let queue = device.makeCommandQueue() else { return false }
            let w = max(1, Int(bounds.width / CGFloat(cellSize)))
            let h = max(1, Int(bounds.height / CGFloat(cellSize)))
            guard let driver = FallingSandDriver(
                device: device, queue: queue,
                gridWidth: w, gridHeight: h,
                pixelFormat: colorPixelFormat
            ) else { return false }
            fallingSandDriver = driver
        }
        useFallingSandMode = true
        isHidden = false
        setNeedsDisplay(bounds)
        return true
    }

    public func disableFallingSandMode() {
        useFallingSandMode = false
        setNeedsDisplay(bounds)
    }

    /// 清场：清空 falling-sand 网格（清除积雪）。
    public func clearFallingSand() {
        fallingSandDriver?.clear()
        setNeedsDisplay(bounds)
    }

    /// 当前 falling-sand 网格尺寸（app 算窗口遮挡矩形用）。
    public var fallingSandGridSize: (width: Int, height: Int)? {
        fallingSandDriver.map { ($0.gridWidth, $0.gridHeight) }
    }

    /// 设置可调物理参数（设置 → 调试 面板）。driver 每帧 apply，实时生效。
    public func setFallingSandTuning(_ tuning: FallingSandTuning) {
        fallingSandDriver?.tuning = tuning
    }

    /// 每帧按天气写 spawn/温度 + 窗口遮挡矩形（cell 坐标 x,y,w,h）并触发重绘。
    public func tickFallingSand(spawnSnow: Bool, spawnRain: Bool, ambient: Float, rects: [SIMD4<Float>]) {
        guard useFallingSandMode, let driver = fallingSandDriver else { return }
        driver.spawnSnow = spawnSnow
        driver.spawnRain = spawnRain
        driver.ambientTemperature = ambient
        driver.pendingRects = rects.map { FSRect(x: $0.x, y: $0.y, w: $0.z, h: $0.w) }
        setNeedsDisplay(bounds)
    }

    /// 上传 pet 当前帧 alpha occluder（雪堆 pet 身上）。`mask` nil = 关。
    /// app 每帧在 tickFallingSand 同节奏调（pet 移动/换帧 → 每帧重栅格化，雪随之响应）。
    public func uploadPetOccluder(_ mask: PetAlphaMask?, originCellX: Int, originCellY: Int) {
        guard let driver = fallingSandDriver else { return }
        driver.pendingPetOccluder = mask.map {
            FallingSandDriver.PetOccluderFrame(
                mask: $0.mask, width: $0.width, height: $0.height,
                originCellX: originCellX, originCellY: originCellY)
        }
    }

    /// 上传 pet 扬雪（AABB cell + 横速度）。`sweep` nil = 关。
    public func uploadPetSweep(_ sweep: FallingSandDriver.PetSweepFrame?) {
        fallingSandDriver?.pendingPetSweep = sweep
    }

    public override func draw(_ dirtyRect: CGRect) {
        guard
            let descriptor = currentRenderPassDescriptor,
            let drawable = currentDrawable,
            let commandBuffer = renderCommandQueue.makeCommandBuffer()
        else {
            return
        }
        encodeFrame(into: commandBuffer, renderPassDescriptor: descriptor)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public func encodeFrame(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        guard useFallingSandMode, let fsDriver = fallingSandDriver else { return }
        fsDriver.tick(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor,
            dt: 1.0 / 60.0
        )
    }
}
