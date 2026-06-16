import Testing
import Metal
import simd
@testable import SandboxPhysics

/// 飞行粒子渲染离屏自评：emit + 积分几帧 → 渲染粒子层到离屏纹理 → PNG。
/// 目检大小不一的软圆雪花（根治「做不大/随机大小」的视觉验证）。
@Suite("FallingSand 粒子渲染")
struct FallingSandParticleRenderTests {
    @Test("粒子层 dump PNG（大小不一软圆）")
    func particleLayerDump() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 160, gh = 120
        let particles = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 2048))
        particles.windX = 0.6
        particles.sizeMin = 1
        particles.sizeMax = 7
        // 多批发射 + 积分，让粒子散布全屏
        for _ in 0..<40 {
            particles.emitTop(count: 12)
            particles.integrate(dt: 1.0 / 60.0)
        }
        let pipeline = try #require(FallingSandParticleRenderPipeline(device: device, pixelFormat: .rgba8Unorm))

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
        pipeline.encode(into: enc, particleBuffer: particles.buffer, instanceCount: particles.capacity, gridWidth: gw, gridHeight: gh)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: tw * th * 4)
        tex.getBytes(&px, bytesPerRow: tw * 4, from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        FallingSandPNG.writeRGBA(px, width: tw, height: th, to: "/tmp/fallingsand_particles.png")

        // 有亮像素（粒子画出来了）
        let nonBg = stride(from: 0, to: tw * th * 4, by: 4).contains { px[$0] > 120 }
        #expect(nonBg)
    }
}
