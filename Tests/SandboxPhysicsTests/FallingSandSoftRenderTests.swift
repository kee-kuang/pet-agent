import Testing
import Metal
@testable import SandboxPhysics

/// 柔和渲染离屏自评：GPU 降雪场景 → soft pipeline 渲染到离屏纹理 → readback →
/// PNG，供 Read 目检柔边/真雪感。不靠屏幕截图（避开降采样/黑屏/区域越界坑）。
@Suite("FallingSand 柔和渲染自评")
struct FallingSandSoftRenderTests {
    @Test("柔和降雪场景 dump PNG")
    func softSnowRenderDump() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 100, h = 76
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        engine.uploadTemperatures([Float](repeating: 0.2, count: w * h))   // 冷：不融
        for f in 0..<160 {
            if f < 120 { engine.spawnTopRow(.snow, fillRatio: 0.10) }
            engine.step(dt: 1.0 / 30.0)
        }
        let soft = try #require(FallingSandRenderPipeline(device: device, pixelFormat: .rgba8Unorm, soft: true))
        let scale = 6
        let tw = w * scale, th = h * scale
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        let tex = try #require(device.makeTexture(descriptor: td))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        // 深色底便于目检雪的柔边（桌面上是叠在壁纸/窗口上）。
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        let cmd = try #require(queue.makeCommandBuffer())
        let enc = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        soft.encode(into: enc, cellBuffer: engine.cellBufferForRender, gridWidth: w, gridHeight: h)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: tw * th * 4)
        tex.getBytes(&px, bytesPerRow: tw * 4, from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        FallingSandPNG.writeRGBA(px, width: tw, height: th, to: "/tmp/fallingsand_soft.png")

        // 有内容（非全空）。
        let nonBg = px.indices.filter { $0 % 4 == 0 }.prefix(tw * th).contains { px[$0] > 30 }
        #expect(nonBg)
    }
}
