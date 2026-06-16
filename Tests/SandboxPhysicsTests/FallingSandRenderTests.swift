import Testing
import Metal
@testable import SandboxPhysics

/// 像素渲染 pass 离屏验证。填满单一元素，渲染到 RGBA8 离屏纹理读回，断言
/// 颜色映射正确（snow 白 / water 蓝 / empty 透明）。均匀填充 → 朝向无关。
/// on-screen 朝向正确性在跑 app 时目检。
@Suite("FallingSandRender 像素渲染")
struct FallingSandRenderTests {
    private func renderFilled(_ species: FallingSandSpecies, ra: UInt8,
                              device: MTLDevice, queue: MTLCommandQueue,
                              w: Int, h: Int) throws -> [UInt8] {
        let engine = try #require(FallingSandGPUEngine(device: device, queue: queue, width: w, height: h))
        let fill: [UInt32] = species == .empty
            ? [UInt32](repeating: 0, count: w * h)
            : [UInt32](repeating: FallingSandCell.make(species, ra: ra), count: w * h)
        engine.upload(fill)
        let pipeline = try #require(FallingSandRenderPipeline(device: device, pixelFormat: .rgba8Unorm))

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        let tex = try #require(device.makeTexture(descriptor: texDesc))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        let cmd = try #require(queue.makeCommandBuffer())
        let enc = try #require(cmd.makeRenderCommandEncoder(descriptor: rpd))
        pipeline.encode(into: enc, cellBuffer: engine.cellBufferForRender, gridWidth: w, gridHeight: h)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    @Test("全 snow → 白色不透明")
    func snowRendersWhite() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 8, h = 8
        let px = try renderFilled(.snow, ra: 100, device: device, queue: queue, w: w, h: h)
        let o = ((h / 2) * w + w / 2) * 4
        #expect(px[o + 3] > 200)   // alpha 高
        #expect(px[o] > 200)       // r 高（白）
        #expect(px[o + 1] > 200)   // g 高
        #expect(px[o + 2] > 200)   // b 高
    }

    @Test("全 empty → 全透明")
    func emptyRendersTransparent() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 8, h = 8
        let px = try renderFilled(.empty, ra: 0, device: device, queue: queue, w: w, h: h)
        for i in stride(from: 3, to: px.count, by: 4) { #expect(px[i] == 0) }   // alpha 全 0
    }

    @Test("全 water → 蓝色（b > r）")
    func waterRendersBlue() throws {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let w = 8, h = 8
        let px = try renderFilled(.water, ra: 100, device: device, queue: queue, w: w, h: h)
        let o = ((h / 2) * w + w / 2) * 4
        #expect(px[o + 3] > 180)        // alpha 较高（water 0.92）
        #expect(px[o + 2] > px[o])      // b > r（蓝）
    }
}
