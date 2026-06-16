import AppKit
import Foundation
import Metal
import Testing
@testable import Rendering

// MARK: - OrbMetalRendererTests
//
// Cover the pure-logic surfaces of PetRenderer / OrbMetalRenderer so the
// suite stays useful in headless CI (no usable MTLDevice). Tests that need
// the GPU short-circuit gracefully when `MTLCreateSystemDefaultDevice()`
// returns nil; on a Mac with Metal they exercise the real init path.

@MainActor
private func hasMetalDevice() -> Bool {
    return SharedMetal.device != nil
}

@Suite("OrbMetalRenderer — state → uniforms mapping + lifecycle")
@MainActor
struct OrbMetalRendererTests {

    // MARK: - State → uniforms mapping

    @Test("OrbUniforms.target produces docs-spec hue for each state")
    func mappingProducesExpectedHue() {
        #expect(OrbUniforms.target(for: .idle).colorHue == 0.55)
        #expect(OrbUniforms.target(for: .watching).colorHue == 0.50)
        #expect(OrbUniforms.target(for: .thinking).colorHue == 0.75)
        #expect(OrbUniforms.target(for: .talking).colorHue == 0.30)
        #expect(OrbUniforms.target(for: .confused).colorHue == 0.05)
    }

    @Test("OrbUniforms.target produces docs-spec flow rate for each state")
    func mappingProducesExpectedFlow() {
        #expect(OrbUniforms.target(for: .idle).flowSpeed == 0.3)
        #expect(OrbUniforms.target(for: .watching).flowSpeed == 0.5)
        #expect(OrbUniforms.target(for: .thinking).flowSpeed == 1.5)
        #expect(OrbUniforms.target(for: .talking).flowSpeed == 0.8)
        #expect(OrbUniforms.target(for: .confused).flowSpeed == 2.0)
    }

    @Test("OrbUniforms.target squash is only non-1.0 during .talking")
    func mappingSquashOnlyInTalking() {
        #expect(OrbUniforms.target(for: .idle).squashY == 1.0)
        #expect(OrbUniforms.target(for: .watching).squashY == 1.0)
        #expect(OrbUniforms.target(for: .thinking).squashY == 1.0)
        #expect(OrbUniforms.target(for: .talking).squashY == 0.92)
        #expect(OrbUniforms.target(for: .confused).squashY == 1.0)
    }

    @Test("OrbUniforms.target squashX is 1.0 for all five chat states")
    func mappingSquashXAlwaysOneForChatStates() {
        // squashX is reserved for physics-velocity coupling only — chat
        // states don't drive it.
        for state: PetEmotionState in [.idle, .watching, .thinking, .talking, .confused] {
            #expect(OrbUniforms.target(for: state).squashX == 1.0,
                    "expected squashX == 1.0 for state \(state)")
        }
    }

    @Test("OrbUniforms equality includes both squashX and squashY")
    func equalityCoversBothSquashAxes() {
        let base = OrbUniforms(colorHue: 0.5, flowSpeed: 0.5, vortexIntensity: 0.3,
                               squashX: 1.0, squashY: 1.0)
        let differX = OrbUniforms(colorHue: 0.5, flowSpeed: 0.5, vortexIntensity: 0.3,
                                  squashX: 1.1, squashY: 1.0)
        let differY = OrbUniforms(colorHue: 0.5, flowSpeed: 0.5, vortexIntensity: 0.3,
                                  squashX: 1.0, squashY: 0.92)
        #expect(base != differX)
        #expect(base != differY)
        #expect(base == OrbUniforms(colorHue: 0.5, flowSpeed: 0.5, vortexIntensity: 0.3,
                                    squashX: 1.0, squashY: 1.0))
    }

    @Test("eased(toward:dt:) interpolates squashX toward target")
    func easedConvergesSquashX() {
        let from = OrbUniforms(colorHue: 0.5, flowSpeed: 0.0, vortexIntensity: 0.0,
                               squashX: 1.0, squashY: 1.0)
        let to = OrbUniforms(colorHue: 0.5, flowSpeed: 0.0, vortexIntensity: 0.0,
                             squashX: 1.15, squashY: 0.85)
        // One small tick: should move *toward* but not reach the target.
        let stepped = from.eased(toward: to, dt: 1.0 / 60.0)
        #expect(stepped.squashX > from.squashX)
        #expect(stepped.squashX < to.squashX)
        // Many ticks: should converge close to the target.
        var current = from
        for _ in 0..<20 {
            current = current.eased(toward: to, dt: 1.0 / 60.0)
        }
        #expect(abs(current.squashX - to.squashX) < 0.02)
    }

    @Test("OrbUniforms.target vortex intensity increases with arousal")
    func mappingVortexOrdering() {
        let idle = OrbUniforms.target(for: .idle).vortexIntensity
        let watching = OrbUniforms.target(for: .watching).vortexIntensity
        let thinking = OrbUniforms.target(for: .thinking).vortexIntensity
        let confused = OrbUniforms.target(for: .confused).vortexIntensity
        #expect(idle < watching)
        #expect(watching < thinking)
        #expect(thinking < confused)
        #expect(confused == 1.0)
    }

    // MARK: - Ease-out interpolation

    @Test("eased(toward:dt:) does not overshoot the target in one step")
    func easedDoesNotOvershoot() {
        let from = OrbUniforms.target(for: .idle)
        let to = OrbUniforms.target(for: .thinking)
        let stepped = from.eased(toward: to, dt: 1.0 / 60.0)
        #expect(stepped.flowSpeed > from.flowSpeed)
        #expect(stepped.flowSpeed < to.flowSpeed)
    }

    @Test("eased(toward:dt:) converges within ~0.25s")
    func easedConvergesQuickly() {
        var current = OrbUniforms.target(for: .idle)
        let target = OrbUniforms.target(for: .confused)
        for _ in 0..<16 {
            current = current.eased(toward: target, dt: 1.0 / 60.0)
        }
        let remaining = abs(current.flowSpeed - target.flowSpeed)
        let total = abs(OrbUniforms.target(for: .idle).flowSpeed - target.flowSpeed)
        #expect(remaining / total < 0.10,
                "expected < 10% of distance left, got \(remaining / total)")
    }

    @Test("eased(toward:dt:) is a no-op when dt is 0")
    func easedNoopOnZeroDt() {
        let from = OrbUniforms.target(for: .talking)
        let to = OrbUniforms.target(for: .confused)
        let stepped = from.eased(toward: to, dt: 0)
        #expect(stepped == from)
    }

    @Test("eased hue takes the short arc across the 0/1 boundary")
    func easedHueShortArc() {
        // 0.95 → 0.05 should move forward through 1.0 → 0.0, not back through 0.5.
        let from = OrbUniforms(colorHue: 0.95, flowSpeed: 0, vortexIntensity: 0, squashY: 1.0)
        let to   = OrbUniforms(colorHue: 0.05, flowSpeed: 0, vortexIntensity: 0, squashY: 1.0)
        let stepped = from.eased(toward: to, dt: 1.0 / 60.0)
        // After a short tick we're either still in the upper arc (> 0.95)
        // or already wrapped (< 0.05) — never in the middle of the long arc.
        #expect(stepped.colorHue > 0.95 || stepped.colorHue < 0.05,
                "expected short arc movement; got \(stepped.colorHue)")
    }

    // MARK: - Shader source sanity

    @Test("Shader source contains the orb_vertex and orb_fragment entry points")
    func shaderSourceHasEntryPoints() {
        #expect(OrbMetalRenderer.shaderSource.contains("orb_vertex"))
        #expect(OrbMetalRenderer.shaderSource.contains("orb_fragment"))
        #expect(OrbMetalRenderer.shaderSource.contains("OrbUniforms"))
    }

    @Test("Shader source binds the pile mask texture + sampler")
    func shaderSourceHasPileMaskBinding() {
        let source = OrbMetalRenderer.shaderSource
        // Texture / sampler parameters must be on the fragment entry point.
        #expect(source.contains("texture2d<float, access::sample> pileMask"))
        #expect(source.contains("sampler maskSampler"))
        #expect(source.contains("[[texture(0)]]"))
        #expect(source.contains("[[sampler(0)]]"))
        // Warm refraction tint constant is the documented oklch-derived RGB.
        #expect(source.contains("float3(1.0, 0.92, 0.78)"))
        // Mix is gated at 60% intensity so the orb cannot wash out completely.
        #expect(source.contains("0.6"))
    }

    // MARK: - Protocol conformance (compile-time)

    @Test("OrbMetalRenderer conforms to PetRenderer")
    func conformsToProtocol() {
        // If conformance breaks, this stops compiling.
        let t: PetRenderer.Type = OrbMetalRenderer.self
        #expect(String(describing: t).contains("OrbMetalRenderer"))
    }

    // MARK: - GPU-gated lifecycle tests

    @Test("OrbMetalRenderer initializes when Metal is available, view sized")
    func metalInitProducesSizedView() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else {
            Issue.record("OrbMetalRenderer init returned nil despite Metal device being present")
            return
        }
        #expect(renderer.contentLayer.frame.width >= 1)
        #expect(renderer.contentLayer.frame.height >= 1)
    }

    @Test("updateForState mutates the target uniforms across all five states")
    func updateForStateMutatesTarget() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else { return }
        // After init the target is .idle.
        #expect(renderer.targetUniformsForTesting.colorHue == OrbUniforms.target(for: .idle).colorHue)
        for state: PetEmotionState in [.watching, .thinking, .talking, .confused, .idle] {
            renderer.updateForState(state)
            let expected = OrbUniforms.target(for: state)
            #expect(renderer.targetUniformsForTesting == expected)
        }
    }

    // MARK: - Physical squash

    @Test("updateForVelocity(.zero) restores chat-state base")
    func updateForVelocityZeroRestoresBase() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else { return }
        renderer.updateForState(.idle)
        // Apply a high velocity then release — target must snap back to idle base.
        renderer.updateForVelocity(CGVector(dx: 500.0, dy: 0.0))
        #expect(renderer.targetUniformsForTesting.squashX != 1.0,
                "expected non-rest squashX while velocity is applied")
        renderer.updateForVelocity(.zero)
        #expect(renderer.targetUniformsForTesting == OrbUniforms.target(for: .idle))
    }

    @Test("updateForVelocity stretches X for horizontal drag")
    func updateForVelocityStretchesXForHorizontalDrag() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else { return }
        renderer.updateForState(.idle)
        // Pure horizontal velocity at the cap should stretch X (squashX > 1)
        // and compress Y (squashY < 1), since drag direction = +X axis.
        renderer.updateForVelocity(CGVector(dx: 600.0, dy: 0.0))
        let t = renderer.targetUniformsForTesting
        #expect(t.squashX > 1.0, "expected horizontal drag to stretch X, got \(t.squashX)")
        #expect(t.squashY < 1.0, "expected horizontal drag to compress Y, got \(t.squashY)")
        // Hard cap so we never pancake the orb beyond ~15%.
        #expect(t.squashX <= 1.16)
        #expect(t.squashY >= 0.84)
    }

    @Test("updateForVelocity stretches Y for vertical drag, preserves talking burst")
    func updateForVelocityStretchesYAndPreservesTalking() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else { return }
        // .talking has a built-in squashY=0.92 burst. Vertical drag should
        // stretch Y *relative* to that base — physics doesn't erase emotion,
        // it multiplies onto it.
        renderer.updateForState(.talking)
        renderer.updateForVelocity(CGVector(dx: 0.0, dy: 600.0))
        let t = renderer.targetUniformsForTesting
        #expect(t.squashY > 0.92 * 1.0,
                "expected vertical drag to lift Y above the talking base, got \(t.squashY)")
        // X should compress because the drag is vertical (orthogonal axis).
        #expect(t.squashX < 1.0, "expected vertical drag to compress X, got \(t.squashX)")
    }

    // MARK: - Pile mask binding

    @Test("setPileMaskTexture(nil) is a no-op on a fresh renderer")
    func setPileMaskTextureNilIsSafe() {
        guard hasMetalDevice() else { return }
        guard let renderer = OrbMetalRenderer() else { return }
        // Default state — already nil. Calling the setter with nil must not
        // throw, crash, or perturb any other observable state.
        renderer.setPileMaskTexture(nil)
        // updateForState must still function — confirms the renderer is
        // alive and the binding path did not disturb the rest of the API.
        renderer.updateForState(.thinking)
        #expect(renderer.targetUniformsForTesting == OrbUniforms.target(for: .thinking))
    }

    @Test("setPileMaskTexture accepts a 1×1 dummy MTLTexture and round-trips to nil")
    func setPileMaskTextureAcceptsDummy() {
        guard hasMetalDevice() else { return }
        guard
            let device = SharedMetal.device,
            let renderer = OrbMetalRenderer(device: device)
        else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let dummy = device.makeTexture(descriptor: desc) else {
            Issue.record("failed to allocate a 1×1 dummy MTLTexture")
            return
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBufferPointer { buffer in
            dummy.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: 4
            )
        }

        // Attach, then detach — neither call must throw or destabilise the
        // renderer's other surfaces.
        renderer.setPileMaskTexture(dummy)
        renderer.setPileMaskTexture(nil)
        renderer.updateForState(.talking)
        #expect(renderer.targetUniformsForTesting == OrbUniforms.target(for: .talking))
    }
}
