public struct SnowFrameRecord: Sendable, Equatable {
    public let frameIndex: Int
    public let pointCount: Int

    public init(frameIndex: Int, pointCount: Int) {
        self.frameIndex = frameIndex
        self.pointCount = pointCount
    }
}
