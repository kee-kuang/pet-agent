import Testing
import Metal
import simd
@testable import SandboxPhysics

/// 全链路混合雪离屏自评：手动跑 driver 的 tick 序列（emit→integrate→land→step→
/// 渲染 CA 积雪 + 粒子两层）多帧，深色底 dump PNG。验证雪从顶落下、**底部**堆积
/// （抓坐标/落地方向 bug）。
@Suite("FallingSand 混合雪全链路")
struct FallingSandHybridRenderTests {
    @Test("混合雪 240 帧 dump PNG + 底部堆积断言")
    func hybridDump() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 160, gh = 120
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: gw, height: gh))
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 4096))
        let cellPipe = try #require(FallingSandRenderPipeline(device: device, pixelFormat: .rgba8Unorm, soft: true))
        let partPipe = try #require(FallingSandParticleRenderPipeline(device: device, pixelFormat: .rgba8Unorm))
        engine.uploadTemperatures([Float](repeating: 0.2, count: gw * gh))   // 冷：不融，看堆积
        particles.windX = 0.8

        // 跑 driver 同序列：emit → integrate → land(沉积到 engine current) → step
        let dt: Float = 1.0 / 60.0
        for _ in 0..<240 {
            particles.emitTop(count: 6)
            particles.integrate(dt: dt)
            particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding, columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)
            engine.step(dt: dt)
        }

        // 渲染两层到离屏
        let scale = 5
        let tw = gw * scale, th = gh * scale
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        let tex = try #require(device.makeTexture(descriptor: td))
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        let cmd = try #require(queue.makeCommandBuffer())
        let enc = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        cellPipe.encode(into: enc, cellBuffer: engine.cellBufferForRender, gridWidth: gw, gridHeight: gh)
        partPipe.encode(into: enc, particleBuffer: particles.buffer, instanceCount: particles.capacity, gridWidth: gw, gridHeight: gh)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: tw * th * 4)
        tex.getBytes(&px, bytesPerRow: tw * 4, from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        FallingSandPNG.writeRGBA(px, width: tw, height: th, to: "/tmp/fallingsand_hybrid.png")

        // 验证 CA 积雪在**底部**（落地沉积 + CA 堆积）：底 1/4 区 snow cell 数 > 顶 1/4 区。
        let cells = engine.readback()
        var bottomSnow = 0, topSnow = 0
        for y in 0..<gh {
            for x in 0..<gw where FallingSandCell.species(cells[y * gw + x]) == .snow {
                if y < gh / 4 { bottomSnow += 1 }
                else if y >= gh * 3 / 4 { topSnow += 1 }
            }
        }
        #expect(bottomSnow > topSnow)   // 堆积在底，非顶（抓坐标翻转）
        #expect(bottomSnow > 0)
    }

    @Test("混合积雪收敛：连续 emit→land→step 雪量 plateau（不无限涨）")
    func hybridAccumulationPlateaus() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 200, gh = 150
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: gw, height: gh))
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 8192))
        engine.uploadTemperatures([Float](repeating: 0.2, count: gw * gh))   // 冷：不融，纯靠升华平衡
        particles.windX = 0.8
        let dt: Float = 1.0 / 60.0
        func caSnowCount() -> Int {
            engine.readback().reduce(0) { $0 + (FallingSandCell.species($1) == .snow ? 1 : 0) }
        }
        // cap=24 + 低升华 → 雪堆填到硬上限较慢，跑足 4800 帧让稳态显现。
        var mid = 0, late = 0
        for f in 0..<4800 {
            particles.emitTop(count: 8)
            particles.integrate(dt: dt)
            particles.land(cellBuffer: engine.pendingCellBuffer, occlusionBuffer: engine.occlusionBufferForLanding, columnDepthBuffer: engine.columnDepthBufferForLanding, dt: dt)
            engine.step(dt: dt)
            if f == 3600 { mid = caSnowCount() }
            if f == 4799 { late = caSnowCount() }
        }
        // 硬界：积雪 ≤ maxColumnDepth × 列数 ×1.3 容差（落地硬上限保证物理封顶，不无限涨）。
        #expect(late <= Int(Double(particles.maxColumnDepth * gw) * 1.3))
        // 后段平稳（3600→4800 帧增长小，已达稳态非持续爬升）。
        let growth = Double(late - mid) / Double(max(mid, 1))
        #expect(growth < 0.2)
    }
}
