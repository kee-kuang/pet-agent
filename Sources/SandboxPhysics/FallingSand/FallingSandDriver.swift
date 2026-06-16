import Metal
import Foundation

/// 把 falling-sand 混合雪（飞行粒子 + 落地 CA）接到 overlay 渲染循环。
/// `tick` 编排一帧：emit 粒子 → 积分（亚像素）→ 落地沉积到 CA → CA step（堆积/相变/
/// H1 平衡）→ 渲染（CA 积雪 fragment + 粒子 instanced 叠加）。
///
/// 各子系统用各自 queue commit+wait（实测 1px step 1.85ms + 粒子廉价，总 <3ms，
/// 远低于 16ms 预算，故不做 triple-buffer 非阻塞重写——见 H0 实测）。
@MainActor
public final class FallingSandDriver {
    public let engine: FallingSandGPUEngine
    public let particles: FallingSandParticles
    private let renderPipeline: FallingSandRenderPipeline
    private let particleRenderPipeline: FallingSandParticleRenderPipeline
    public let gridWidth: Int
    public let gridHeight: Int
    public private(set) var tickCount: Int = 0

    /// 每帧 spawn / 温度参数（由 app 层每帧按天气写）。
    public var spawnSnow: Bool = false
    public var spawnRain: Bool = false
    public var ambientTemperature: Float = 0.33   // 默认偏冷，雪不立刻融
    /// 可调物理参数（密度/风/重力/大小/上限/相变/升华）。设置 → 调试 面板实时改，
    /// 每帧 apply 到 particles / engine。`ambientOverride >= 0` 时无视天气温度。
    public var tuning = FallingSandTuning()
    /// 待上传的窗口遮挡矩形（cell 坐标）。app 每帧按窗口算好塞进来，引擎栅格化成 mask。
    public var pendingRects: [FSRect]?
    /// 待上传的 pet occluder（当前帧 alpha mask + 占位 cell 原点）。
    /// app 每帧按 pet 世界位置 + 当前帧算好塞进来；nil = 关 occluder（无雪/Orb 形象）。
    public var pendingPetOccluder: PetOccluderFrame?

    /// pet occluder 一帧上传包（mask + footprint cell 原点）。mask row 0 = sprite 顶部。
    public struct PetOccluderFrame: Sendable {
        public let mask: [UInt8]
        public let width: Int
        public let height: Int
        public let originCellX: Int
        public let originCellY: Int
        public init(mask: [UInt8], width: Int, height: Int, originCellX: Int, originCellY: Int) {
            self.mask = mask; self.width = width; self.height = height
            self.originCellX = originCellX; self.originCellY = originCellY
        }
    }

    /// 待应用的 pet 扬雪（AABB cell + 横速度）。nil = 关（无雪/pet 静止/Orb）。
    public var pendingPetSweep: PetSweepFrame?

    /// pet 扬雪一帧包（AABB cell 坐标 + 横向速度 cell/s 带符号）。
    public struct PetSweepFrame: Sendable {
        public let minX: Float, minY: Float, maxX: Float, maxY: Float
        public let velX: Float
        public init(minX: Float, minY: Float, maxX: Float, maxY: Float, velX: Float) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY; self.velX = velX
        }
    }
    /// 积水湿亮 sheen 强度（0..1）。每帧朝目标（下雨=1，停雨=wetnessBaseline）lerp，
    /// 平滑过渡传给 CA 渲染（避免雨开关瞬间硬切）。
    public private(set) var wetness: Float = 0

    public init(
        engine: FallingSandGPUEngine,
        particles: FallingSandParticles,
        renderPipeline: FallingSandRenderPipeline,
        particleRenderPipeline: FallingSandParticleRenderPipeline,
        gridWidth: Int,
        gridHeight: Int
    ) {
        self.engine = engine
        self.particles = particles
        self.renderPipeline = renderPipeline
        self.particleRenderPipeline = particleRenderPipeline
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    public convenience init?(
        device: MTLDevice,
        queue: MTLCommandQueue,
        gridWidth: Int,
        gridHeight: Int,
        pixelFormat: MTLPixelFormat
    ) {
        guard
            let engine = FallingSandGPUEngine(device: device, queue: queue, width: gridWidth, height: gridHeight),
            let particles = FallingSandParticles(device: device, queue: queue, gridWidth: gridWidth, gridHeight: gridHeight),
            let pipeline = FallingSandRenderPipeline(device: device, pixelFormat: pixelFormat),
            let particlePipeline = FallingSandParticleRenderPipeline(device: device, pixelFormat: pixelFormat)
        else { return nil }
        self.init(engine: engine, particles: particles, renderPipeline: pipeline,
                  particleRenderPipeline: particlePipeline, gridWidth: gridWidth, gridHeight: gridHeight)
    }

    /// 清场：清空 CA 网格（积雪）+ **飞行粒子**（防停止后冻结残留）+ 关 spawn。
    /// 停止天气系统时调 → 屏幕彻底干净，像刚打开软件。
    public func clear() {
        engine.clear()
        particles.clear()
        spawnSnow = false
        spawnRain = false
    }

    public func tick(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        dt: Float
    ) {
        if let rects = pendingRects {
            engine.uploadRects(rects)
        }
        // pet occluder：每帧上传当前帧 alpha mask + 占位原点（雪堆 pet 上）；
        // nil → 关 occluder（无雪 / Orb 形象 / pet 隐藏）。
        if let pet = pendingPetOccluder {
            engine.uploadPetMask(pet.mask, originCellX: pet.originCellX, originCellY: pet.originCellY,
                                 w: pet.width, h: pet.height)
        } else {
            engine.disablePetOccluder()
        }
        // pet 扬雪:写粒子系统的 pet AABB + 横速度(integrate kernel 用)。
        if let sweep = pendingPetSweep {
            particles.petSweepEnabled = true
            particles.petAABBMinX = sweep.minX; particles.petAABBMinY = sweep.minY
            particles.petAABBMaxX = sweep.maxX; particles.petAABBMaxY = sweep.maxY
            particles.petVelX = sweep.velX
        } else {
            particles.petSweepEnabled = false
        }
        // 同步可调参数到 engine / particles（调试面板实时改 → 立即生效）。
        engine.tuning = tuning
        particles.gravity = tuning.gravity
        particles.windStrength = tuning.windStrength   // 雪 spatial 微飘强度
        particles.windX = tuning.rainWindLean          // 雨有向风 lean（带符号）
        particles.splashProbability = tuning.splashProbability
        particles.sizeMin = tuning.sizeMin
        particles.sizeMax = tuning.sizeMax
        particles.maxColumnDepth = tuning.maxColumnDepth
        // 湿亮 sheen 朝目标 lerp（下雨→1，停雨→基线）。dt*3 ≈ 1s 平滑过渡。
        let wetTarget: Float = spawnRain ? 1.0 : tuning.wetnessBaseline
        wetness += (wetTarget - wetness) * min(1.0, dt * 3.0)
        // ambientOverride >= 0 → 无视天气温度（调试用，直接拖到全融/冰冻看相变）。
        let ambient = tuning.ambientOverride >= 0 ? tuning.ambientOverride : ambientTemperature
        engine.fillTemperature(ambient)

        // 1. 发射飞行粒子（连续降雪）
        if spawnSnow { particles.emitTop(count: tuning.snowEmitPerFrame) }
        if spawnRain { particles.emitTop(count: tuning.rainEmitPerFrame, kind: 1) }   // 雨 = water 粒子（落地沉积水→漫流成水洼）

        // 2. 粒子物理 + 落地沉积到 CA 当前 buffer（各自 commit+wait，保证 step 前沉积完）
        particles.integrate(dt: dt)
        particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding,
                       columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)

        // 3. CA step（处理沉积的 cell：堆积/相变/H1 深度平衡）
        engine.step(dt: dt)
        tickCount += 1

        // 4. 渲染：CA 积雪 fragment（连续柔面）+ 粒子 instanced（飞行软圆）叠加，一个 render pass
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        renderPipeline.encode(
            into: encoder,
            cellBuffer: engine.cellBufferForRender,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            wetness: wetness
        )
        particleRenderPipeline.encode(
            into: encoder,
            particleBuffer: particles.buffer,
            instanceCount: particles.capacity,
            gridWidth: gridWidth,
            gridHeight: gridHeight
        )
        encoder.endEncoding()
    }
}
