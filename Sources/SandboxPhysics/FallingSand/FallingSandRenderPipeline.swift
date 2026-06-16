import Metal

/// Render uniforms（fragment 用：网格尺寸算 cell + 积水湿亮 sheen）。12 字节。
public struct FallingSandRenderUniforms: Equatable, Sendable {
    public var gridWidth: UInt32
    public var gridHeight: UInt32
    /// 积水洼湿亮 sheen 强度（0..1）。下雨时→1，停雨回落到基线。
    public var wetness: Float
    public init(gridWidth: UInt32, gridHeight: UInt32, wetness: Float = 0) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.wetness = wetness
    }
}

/// Falling-sand 像素渲染管线。fullscreen 三角 + fragment 读 cell buffer 直出。
/// alpha 混合（透明叠在桌面上）。`pixelFormat` 在 init 指定（drawable=bgra8Unorm，
/// 离屏测试=rgba8Unorm）。
public final class FallingSandRenderPipeline {
    private let pipelineState: MTLRenderPipelineState

    /// `soft = true` 用高斯软覆盖 fragment（柔边真雪感）；false 用硬像素方块。
    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat, soft: Bool = true) {
        guard
            let library = try? device.makeLibrary(source: FallingSandRenderKernels.source, options: nil),
            let vertexFn = library.makeFunction(name: "fs_fullscreen_vertex"),
            let fragmentFn = library.makeFunction(name: soft ? "fs_soft_fragment" : "fs_pixel_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipelineState = state
    }

    /// 把 cell buffer 渲染进 encoder（调用方负责 begin/end render pass）。
    public func encode(
        into encoder: MTLRenderCommandEncoder,
        cellBuffer: MTLBuffer,
        gridWidth: Int,
        gridHeight: Int,
        wetness: Float = 0
    ) {
        var u = FallingSandRenderUniforms(gridWidth: UInt32(gridWidth), gridHeight: UInt32(gridHeight), wetness: wetness)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(cellBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FallingSandRenderUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
