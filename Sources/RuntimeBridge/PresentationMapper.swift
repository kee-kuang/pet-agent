// 运行时输出 → 业务可消费的渲染状态映射。住 RuntimeBridge(非 Rendering):只依赖
// RuntimeBridge 的 RuntimeOutput/ParticlePosition,无 Metal/AppKit —— 让业务层(Orchestrator)
// 消费它时不必拖进整个 Rendering(含 Metal)。原在 Rendering,后随模块边界清理上移。

public enum CompanionBehavior: Sendable, Equatable {
    case idle
    case tracking
    case snowing
}

public struct RenderState: Sendable, Equatable {
    public let petPositionX: Double
    public let petPositionY: Double
    public let petRotation: Double
    public let particleCount: Int
    public let particles: [ParticlePosition]
    public let contactCount: Int
    public let isSnowEnabled: Bool
    public let companionBehavior: CompanionBehavior

    public init(
        petPositionX: Double,
        petPositionY: Double,
        petRotation: Double,
        particleCount: Int,
        particles: [ParticlePosition] = [],
        contactCount: Int = 0,
        isSnowEnabled: Bool = false,
        companionBehavior: CompanionBehavior = .idle
    ) {
        self.petPositionX = petPositionX
        self.petPositionY = petPositionY
        self.petRotation = petRotation
        self.particleCount = particleCount
        self.particles = particles
        self.contactCount = contactCount
        self.isSnowEnabled = isSnowEnabled
        self.companionBehavior = companionBehavior
    }
}

public struct PresentationMapper: Sendable {
    public init() {}

    public func map(_ output: RuntimeOutput) -> RenderState {
        RenderState(
            petPositionX: output.petPose.position.x,
            petPositionY: output.petPose.position.y,
            petRotation: output.petPose.rotation,
            particleCount: output.particleCount,
            particles: output.particles,
            contactCount: output.contactCount,
            isSnowEnabled: output.isSnowEnabled
        )
    }
}
