import Testing
import Context
import RuntimeBridge

@Test("Presentation mapper converts runtime output into render state")
func presentationMapperConvertsRuntimeOutput() {
    let output = RuntimeOutput(
        petPose: PetPose(position: Point(x: 8, y: 13), rotation: 0.5),
        particleCount: 2,
        particles: [
            ParticlePosition(x: 1, y: 2),
            ParticlePosition(x: 3, y: 4),
        ],
        contactCount: 3,
        isSnowEnabled: true
    )

    let renderState = PresentationMapper().map(output)

    #expect(renderState.petPositionX == 8)
    #expect(renderState.petPositionY == 13)
    #expect(renderState.petRotation == 0.5)
    #expect(renderState.particleCount == 2)
    #expect(renderState.particles == [
        ParticlePosition(x: 1, y: 2),
        ParticlePosition(x: 3, y: 4),
    ])
    #expect(renderState.contactCount == 3)
    #expect(renderState.isSnowEnabled)
}
