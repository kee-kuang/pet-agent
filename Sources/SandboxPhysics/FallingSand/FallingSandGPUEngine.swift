import Metal

/// Falling-sand GPU 引擎。双缓冲 cell buffer + reservation buffer，运行时编译
/// `FallingSandKernels.source`。每个移动 sub-pass = clear → claim → commit 三
/// dispatch（pass 间 memoryBarrier），双缓冲 ping-pong。
///
/// `stepMovementOnly()` 只跑确定性移动（gravity forced + flowL + flowR），语义
/// 对齐 CPU `FallingSandSimulation.stepMovementOnly()`，供逐格对拍。相变/spawn
/// 在后续 task 接入。
/// 窗口遮挡矩形（cell 坐标，y=0 底）。镜像 MSL FSRect，16 字节。
public struct FSRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public final class FallingSandGPUEngine {
    public let width: Int
    public let height: Int
    public static let maxRects = 64
    /// pet occluder mask 单边上限（cell）。pet 窗口 72px @ cellSize=1 → 72 cell；
    /// 128 留足头寸（不同 cellSize / 更大形象），128×128 = 16KB shared，可忽略。
    public static let maxPetMaskDim = 128

    private let queue: MTLCommandQueue
    private let clearPipeline: MTLComputePipelineState
    private let claimPipeline: MTLComputePipelineState
    private let commitPipeline: MTLComputePipelineState
    private let phasePipeline: MTLComputePipelineState
    private let columnDepthPipeline: MTLComputePipelineState
    private let clearOccludedPipeline: MTLComputePipelineState
    private let rasterizeOcclusionPipeline: MTLComputePipelineState
    private let rasterizePetPipeline: MTLComputePipelineState

    private let cellBufferA: MTLBuffer
    private let cellBufferB: MTLBuffer
    private let reservationBuffer: MTLBuffer
    private let temperatureBuffer: MTLBuffer
    private let occlusionBuffer: MTLBuffer     // 逐 cell 窗口遮挡 mask（UInt8）
    private let rectsBuffer: MTLBuffer         // 窗口矩形（cell 坐标，栅格化 mask 用）
    private var rectCount: Int = 0
    private let petMaskBuffer: MTLBuffer       // pet 当前帧 alpha mask（uchar，maxPetMaskDim²）
    private var petOriginCellX: Int = 0
    private var petOriginCellY: Int = 0
    private var petMaskW: Int = 0
    private var petMaskH: Int = 0
    private var petOccluderEnabled = false
    private let columnDepthBuffer: MTLBuffer   // 每列雪堆深度（深度负反馈升华读）
    private let cellCount: Int

    private var currentIsA = true
    private var frame: UInt32 = 0
    private var spawnRng = FallingSandRandom(seed: 0xBEEF)
    /// 自然风（带符号 ~-1..1）。由 driver 每帧按阵风函数设。0 = 无风（确定性）。
    public var windX: Float = 0
    /// 可调物理参数（相变阈值/速率/升华/雪概率）。driver 每帧从调试面板同步。
    public var tuning = FallingSandTuning()

    public init?(device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.queue = queue
        self.width = width
        self.height = height
        self.cellCount = width * height

        guard
            let library = try? device.makeLibrary(source: FallingSandKernels.source, options: nil),
            let clearFn = library.makeFunction(name: "fs_clear_reservation"),
            let claimFn = library.makeFunction(name: "fs_claim_move"),
            let commitFn = library.makeFunction(name: "fs_commit_move"),
            let phaseFn = library.makeFunction(name: "fs_apply_phase"),
            let depthFn = library.makeFunction(name: "fs_compute_column_depth"),
            let occludeFn = library.makeFunction(name: "fs_clear_occluded"),
            let rasterFn = library.makeFunction(name: "fs_rasterize_occlusion"),
            let petFn = library.makeFunction(name: "fs_rasterize_pet"),
            let clearState = try? device.makeComputePipelineState(function: clearFn),
            let claimState = try? device.makeComputePipelineState(function: claimFn),
            let commitState = try? device.makeComputePipelineState(function: commitFn),
            let phaseState = try? device.makeComputePipelineState(function: phaseFn),
            let depthState = try? device.makeComputePipelineState(function: depthFn),
            let occludeState = try? device.makeComputePipelineState(function: occludeFn),
            let rasterState = try? device.makeComputePipelineState(function: rasterFn),
            let petState = try? device.makeComputePipelineState(function: petFn)
        else { return nil }
        self.clearPipeline = clearState
        self.claimPipeline = claimState
        self.commitPipeline = commitState
        self.phasePipeline = phaseState
        self.columnDepthPipeline = depthState
        self.clearOccludedPipeline = occludeState
        self.rasterizeOcclusionPipeline = rasterState
        self.rasterizePetPipeline = petState

        let bytes = cellCount * MemoryLayout<UInt32>.stride
        let tempBytes = cellCount * MemoryLayout<Float>.stride
        guard
            let a = device.makeBuffer(length: bytes, options: [.storageModeShared]),
            let b = device.makeBuffer(length: bytes, options: [.storageModeShared]),
            let r = device.makeBuffer(length: bytes, options: [.storageModeShared]),
            let temp = device.makeBuffer(length: tempBytes, options: [.storageModeShared]),
            let occ = device.makeBuffer(length: cellCount * MemoryLayout<UInt8>.stride, options: [.storageModeShared]),
            let rects = device.makeBuffer(length: Self.maxRects * MemoryLayout<FSRect>.stride, options: [.storageModeShared]),
            let depth = device.makeBuffer(length: width * MemoryLayout<UInt32>.stride, options: [.storageModeShared]),
            let petMask = device.makeBuffer(length: Self.maxPetMaskDim * Self.maxPetMaskDim * MemoryLayout<UInt8>.stride, options: [.storageModeShared])
        else { return nil }
        self.cellBufferA = a
        self.cellBufferB = b
        self.reservationBuffer = r
        self.temperatureBuffer = temp
        self.occlusionBuffer = occ
        self.rectsBuffer = rects
        self.columnDepthBuffer = depth
        self.petMaskBuffer = petMask
        // 默认无遮挡（无窗口，雪落到 y=0）。
        occ.contents().initializeMemory(as: UInt8.self, repeating: 0, count: cellCount)
        // 列深 zero-init（首帧 land 读到的是 0 → 允许沉积）。
        depth.contents().initializeMemory(as: UInt32.self, repeating: 0, count: width)
    }

    private var currentBuffer: MTLBuffer { currentIsA ? cellBufferA : cellBufferB }
    private var otherBuffer: MTLBuffer { currentIsA ? cellBufferB : cellBufferA }

    /// 当前网格的 GPU buffer，供像素渲染管线读取。
    public var cellBufferForRender: MTLBuffer { currentBuffer }

    /// step 接下来要读的 cell buffer（= 当前 buffer）。粒子落地沉积写这里，
    /// 之后 step 处理这些沉积的 cell。必须在 step 之前调用。
    public var pendingCellBuffer: MTLBuffer { currentBuffer }

    /// 遮挡 mask buffer（窗口碰撞），供粒子落地检测读。step 内每帧由 rasterize 重算。
    public var occlusionBufferForLanding: MTLBuffer { occlusionBuffer }

    /// 列深 buffer（上一帧每列雪深），供粒子落地硬上限检测读（超上限拒绝沉积）。
    public var columnDepthBufferForLanding: MTLBuffer { columnDepthBuffer }

    /// 上传初始网格到当前 buffer。
    public func upload(_ cells: [UInt32]) {
        precondition(cells.count == cellCount, "cells 数量需等于 width*height")
        cells.withUnsafeBytes { src in
            currentBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }

    /// 读回当前网格。
    public func readback() -> [UInt32] {
        let ptr = currentBuffer.contents().bindMemory(to: UInt32.self, capacity: cellCount)
        return Array(UnsafeBufferPointer(start: ptr, count: cellCount))
    }

    /// 上传 per-cell 温度场（归一化 0..1）。
    public func uploadTemperatures(_ temps: [Float]) {
        precondition(temps.count == cellCount, "温度数量需等于 width*height")
        temps.withUnsafeBytes { src in
            temperatureBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }

    private var lastFilledTemperature: Float?

    /// 用单一值填满温度场（均匀 ambient）。值不变则跳过 —— 1px 下 cellCount 达
    /// 数百万，每帧空跑全网格循环太贵；ambient 仅天气刷新（15min）才变。
    public func fillTemperature(_ value: Float) {
        if lastFilledTemperature == value { return }
        lastFilledTemperature = value
        let ptr = temperatureBuffer.contents().bindMemory(to: Float.self, capacity: cellCount)
        for i in 0..<cellCount { ptr[i] = value }
    }

    /// 上传窗口遮挡矩形（cell 坐标）。step 内每帧栅格化成逐 cell mask。超 maxRects 截断。
    public func uploadRects(_ rects: [FSRect]) {
        let n = min(rects.count, Self.maxRects)
        rectCount = n
        guard n > 0 else { return }
        let ptr = rectsBuffer.contents().bindMemory(to: FSRect.self, capacity: Self.maxRects)
        for i in 0..<n { ptr[i] = rects[i] }
    }

    /// 上传 pet 当前帧 alpha mask（pet 第二 occluder）。mask 为 w×h 行主序 uchar（0..255），
    /// row 0 = sprite 顶部（CGImage 行序，Y 翻转在 kernel 内）。`originCell{X,Y}` 是
    /// pet 占位左下角的 cell 坐标（世界底原点 y-up，= pet 世界位置 / cellSize）。
    /// w/h 超 maxPetMaskDim 截断。step 内每帧栅格化进 occlusion buffer（雪堆 pet 上）。
    public func uploadPetMask(_ mask: [UInt8], originCellX: Int, originCellY: Int, w: Int, h: Int) {
        let clampedW = min(max(w, 0), Self.maxPetMaskDim)
        let clampedH = min(max(h, 0), Self.maxPetMaskDim)
        guard clampedW > 0, clampedH > 0, mask.count >= clampedW * clampedH else {
            petOccluderEnabled = false
            return
        }
        petMaskW = clampedW
        petMaskH = clampedH
        petOriginCellX = originCellX
        petOriginCellY = originCellY
        petOccluderEnabled = true
        let ptr = petMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: Self.maxPetMaskDim * Self.maxPetMaskDim)
        mask.withUnsafeBufferPointer { src in
            ptr.update(from: src.baseAddress!, count: clampedW * clampedH)
        }
    }

    /// 关闭 pet occluder（无雪 / 非 sprite 形象 / pet 隐藏）。step 内跳过 fs_rasterize_pet。
    public func disablePetOccluder() {
        petOccluderEnabled = false
    }

    /// 只跑确定性移动（无相变、无雪概率门），对齐 CPU stepMovementOnly。
    /// 3 个移动 pass 批进 1 个 command buffer（pass 间 memoryBarrier）。
    public func stepMovementOnly() {
        let leftFirst = (frame & 1) == 0
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        var src = currentBuffer, dst = otherBuffer
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 0, leftFirst: leftFirst, forceSnowFall: true, windX: 0)
        swap(&src, &dst)
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 1, leftFirst: leftFirst, forceSnowFall: true, windX: 0)
        swap(&src, &dst)
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 1, leftFirst: !leftFirst, forceSnowFall: true, windX: 0)
        swap(&src, &dst)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        currentIsA = (src === cellBufferA)   // src = 最新结果 buffer
        frame &+= 1
    }

    /// 只跑相变一帧（in-place，读已上传的温度场）。frame 推进让位置哈希逐帧变化。
    public func stepPhaseOnly() {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        encodePhasePass(into: enc, buffer: currentBuffer, dt: 1.0 / 30.0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        frame &+= 1
    }

    /// 在顶行按比例铺**单 cell** 元素（clump 在 CA 里会立刻散开 → 改单 cell 不散、
    /// 密度可控）。每个 cell 的 `rb` 存随机尺寸种子 → 渲染侧按 rb 画大小不一的软团雪花
    /// （真正凝聚的大雪花/丝滑落雪需粒子方案 1b）。
    public func spawnTopRow(_ species: FallingSandSpecies, fillRatio: Float) {
        let y = height - 1
        let ptr = currentBuffer.contents().bindMemory(to: UInt32.self, capacity: cellCount)
        for x in 0..<width where spawnRng.unit() < fillRatio {
            // rb = 随机尺寸种子（平方分布偏小：多数小、偶有大）。
            let u = spawnRng.unit()
            let sizeSeed = UInt8(u * u * 255.0)
            ptr[y * width + x] = FallingSandCell.make(species, ra: UInt8(spawnRng.int(256)), rb: sizeSeed)
        }
    }

    /// 清空网格（清场）。两个 cell buffer 都清，避免 ping-pong 残留。
    public func clear() {
        cellBufferA.contents().initializeMemory(as: UInt32.self, repeating: 0, count: cellCount)
        cellBufferB.contents().initializeMemory(as: UInt32.self, repeating: 0, count: cellCount)
    }

    /// 完整一帧：gravity（真雪概率门）→ flowL → flowR → 相变。全批进 1 个
    /// command buffer + 单次 waitUntilCompleted（4 次 GPU 往返 → 1 次）。
    public func step(dt: Float) {
        let leftFirst = (frame & 1) == 0
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        var src = currentBuffer, dst = otherBuffer
        // 先栅格化窗口遮挡 mask（每帧重算，窗口移动/切桌面立刻反映）。
        encodeRasterizeOcclusion(into: enc)
        enc.memoryBarrier(scope: .buffers)
        // pet 当前帧 alpha 轮廓 OR 进同一 occlusion buffer（雪堆 pet 上）。
        // 必须在窗口栅格化之后（OR，不被覆写）、清遮挡之前（pet 内部的雪一并清掉）。
        if petOccluderEnabled {
            encodeRasterizePet(into: enc)
            enc.memoryBarrier(scope: .buffers)
        }
        // 再清遮挡：窗口 + pet 盖住的雪每帧清掉（切桌面/窗口移动/pet 移动立刻消失）。
        encodeClearOccluded(into: enc, buffer: src)
        enc.memoryBarrier(scope: .buffers)
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 0, leftFirst: leftFirst, forceSnowFall: false, windX: windX)
        swap(&src, &dst)
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 1, leftFirst: leftFirst, forceSnowFall: false, windX: windX)
        swap(&src, &dst)
        encodeMovementPass(into: enc, src: src, dst: dst, passKind: 1, leftFirst: !leftFirst, forceSnowFall: false, windX: windX)
        swap(&src, &dst)
        encodePhasePass(into: enc, buffer: src, dt: dt)   // src = 最新移动结果
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        currentIsA = (src === cellBufferA)
        frame &+= 1
    }

    // MARK: - 内部

    private var threadgroupSize: MTLSize { MTLSize(width: 8, height: 8, depth: 1) }
    private var threadgroupCount: MTLSize {
        MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
    }

    /// 把一个移动 sub-pass（clear→claim→commit）编入给定 encoder（不提交，pass 间
    /// 由 memoryBarrier 排序）。读 src 写 dst（双缓冲由调用方 ping-pong）。
    private func encodeMovementPass(
        into enc: MTLComputeCommandEncoder,
        src: MTLBuffer, dst: MTLBuffer,
        passKind: UInt32, leftFirst: Bool, forceSnowFall: Bool, windX: Float
    ) {
        var u = FallingSandUniforms(
            gridWidth: UInt32(width), gridHeight: UInt32(height),
            frameIndex: frame, leftFirst: leftFirst ? 1 : 0,
            passKind: passKind, forceSnowFall: forceSnowFall ? 1 : 0,
            snowFallProbability: tuning.snowFallProbability,
            windX: windX
        )
        let tg = threadgroupSize, groups = threadgroupCount
        let stride = MemoryLayout<FallingSandUniforms>.stride

        enc.setComputePipelineState(clearPipeline)
        enc.setBuffer(reservationBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: stride, index: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.memoryBarrier(scope: .buffers)

        enc.setComputePipelineState(claimPipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(reservationBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: stride, index: 2)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 3)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.memoryBarrier(scope: .buffers)

        enc.setComputePipelineState(commitPipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBuffer(reservationBuffer, offset: 0, index: 2)
        enc.setBytes(&u, length: stride, index: 3)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 4)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.memoryBarrier(scope: .buffers)   // 排序下一 pass 的 clear
    }

    /// 栅格化窗口遮挡 mask（rects → 逐 cell occlusion）。
    private func encodeRasterizeOcclusion(into enc: MTLComputeCommandEncoder) {
        var u = FallingSandUniforms(gridWidth: UInt32(width), gridHeight: UInt32(height),
                                    frameIndex: frame, rectCount: UInt32(rectCount))
        enc.setComputePipelineState(rasterizeOcclusionPipeline)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 0)
        enc.setBuffer(rectsBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<FallingSandUniforms>.stride, index: 2)
        enc.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
    }

    /// 栅格化 pet alpha 轮廓进 occlusion buffer（pet 第二 occluder）。线程网格 = mask 尺寸
    /// （pet footprint），非全网格 —— pet 占位通常远小于屏幕。
    private func encodeRasterizePet(into enc: MTLComputeCommandEncoder) {
        guard petMaskW > 0, petMaskH > 0 else { return }   // 防御:零尺寸 → dispatch(0,0) 静默空跑
        var u = FallingSandUniforms(
            gridWidth: UInt32(width), gridHeight: UInt32(height), frameIndex: frame,
            petOriginX: Int32(petOriginCellX), petOriginY: Int32(petOriginCellY),
            petMaskW: UInt32(petMaskW), petMaskH: UInt32(petMaskH), petEnabled: 1)
        enc.setComputePipelineState(rasterizePetPipeline)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 0)
        enc.setBuffer(petMaskBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<FallingSandUniforms>.stride, index: 2)
        let petGroups = MTLSize(
            width: (petMaskW + 7) / 8, height: (petMaskH + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(petGroups, threadsPerThreadgroup: threadgroupSize)
    }

    /// 清遮挡 pass：清除 occlusion=1 的 cell（窗口内部的雪）。
    private func encodeClearOccluded(into enc: MTLComputeCommandEncoder, buffer: MTLBuffer) {
        var u = FallingSandUniforms(gridWidth: UInt32(width), gridHeight: UInt32(height), frameIndex: frame)
        enc.setComputePipelineState(clearOccludedPipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(occlusionBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<FallingSandUniforms>.stride, index: 2)
        enc.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
    }

    /// 相变 pass（in-place）编入给定 encoder。先算每列雪深（深度负反馈升华读），
    /// 再跑相变。pass 间 memoryBarrier 排序。
    private func encodePhasePass(into enc: MTLComputeCommandEncoder, buffer: MTLBuffer, dt: Float) {
        var u = FallingSandUniforms(
            gridWidth: UInt32(width), gridHeight: UInt32(height),
            frameIndex: frame, dt: dt,
            meltThreshold: tuning.meltThreshold,
            freezeThreshold: tuning.freezeThreshold,
            evaporateThreshold: tuning.evaporateThreshold,
            condenseThreshold: tuning.condenseThreshold,
            meltRatePerSec: tuning.meltRatePerSec,
            freezeRatePerSec: tuning.freezeRatePerSec,
            evaporateRatePerSec: tuning.evaporateRatePerSec,
            condenseRatePerSec: tuning.condenseRatePerSec,
            steamDissipatePerSec: tuning.steamDissipatePerSec,
            snowSublimatePerSec: tuning.snowSublimatePerSec,
            snowDepthSublimateCoeff: tuning.snowDepthSublimateCoeff
        )
        let stride = MemoryLayout<FallingSandUniforms>.stride

        // 列深 pass（一线程一列）
        enc.setComputePipelineState(columnDepthPipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(columnDepthBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: stride, index: 2)
        let colGroups = MTLSize(width: (width + 63) / 64, height: 1, depth: 1)
        enc.dispatchThreadgroups(colGroups, threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.memoryBarrier(scope: .buffers)

        // 相变 pass
        enc.setComputePipelineState(phasePipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(temperatureBuffer, offset: 0, index: 1)
        enc.setBytes(&u, length: stride, index: 2)
        enc.setBuffer(columnDepthBuffer, offset: 0, index: 3)
        enc.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
    }
}
