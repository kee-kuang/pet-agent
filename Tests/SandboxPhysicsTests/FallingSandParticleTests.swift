import Testing
import Metal
import simd
@testable import SandboxPhysics

@Suite("FallingSand 飞行粒子")
struct FallingSandParticleTests {
    @Test("SnowParticle / uniforms stride 与 MSL 对齐")
    func strideMatchesMSL() {
        #expect(MemoryLayout<SnowParticle>.stride == 32)        // float2+float2+f+u+u+u = 32
        // 10 原字段 + pet 扬雪 6 字段（petSweepEnabled + AABB 4 + petVelX）= 16×4 = 64。
        #expect(MemoryLayout<FSParticleUniforms>.stride == 64)
        #expect(MemoryLayout<FSParticleUniforms>.alignment == 4)
    }

    @Test("B2 扬雪：pet AABB 内雪粒子被沿运动方向横扫（vs 关闭对照组）")
    func petSweepPushesParticles() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 120, gh = 100

        // 在 pet AABB 内手摆静止雪粒子（velocity≈0），跑一步积分看横速度变化。
        func runSweep(enabled: Bool, velX: Float) throws -> Float {
            let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 64))
            p.gravity = 0   // 隔离扬雪横向冲量（不掺重力）
            p.windStrength = 0
            p.petSweepEnabled = enabled
            p.petAABBMinX = 40; p.petAABBMaxX = 80
            p.petAABBMinY = 20; p.petAABBMaxY = 60
            p.petVelX = velX
            let pptr = p.buffer.contents().bindMemory(to: SnowParticle.self, capacity: 64)
            // 雪粒子在 AABB 正中，初速 0。
            pptr[0] = SnowParticle(position: SIMD2<Float>(60, 40), velocity: .zero, size: 2, seed: 7, alive: 1)
            for _ in 0..<5 { p.integrate(dt: 1.0 / 60.0) }
            return p.readback()[0].velocity.x
        }

        // pet 向右快走（velX=+120 > 阈值 15）→ 粒子获得 +x 横速度。
        let swept = try runSweep(enabled: true, velX: 120)
        #expect(swept > 5, "扬雪应给 AABB 内雪粒子明显 +x 横速度,实际 \(swept)")
        // 关闭扬雪 → 横速度保持≈0（gravity/wind 已关）。
        let off = try runSweep(enabled: false, velX: 120)
        #expect(abs(off) < 0.5, "关闭扬雪横速度应≈0,实际 \(off)")
        // pet 静止（velX 低于阈值）→ 即使启用也不扬雪。
        let still = try runSweep(enabled: true, velX: 5)
        #expect(abs(still) < 0.5, "pet 静止(低于阈值)不应扬雪,实际 \(still)")
    }

    @Test("emitTop 发射存活粒子在顶边")
    func emitsAtTop() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: 200, gridHeight: 150, capacity: 1024))
        let n = p.emitTop(count: 100)
        #expect(n == 100)
        #expect(p.aliveCount() == 100)
        // 顶边附近
        for flake in p.readback() where flake.alive == 1 {
            #expect(flake.position.y >= 140)
            #expect(flake.position.x >= 0 && flake.position.x < 200)
            #expect(flake.size >= 0.6 && flake.size <= 4)
        }
    }

    @Test("积分浮点亚像素下落（不整格量化）")
    func integratesSubPixel() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: 100, gridHeight: 200, capacity: 256))
        p.windX = 0   // 无风确定性
        p.emitTop(count: 50)
        let before = p.readback().filter { $0.alive == 1 }.map { $0.position.y }
        for _ in 0..<10 { p.integrate(dt: 1.0 / 60.0) }
        let after = p.readback().filter { $0.alive == 1 }
        // 都在下落（y 减小）
        let afterY = after.map { $0.position.y }
        #expect(zip(before, afterY).allSatisfy { $0 > $1 })
        // 亚像素：至少一个 y 不是整数（证明浮点位置，非整格跳）
        let anyFractional = afterY.contains { $0 != $0.rounded() }
        #expect(anyFractional)
    }

    @Test("落地→CA 沉积：碰到 floor 写 snow cell + 回收粒子")
    func landingDepositsToCA() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 64, gh = 48
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 64))
        // CA cell buffer（空）+ occlusion buffer（全 0 = 无遮挡）
        let cellBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        cellBuf.contents().initializeMemory(as: UInt32.self, repeating: 0, count: gw * gh)
        let occBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt8>.stride, options: [.storageModeShared]))
        occBuf.contents().initializeMemory(as: UInt8.self, repeating: 0, count: gw * gh)
        let depthBuf = try #require(device.makeBuffer(length: gw * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        depthBuf.contents().initializeMemory(as: UInt32.self, repeating: 0, count: gw)   // 深 0 < 上限 → 允许沉积

        // 手摆一个粒子在底行附近（y=0，cy<=0 → 落地）
        let pptr = p.buffer.contents().bindMemory(to: SnowParticle.self, capacity: 64)
        pptr[0] = SnowParticle(position: SIMD2<Float>(30, 0.4), velocity: SIMD2<Float>(0, -5), size: 4, seed: 12345, alive: 1)

        p.land(cellBuffer: cellBuf, occlusionBuffer: occBuf, columnDepthBuffer: depthBuf, dt: 1.0 / 60.0)

        // CA cell (30,0) 应被沉积成 snow（species byte = 2）
        let cells = cellBuf.contents().bindMemory(to: UInt32.self, capacity: gw * gh)
        #expect(cells[0 * gw + 30] & 0xFF == 2)
        // 粒子落地后死亡（不回收）
        let after = p.buffer.contents().bindMemory(to: SnowParticle.self, capacity: 64)
        #expect(after[0].alive == 0)
    }

    @Test("落到底死亡（不回收，避免顶部聚集）")
    func diesAtBottom() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: 80, gridHeight: 60, capacity: 256))
        p.windX = 0
        p.emitTop(count: 40)
        // 跑足够多帧让粒子落到底
        for _ in 0..<600 { p.integrate(dt: 1.0 / 60.0) }
        // 落底的粒子死亡（不回收）→ 存活数清零
        #expect(p.aliveCount() == 0)
    }

    @Test("连续 emit + 落地死亡 → 飞行粒子存活数平衡（不涨到容量上限）")
    func airbornePopulationPlateaus() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 100, gh = 80
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 4096))
        let cellBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        cellBuf.contents().initializeMemory(as: UInt32.self, repeating: 0, count: gw * gh)
        let occBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt8>.stride, options: [.storageModeShared]))
        occBuf.contents().initializeMemory(as: UInt8.self, repeating: 0, count: gw * gh)
        let depthBuf = try #require(device.makeBuffer(length: gw * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        depthBuf.contents().initializeMemory(as: UInt32.self, repeating: 255, count: gw)   // 列满 → 落地必死不沉积
        let dt: Float = 1.0 / 60.0
        var early = 0, late = 0
        for f in 0..<800 {
            p.emitTop(count: 5)
            p.integrate(dt: dt)
            p.land(cellBuffer: cellBuf, occlusionBuffer: occBuf, columnDepthBuffer: depthBuf, dt: dt)
            if f == 400 { early = p.aliveCount() }
            if f == 799 { late = p.aliveCount() }
        }
        // 存活数平衡（emit↔死亡），远不到容量 4096
        #expect(late < 4096 / 2)
        // 后段稳定（非持续增长到上限）
        #expect(abs(late - early) < early / 3 + 50)
    }
}
