import Context
import Foundation

private final class CollisionLogState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSignature: String = ""

    func shouldLog(signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if signature == lastSignature {
            return false
        }
        lastSignature = signature
        return true
    }
}

private let collisionLogState = CollisionLogState()

public protocol RuntimeClient: Sendable {
    func capabilities() async throws -> RuntimeCapabilities
    func step(_ input: RuntimeInput) async throws -> RuntimeOutput
}

public actor NoOpRuntimeClient: RuntimeClient {
    public init() {}

    public func capabilities() async throws -> RuntimeCapabilities {
        RuntimeCapabilities()
    }

    public func step(_ input: RuntimeInput) async throws -> RuntimeOutput {
        let cursor = input.desktopSnapshot.cursorPosition
        let pose = input.currentPetPose
        let contacts = input.collisionGeometry.reduce(into: 0) { count, rect in
            if Self.contains(rect: rect.bounds, point: cursor) {
                count += 1
            }
        }
        // NoOp client honours wantsParticles symmetrically with the FFI
        // client so callers see consistent behaviour across clients.
        _ = input.wantsParticles
        return RuntimeOutput(
            petPose: pose,
            particleCount: 0,
            contactCount: contacts,
            isSnowEnabled: input.isSnowEnabled
        )
    }

    private static func contains(rect: Rect, point: Point) -> Bool {
        let minX = rect.origin.x
        let minY = rect.origin.y
        return point.x >= minX
            && point.x <= minX + rect.width
            && point.y >= minY
            && point.y <= minY + rect.height
    }
}

public struct RuntimeBridgeService: Sendable {
    private let client: any RuntimeClient

    public init(client: any RuntimeClient = LocalRuntimeClient()) {
        self.client = client
    }

    static func logCollisionInputOnce(
        worldWidth: Double,
        worldHeight: Double,
        windows: [VisibleWindowSnapshot]
    ) {
        let signature = "\(worldWidth)x\(worldHeight)|" + windows.map {
            "\($0.ownerName)@\($0.bounds.origin.x),\($0.bounds.origin.y)\($0.bounds.width)x\($0.bounds.height)"
        }.joined(separator: ";")
        guard collisionLogState.shouldLog(signature: signature) else {
            return
        }
        let path = "/tmp/petagent-snow-diagnostics.log"
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        var lines = "[snow] bridge worldSize=\(worldWidth)x\(worldHeight) windows=\(windows.count)\n"
        for (index, window) in windows.enumerated() {
            lines += "[snow]   win[\(index)] owner=\(window.ownerName) bounds=(x=\(window.bounds.origin.x), y=\(window.bounds.origin.y), w=\(window.bounds.width), h=\(window.bounds.height))\n"
        }
        if let data = lines.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    public func fetchCapabilities() async throws -> RuntimeCapabilities {
        try await client.capabilities()
    }

    public func step(
        snapshot: DesktopSnapshot,
        deltaTime: Double = 1.0 / 60.0,
        currentPetPose: PetPose? = nil,
        isSnowEnabled: Bool = false,
        previousParticleCount: Int = 0,
        previousParticles: [ParticlePosition] = [],
        wantsParticles: Bool = true
    ) async throws -> RuntimeOutput {
        let worldHeight = snapshot.displays.first?.height ?? 0
        let worldWidth = snapshot.displays.first?.width ?? 0
        if ProcessInfo.processInfo.environment["PETAGENT_SNOW_DIAGNOSTICS"] == "1" {
            RuntimeBridgeService.logCollisionInputOnce(
                worldWidth: worldWidth,
                worldHeight: worldHeight,
                windows: snapshot.visibleWindows
            )
        }
        // Preserve CGWindowList's front-to-back z-order so the GPU snow
        // compute can discard occluded top edges per particle column.
        // Wallpaper-sized windows (Finder desktop background) get filtered
        // inside `CollisionRect.collection(from:)` and the top→bottom origin
        // flip happens there too, so the pet-motion client and the GPU snow
        // compute see the same geometry.
        let geometry = CollisionRect.collection(from: snapshot)
        let input = RuntimeInput(
            deltaTime: deltaTime,
            desktopSnapshot: snapshot,
            currentPetPose: currentPetPose ?? PetPose(position: snapshot.cursorPosition),
            collisionGeometry: geometry,
            isSnowEnabled: isSnowEnabled,
            previousParticleCount: previousParticleCount,
            previousParticles: previousParticles,
            worldHeight: snapshot.displays.first?.height ?? 0,
            worldWidth: snapshot.displays.first?.width ?? 0,
            accessibilityIsTrusted: snapshot.accessibilityIsTrusted,
            wantsParticles: wantsParticles
        )
        let output = try await client.step(input)
        return RuntimeOutput(
            petPose: output.petPose,
            particleCount: output.particleCount,
            particles: output.particles,
            contactCount: output.contactCount,
            isSnowEnabled: isSnowEnabled || output.isSnowEnabled
        )
    }
}
