import Metal
import simd

/// 飞行雪粒子（CPU 端镜像 MSL SnowParticle，32 字节、与 GPU buffer 逐位对齐）。
public struct SnowParticle: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    public var size: Float
    public var seed: UInt32
    public var alive: UInt32
    /// 粒子种类：0 = 雪（落地沉积 snow cell），1 = 主雨（落地沉积 water cell → FS 水漫流成水洼），
    /// 2 = splash 水花（主雨落地按概率溅起，横飞+上抛弧线消亡，不沉积——纯视觉）。
    public var kind: UInt32

    public init(position: SIMD2<Float>, velocity: SIMD2<Float>, size: Float,
                seed: UInt32, alive: UInt32 = 1, kind: UInt32 = 0) {
        self.position = position
        self.velocity = velocity
        self.size = size
        self.seed = seed
        self.alive = alive
        self.kind = kind
    }
}

/// 精简粒子 uniforms（镜像 MSL FSParticleUniforms，16×4=64 字节，stride 闸防漂移）。
public struct FSParticleUniforms: Equatable, Sendable {
    public var particleCount: UInt32
    public var gridWidth: UInt32
    public var gridHeight: UInt32
    public var frameIndex: UInt32
    public var dt: Float
    public var gravity: Float
    /// 雨的有向风 lean（带符号 cell/s）；雪不用此字段。见 `FallingSandParticles.windX`。
    public var windX: Float
    /// 雪的 spatial 微飘强度（净零，不集体滑）。
    public var windStrength: Float
    public var maxColumnDepth: UInt32   // 落地硬上限：列深 ≥ 此值则拒绝沉积（封顶防蠕变）
    /// 雨滴落地溅起 splash 水花概率（0..1）。land kernel 用。
    public var splashProbability: Float
    // pet 扬雪（仅 integrate kernel 用；land 用默认 0/关）。
    public var petSweepEnabled: UInt32  // 1 = 启用扬雪
    public var petMinX: Float           // pet AABB（cell 坐标，y=0 底）
    public var petMinY: Float
    public var petMaxX: Float
    public var petMaxY: Float
    public var petVelX: Float           // pet 横向速度（cell/s，带符号）

    public init(
        particleCount: UInt32, gridWidth: UInt32, gridHeight: UInt32, frameIndex: UInt32,
        dt: Float, gravity: Float, windX: Float, windStrength: Float,
        maxColumnDepth: UInt32, splashProbability: Float,
        petSweepEnabled: UInt32 = 0, petMinX: Float = 0, petMinY: Float = 0,
        petMaxX: Float = 0, petMaxY: Float = 0, petVelX: Float = 0
    ) {
        self.particleCount = particleCount
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.frameIndex = frameIndex
        self.dt = dt
        self.gravity = gravity
        self.windX = windX
        self.windStrength = windStrength
        self.maxColumnDepth = maxColumnDepth
        self.splashProbability = splashProbability
        self.petSweepEnabled = petSweepEnabled
        self.petMinX = petMinX
        self.petMinY = petMinY
        self.petMaxX = petMaxX
        self.petMaxY = petMaxY
        self.petVelX = petVelX
    }
}

/// 飞行雪粒子系统。固定容量 buffer + alive 标志（dead 槽位可被 spawn 复用）。
/// `integrate` 推进浮点位置（亚像素）。落地→CA 转换在 H3 加；此处落到底回收到顶。
public final class FallingSandParticles {
    public let capacity: Int
    public let gridWidth: Int
    public let gridHeight: Int

    private let queue: MTLCommandQueue
    private let integratePipeline: MTLComputePipelineState
    private let landPipeline: MTLComputePipelineState
    private let particleBuffer: MTLBuffer
    private var spawnRng = FallingSandRandom(seed: 0x5A17)
    private var frame: UInt32 = 0

    public var gravity: Float = 90
    /// 雨的有向风 lean（带符号 cell/s，driver 由 `tuning.rainWindLean` 写）。雪不受影响。
    public var windX: Float = 0
    public var windStrength: Float = 1.5
    public var sizeMin: Float = 0.6   // 用户反馈雪花太大，持续缩
    public var sizeMax: Float = 3
    /// 雨滴落地溅起 splash 水花概率（0..1，driver 由 `tuning.splashProbability` 写）。
    public var splashProbability: Float = 0.3
    /// 落地硬上限：每列雪深 ≥ 此值则拒绝沉积（物理封顶，防积雪蠕变增长）。
    /// 8 cell ≈ 8px 薄层，快速填满即封顶（用户反馈越堆越高）。
    public var maxColumnDepth: Int = 24
    /// pet 扬雪：driver 每帧按 pet 位置/速度写。`petSweepEnabled=false` 时
    /// integrate kernel 跳过（无雪/pet 静止/Orb）。AABB 为 cell 坐标，velX 为 cell/s 带符号。
    public var petSweepEnabled = false
    public var petAABBMinX: Float = 0
    public var petAABBMinY: Float = 0
    public var petAABBMaxX: Float = 0
    public var petAABBMaxY: Float = 0
    public var petVelX: Float = 0

    public init?(device: MTLDevice, queue: MTLCommandQueue, gridWidth: Int, gridHeight: Int, capacity: Int = 32768) {
        guard gridWidth > 0, gridHeight > 0, capacity > 0 else { return nil }
        self.queue = queue
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.capacity = capacity
        guard
            let library = try? device.makeLibrary(source: FallingSandParticleKernels.source, options: nil),
            let fn = library.makeFunction(name: "fs_integrate_particles"),
            let landFn = library.makeFunction(name: "fs_particle_land"),
            let pipeline = try? device.makeComputePipelineState(function: fn),
            let landState = try? device.makeComputePipelineState(function: landFn),
            let buffer = device.makeBuffer(length: capacity * MemoryLayout<SnowParticle>.stride, options: [.storageModeShared])
        else { return nil }
        self.integratePipeline = pipeline
        self.landPipeline = landState
        self.particleBuffer = buffer
        // 全部初始化为 dead。
        let ptr = buffer.contents().bindMemory(to: SnowParticle.self, capacity: capacity)
        for i in 0..<capacity {
            ptr[i] = SnowParticle(position: .zero, velocity: .zero, size: 0, seed: 0, alive: 0)
        }
    }

    /// 供渲染读取的粒子 buffer + 容量。
    public var buffer: MTLBuffer { particleBuffer }

    /// 清空所有粒子（全标记 dead）。停止天气系统时用 → 屏幕干净无残留飞行雪。
    public func clear() {
        let ptr = particleBuffer.contents().bindMemory(to: SnowParticle.self, capacity: capacity)
        for i in 0..<capacity { ptr[i].alive = 0 }
    }

    /// 当前存活粒子数（CPU 扫描，测试/诊断用）。
    public func aliveCount() -> Int {
        let ptr = particleBuffer.contents().bindMemory(to: SnowParticle.self, capacity: capacity)
        return (0..<capacity).reduce(0) { $0 + (ptr[$1].alive == 1 ? 1 : 0) }
    }

    public func readback() -> [SnowParticle] {
        let ptr = particleBuffer.contents().bindMemory(to: SnowParticle.self, capacity: capacity)
        return Array(UnsafeBufferPointer(start: ptr, count: capacity))
    }

    /// 在顶边发射 `count` 个粒子（找 dead 槽位复用）。
    /// `kind`：0 = 雪（平方分布尺寸、慢飘、落地沉积 snow），1 = 雨（细、快落、少横漂、
    /// 落地沉积 water → FS 水漫流成水洼）。
    @discardableResult
    public func emitTop(count: Int, kind: UInt32 = 0) -> Int {
        let ptr = particleBuffer.contents().bindMemory(to: SnowParticle.self, capacity: capacity)
        let isRain = kind == 1
        var emitted = 0
        var slot = 0
        for _ in 0..<count {
            // 找下一个 dead 槽
            while slot < capacity && ptr[slot].alive == 1 { slot += 1 }
            guard slot < capacity else { break }
            let u = spawnRng.unit()
            // 雨：细长（0.5..0.9）；雪：平方分布偏小。
            let size = isRain ? (0.5 + 0.4 * u) : (sizeMin + u * u * (sizeMax - sizeMin))
            let x = spawnRng.unit() * Float(gridWidth)
            // 雨落速 ~3x 雪（按屏高缩放）。
            let baseFall = Float(gridHeight) * (isRain ? 0.55 : 0.18)
            let fallSpeed = -baseFall * (0.6 + 0.4 * spawnRng.unit())
            // 雨横向漂移小（落得直），雪飘。
            let lateral = (spawnRng.unit() - 0.5) * (isRain ? 1.0 : 4.0)
            ptr[slot] = SnowParticle(
                position: SIMD2<Float>(x, Float(gridHeight) - 1),
                velocity: SIMD2<Float>(lateral, fallSpeed),
                size: size,
                seed: UInt32(spawnRng.int(0x7FFFFFFF)),
                alive: 1,
                kind: kind
            )
            emitted += 1
            slot += 1
        }
        return emitted
    }

    /// 把积分 pass 编入给定 command buffer（不提交）。供 driver 与渲染共用一个 cmd buffer。
    public func encodeIntegrate(into commandBuffer: MTLCommandBuffer, dt: Float) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        encodeIntegrate(into: enc, dt: dt)
        enc.endEncoding()
    }

    /// 把积分 pass 编入给定 encoder（与其它 compute 共用 encoder 时用）。
    public func encodeIntegrate(into enc: MTLComputeCommandEncoder, dt: Float) {
        var u = FSParticleUniforms(
            particleCount: UInt32(capacity),
            gridWidth: UInt32(gridWidth), gridHeight: UInt32(gridHeight),
            frameIndex: frame, dt: dt, gravity: gravity, windX: windX, windStrength: windStrength,
            maxColumnDepth: UInt32(maxColumnDepth), splashProbability: splashProbability,
            petSweepEnabled: petSweepEnabled ? 1 : 0,
            petMinX: petAABBMinX, petMinY: petAABBMinY, petMaxX: petAABBMaxX, petMaxY: petAABBMaxY,
            petVelX: petVelX
        )
        enc.setComputePipelineState(integratePipeline)
        enc.setBuffer(particleBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<FSParticleUniforms>.stride, index: 1)
        let tw = 64
        let groups = MTLSize(width: (capacity + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
        frame &+= 1
    }

    /// 同步积分一帧（测试用，commit + wait）。
    public func integrate(dt: Float) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        encodeIntegrate(into: cmd, dt: dt)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// 同步落地一帧（测试用，commit + wait）。
    public func land(cellBuffer: MTLBuffer, occlusionBuffer: MTLBuffer, columnDepthBuffer: MTLBuffer, dt: Float) {
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return }
        encodeLand(into: enc, cellBuffer: cellBuffer, occlusionBuffer: occlusionBuffer, columnDepthBuffer: columnDepthBuffer, dt: dt)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// 把落地→CA 沉积 pass 编入 encoder：碰 floor/下方占用 + 列深未达上限 → 写 snow cell
    /// 到 `cellBuffer` + 回收粒子。buffer 由 caller（引擎/driver）传。
    public func encodeLand(
        into enc: MTLComputeCommandEncoder,
        cellBuffer: MTLBuffer,
        occlusionBuffer: MTLBuffer,
        columnDepthBuffer: MTLBuffer,
        dt: Float
    ) {
        var u = FSParticleUniforms(
            particleCount: UInt32(capacity),
            gridWidth: UInt32(gridWidth), gridHeight: UInt32(gridHeight),
            frameIndex: frame, dt: dt, gravity: gravity, windX: windX, windStrength: windStrength,
            maxColumnDepth: UInt32(maxColumnDepth), splashProbability: splashProbability
        )
        enc.setComputePipelineState(landPipeline)
        enc.setBuffer(particleBuffer, offset: 0, index: 0)
        enc.setBuffer(cellBuffer, offset: 0, index: 1)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 2)
        enc.setBytes(&u, length: MemoryLayout<FSParticleUniforms>.stride, index: 3)
        enc.setBuffer(columnDepthBuffer, offset: 0, index: 4)
        let tw = 64
        let groups = MTLSize(width: (capacity + tw - 1) / tw, height: 1, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
    }
}
