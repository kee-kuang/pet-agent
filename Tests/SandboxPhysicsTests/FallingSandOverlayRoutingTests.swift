import Metal
import Testing
@testable import SandboxPhysics
@testable import Rendering

/// MetalSnowOverlayView 的 falling-sand 分发回归（falling-sand 是唯一雪路径）。锁死：
/// - useFallingSandMode on → driver 被 tick 并渲染
/// - useFallingSandMode off → encodeFrame 不碰 driver（不渲染）
@MainActor
@Suite("FallingSand overlay 分发")
struct FallingSandOverlayRoutingTests {
    private func offscreen(_ device: MTLDevice, _ size: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return try #require(device.makeTexture(descriptor: d))
    }

    private func clearPass(_ tex: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = tex
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        p.colorAttachments[0].storeAction = .store
        return p
    }

    @Test("useFallingSandMode on → driver 被 tick 并渲染")
    func modeOnRoutesToFallingSand() throws {
        let view = try #require(MetalSnowOverlayView.make(frame: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let device = try #require(view.device)
        let queue = try #require(device.makeCommandQueue())
        let driver = try #require(FallingSandDriver(
            device: device, queue: queue, gridWidth: 16, gridHeight: 16, pixelFormat: .bgra8Unorm))
        driver.engine.upload([UInt32](repeating: FallingSandCell.make(.snow, ra: 120), count: 16 * 16))
        view.attachFallingSandDriver(driver)
        view.useFallingSandMode = true

        let tex = try offscreen(device, 32)
        let cmd = try #require(queue.makeCommandBuffer())
        view.encodeFrame(into: cmd, renderPassDescriptor: clearPass(tex))
        cmd.commit()
        cmd.waitUntilCompleted()

        #expect(cmd.error == nil)
        #expect(driver.tickCount == 1)   // 被调用
    }

    @Test("useFallingSandMode off → encodeFrame 不碰 driver")
    func modeOffSkipsFallingSand() throws {
        let view = try #require(MetalSnowOverlayView.make(frame: CGRect(x: 0, y: 0, width: 16, height: 16)))
        let device = try #require(view.device)
        let queue = try #require(device.makeCommandQueue())
        let fsDriver = try #require(FallingSandDriver(
            device: device, queue: queue, gridWidth: 8, gridHeight: 8, pixelFormat: .bgra8Unorm))
        view.attachFallingSandDriver(fsDriver)
        // 默认 useFallingSandMode == false

        let tex = try offscreen(device, 16)
        let cmd = try #require(queue.makeCommandBuffer())
        view.encodeFrame(into: cmd, renderPassDescriptor: clearPass(tex))
        cmd.commit()
        cmd.waitUntilCompleted()

        #expect(view.useFallingSandMode == false)
        #expect(fsDriver.tickCount == 0)   // falling-sand 未被调用
    }
}
