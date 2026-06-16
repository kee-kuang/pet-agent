import Context
import Foundation

public struct RuntimeCapabilities: Sendable, Equatable {
    public let version: String
    public let supportsWeather: Bool

    public init(version: String = "runtime-dev", supportsWeather: Bool = false) {
        self.version = version
        self.supportsWeather = supportsWeather
    }
}

public struct PetPose: Sendable, Equatable {
    public let position: Point
    public let rotation: Double

    public init(position: Point = .zero, rotation: Double = 0) {
        self.position = position
        self.rotation = rotation
    }
}

public struct CollisionRect: Sendable, Equatable {
    public let bounds: Rect

    public init(bounds: Rect) {
        self.bounds = bounds
    }
}

extension CollisionRect {
    /// Build collision rects for the snow runtime / GPU compute kernel.
    ///
    /// Two pieces of bookkeeping live here so the Rust runtime and the
    /// GPU compute path share the same view of the world:
    /// - filter out wallpaper-sized windows (≥ 90% of display in both
    ///   dimensions) — otherwise Finder's desktop background would
    ///   clamp every snowflake to the top of the screen.
    /// - flip from CGWindow top-origin to runtime bottom-origin so the
    ///   y axis matches the simulation's "up = positive" convention.
    ///
    /// Output preserves `CGWindowList`'s front-to-back z-order so the
    /// caller can do per-column occlusion (a flake column passing through
    /// a foreground rect must skip back-rects sitting under it).
    public static func collection(from snapshot: DesktopSnapshot) -> [CollisionRect] {
        let worldWidth = snapshot.displays.first?.width ?? 0
        let worldHeight = snapshot.displays.first?.height ?? 0
        return snapshot.visibleWindows.compactMap { window in
            if worldWidth > 0 && worldHeight > 0 {
                let coversWidth = window.bounds.width >= worldWidth * 0.9
                let coversHeight = window.bounds.height >= worldHeight * 0.9
                if coversWidth && coversHeight {
                    return nil
                }
            }
            guard worldHeight > 0 else {
                return CollisionRect(bounds: window.bounds)
            }
            let topOriginY = window.bounds.origin.y
            let bottomOriginY = worldHeight - topOriginY - window.bounds.height
            return CollisionRect(bounds: Rect(
                origin: Point(x: window.bounds.origin.x, y: bottomOriginY),
                width: window.bounds.width,
                height: window.bounds.height
            ))
        }
    }

    /// Per-screen variant for the M.2 multi-monitor physics path.
    ///
    /// Filters `snapshot.visibleWindows` to those whose CGWindow-bounds center
    /// falls inside `screenFrame`, then converts global CGWindow coordinates
    /// (top-origin) to screen-local coordinates (bottom-origin):
    ///
    ///   localX = globalX - screen.frame.origin.x
    ///   localY = screen.frame.height - (globalY - screen.frame.origin.y) - window.height
    ///
    /// Wallpaper-sized windows are filtered against the screen's own frame.size
    /// (not `displays.first`), matching §2.4 of the multi-monitor design doc.
    ///
    /// - Parameters:
    ///   - snapshot: The current desktop snapshot.
    ///   - screen:   The NSRect of the target screen in global NSScreen
    ///               bottom-origin coordinates.
    /// - Returns: Collision rects in screen-local bottom-origin coordinates.
    public static func collection(
        from snapshot: DesktopSnapshot,
        screen screenFrame: CGRect
    ) -> [CollisionRect] {
        let screenW = Double(screenFrame.width)
        let screenH = Double(screenFrame.height)
        let screenOriginX = Double(screenFrame.origin.x)
        let screenOriginY = Double(screenFrame.origin.y)

        return snapshot.visibleWindows.compactMap { window in
            // Assign window to the screen whose frame contains the window's center.
            // CGWindow bounds are top-origin, but the center-x test is the same
            // since x-axes align between CGWindow and NSScreen global coordinates.
            // For y, CGWindow top-origin y=0 is NSScreen bottom-origin y=totalH.
            // We use the NSScreen frame (bottom-origin) to test containment:
            // convert CGWindow center to NSScreen bottom-origin y first.
            // Per §2.4: assign windows by x-band of their center point.
            // The x-axis is identical between CGWindow (top-origin) and NSScreen
            // (bottom-origin) global coordinates, so no conversion is needed.
            // Y-axis containment is intentionally skipped here: in practice,
            // every window on a screen has an x-center inside that screen's
            // x-band, which is sufficient for physical isolation.
            let cgCenterX = window.bounds.origin.x + window.bounds.width / 2
            let inXBand = cgCenterX >= screenOriginX && cgCenterX < screenOriginX + screenW
            guard inXBand else { return nil }

            // Wallpaper filter using the screen's own size.
            if screenW > 0 && screenH > 0 {
                let coversWidth  = window.bounds.width  >= screenW * 0.9
                let coversHeight = window.bounds.height >= screenH * 0.9
                if coversWidth && coversHeight { return nil }
            }

            // Global CGWindow (top-origin) → screen-local (bottom-origin):
            //   localX = globalX - screen.origin.x
            //   localY = screenH - (globalY - screen.origin.y) - windowH
            let localX = window.bounds.origin.x - screenOriginX
            let localY = screenH - (window.bounds.origin.y - screenOriginY) - window.bounds.height
            return CollisionRect(bounds: Rect(
                origin: Point(x: localX, y: localY),
                width: window.bounds.width,
                height: window.bounds.height
            ))
        }
    }
}

public struct ParticlePosition: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RuntimeInput: Sendable, Equatable {
    public let deltaTime: Double
    public let desktopSnapshot: DesktopSnapshot
    public let currentPetPose: PetPose
    public let collisionGeometry: [CollisionRect]
    public let isSnowEnabled: Bool
    public let previousParticleCount: Int
    public let previousParticles: [ParticlePosition]
    public let worldHeight: Double
    public let worldWidth: Double
    public let accessibilityIsTrusted: Bool
    /// When false, the runtime skips particle simulation entirely
    /// (output.particles will be empty). pet pose and contactCount
    /// are still computed. The GPU snow path sets this to false so
    /// the Rust runtime stops doing redundant CPU work — particles
    /// live in Metal compute buffers, not in the Rust runtime.
    public let wantsParticles: Bool

    public init(
        deltaTime: Double,
        desktopSnapshot: DesktopSnapshot,
        currentPetPose: PetPose = PetPose(),
        collisionGeometry: [CollisionRect] = [],
        isSnowEnabled: Bool = false,
        previousParticleCount: Int = 0,
        previousParticles: [ParticlePosition] = [],
        worldHeight: Double = 0,
        worldWidth: Double = 0,
        accessibilityIsTrusted: Bool = false,
        wantsParticles: Bool = true
    ) {
        self.deltaTime = deltaTime
        self.desktopSnapshot = desktopSnapshot
        self.currentPetPose = currentPetPose
        self.collisionGeometry = collisionGeometry
        self.isSnowEnabled = isSnowEnabled
        self.previousParticleCount = previousParticleCount
        self.previousParticles = previousParticles
        self.worldHeight = worldHeight
        self.worldWidth = worldWidth
        self.accessibilityIsTrusted = accessibilityIsTrusted
        self.wantsParticles = wantsParticles
    }
}

public struct RuntimeOutput: Sendable, Equatable {
    public let petPose: PetPose
    public let particleCount: Int
    public let particles: [ParticlePosition]
    public let contactCount: Int
    public let isSnowEnabled: Bool

    public init(
        petPose: PetPose = PetPose(),
        particleCount: Int = 0,
        particles: [ParticlePosition] = [],
        contactCount: Int = 0,
        isSnowEnabled: Bool = false
    ) {
        self.petPose = petPose
        self.particleCount = particleCount
        self.particles = particles
        self.contactCount = contactCount
        self.isSnowEnabled = isSnowEnabled
    }

    public static let idle = RuntimeOutput()
}

public enum RuntimeClientError: Error, Equatable {
    case unavailable(String)
}
