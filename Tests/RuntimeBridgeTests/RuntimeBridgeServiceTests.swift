import Testing
@testable import RuntimeBridge
import Context

@Test("Local runtime client reports Swift pet-motion capabilities")
func localRuntimeClientReportsCapabilities() async throws {
    let capabilities = try await LocalRuntimeClient().capabilities()

    #expect(capabilities.version == "swift-local")
    #expect(capabilities.supportsWeather == false)
}

@Test("Local runtime client tracks cursor + counts contacts")
func localRuntimeClientTracksCursorAndCountsContacts() async throws {
    let snapshot = DesktopSnapshot(
        cursorPosition: Point(x: 50, y: 50),
        visibleWindows: [
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 0, y: 0), width: 100, height: 100)
            ),
        ]
    )
    let input = RuntimeInput(
        deltaTime: 1.0 / 60.0,
        desktopSnapshot: snapshot,
        currentPetPose: PetPose(position: snapshot.cursorPosition),
        collisionGeometry: [CollisionRect(bounds: snapshot.visibleWindows[0].bounds)]
    )

    let output = try await LocalRuntimeClient().step(input)

    #expect(output.petPose.position == Point(x: 50, y: 50))
    #expect(output.contactCount == 1)
}

@Test("Local runtime client advances pet toward cursor at clamped tracking speed")
func localRuntimeClientAdvancesTowardCursor() async throws {
    // pet 远离光标:一帧只移动 maxStep = 160 * (1/60) ≈ 2.667 px,朝光标方向。
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 1000, y: 0))
    let input = RuntimeInput(
        deltaTime: 1.0 / 60.0,
        desktopSnapshot: snapshot,
        currentPetPose: PetPose(position: Point(x: 0, y: 0))
    )

    let output = try await LocalRuntimeClient().step(input)

    let expectedStep = 160.0 / 60.0
    #expect(abs(output.petPose.position.x - expectedStep) < 0.001)
    #expect(output.petPose.position.y == 0)
}

@Test("Runtime bridge service fetches capabilities through the local client")
func runtimeBridgeServiceFetchesCapabilities() async throws {
    let capabilities = try await RuntimeBridgeService(client: LocalRuntimeClient()).fetchCapabilities()

    #expect(capabilities.version == "swift-local")
}

@Test("Runtime bridge echoes cursor position through no-op runtime")
func runtimeBridgeEchoesCursorPosition() async throws {
    let snapshot = DesktopSnapshot(
        cursorPosition: Point(x: 12, y: 34)
    )

    let output = try await RuntimeBridgeService().step(snapshot: snapshot)

    #expect(output.petPose.position == Point(x: 12, y: 34))
    #expect(output.particleCount == 0)
}

@Test("No-op runtime client counts cursor contacts with collision geometry")
func noOpRuntimeClientCountsCursorContacts() async throws {
    let snapshot = DesktopSnapshot(
        cursorPosition: Point(x: 50, y: 50),
        visibleWindows: [
            // cursor inside
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 0, y: 0), width: 100, height: 100)
            ),
            // cursor outside
            VisibleWindowSnapshot(
                ownerName: "Xcode",
                bounds: Rect(origin: Point(x: 200, y: 0), width: 50, height: 50)
            ),
        ]
    )

    let output = try await RuntimeBridgeService().step(snapshot: snapshot)

    #expect(output.contactCount == 1)
}

@Test("Runtime bridge forwards accessibility trust flag from snapshot to input")
func runtimeBridgeForwardsAccessibilityTrustFlagFromSnapshotToInput() async throws {
    let snapshot = DesktopSnapshot(
        cursorPosition: Point(x: 0, y: 0),
        accessibilityIsTrusted: true
    )
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(snapshot: snapshot)

    let observed = try #require(await spy.lastInput)
    #expect(observed.accessibilityIsTrusted)
}

@Test("Runtime bridge flips top-origin window bounds into bottom-origin collision rects")
func runtimeBridgeFlipsTopOriginWindowBoundsIntoBottomOriginCollisionRects() async throws {
    let displays = [DisplaySnapshot(id: 0, width: 1200, height: 800)]
    let windows = [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 300, height: 200)
        ),
        VisibleWindowSnapshot(
            ownerName: "Xcode",
            bounds: Rect(origin: Point(x: 400, y: 100), width: 800, height: 600)
        ),
    ]
    let snapshot = DesktopSnapshot(displays: displays, visibleWindows: windows)
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(snapshot: snapshot, isSnowEnabled: true)

    let observed = try #require(await spy.lastInput)
    #expect(
        observed.collisionGeometry == [
            CollisionRect(bounds: Rect(origin: Point(x: 10, y: 580), width: 300, height: 200)),
            CollisionRect(bounds: Rect(origin: Point(x: 400, y: 100), width: 800, height: 600)),
        ]
    )
    #expect(observed.desktopSnapshot == snapshot)
    #expect(observed.isSnowEnabled)
}

@Test("Runtime bridge skips nearly-fullscreen wallpaper windows from collision geometry")
func runtimeBridgeSkipsNearlyFullscreenWallpaperWindowsFromCollisionGeometry() async throws {
    let displays = [DisplaySnapshot(id: 0, width: 1000, height: 800)]
    let windows = [
        // wallpaper/desktop background — covers the whole screen
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 0, y: 0), width: 1000, height: 800)
        ),
        // real app window
        VisibleWindowSnapshot(
            ownerName: "Xcode",
            bounds: Rect(origin: Point(x: 100, y: 100), width: 600, height: 400)
        ),
    ]
    let snapshot = DesktopSnapshot(displays: displays, visibleWindows: windows)
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(snapshot: snapshot, isSnowEnabled: true)

    let observed = try #require(await spy.lastInput)
    #expect(observed.collisionGeometry.count == 1)
    let rect = try #require(observed.collisionGeometry.first)
    #expect(rect.bounds.origin.x == 100)
    #expect(rect.bounds.width == 600)
}

@Test("Runtime bridge preserves CGWindowList z-order in collision geometry")
func runtimeBridgePreservesCGWindowListZOrderInCollisionGeometry() async throws {
    let displays = [DisplaySnapshot(id: 0, width: 1800, height: 1200)]
    let windows = [
        VisibleWindowSnapshot(ownerName: "Code", bounds: Rect(origin: Point(x: 100, y: 100), width: 800, height: 600)),
        VisibleWindowSnapshot(ownerName: "Finder", bounds: Rect(origin: Point(x: 500, y: 300), width: 400, height: 300)),
        VisibleWindowSnapshot(ownerName: "Safari", bounds: Rect(origin: Point(x: 200, y: 150), width: 700, height: 500)),
    ]
    let snapshot = DesktopSnapshot(
        displays: displays,
        visibleApplicationName: "Code",
        visibleWindows: windows
    )
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(snapshot: snapshot, isSnowEnabled: true)

    let observed = try #require(await spy.lastInput)
    #expect(observed.collisionGeometry.count == 3)
    // Width order mirrors the CGWindowList front-to-back order; the runtime's
    // occlusion check relies on this ordering.
    #expect(observed.collisionGeometry.map { $0.bounds.width } == [800.0, 400.0, 700.0])
}

@Test("Runtime bridge falls back to raw window bounds when display height is missing")
func runtimeBridgeFallsBackToRawWindowBoundsWhenDisplayHeightIsMissing() async throws {
    let windows = [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 300, height: 200)
        ),
    ]
    let snapshot = DesktopSnapshot(visibleWindows: windows)
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(snapshot: snapshot, isSnowEnabled: true)

    let observed = try #require(await spy.lastInput)
    #expect(
        observed.collisionGeometry == [
            CollisionRect(bounds: windows[0].bounds),
        ]
    )
}

@Test("Runtime bridge service threads previous particle count to client")
func runtimeBridgeServiceThreadsPreviousParticleCountToClient() async throws {
    let spy = SpyRuntimeClient()

    _ = try await RuntimeBridgeService(client: spy).step(
        snapshot: DesktopSnapshot(cursorPosition: .zero),
        isSnowEnabled: true,
        previousParticleCount: 7
    )

    let observed = try #require(await spy.lastInput)
    #expect(observed.previousParticleCount == 7)
}

private actor SpyRuntimeClient: RuntimeClient {
    private(set) var lastInput: RuntimeInput?

    func capabilities() async throws -> RuntimeCapabilities {
        RuntimeCapabilities()
    }

    func step(_ input: RuntimeInput) async throws -> RuntimeOutput {
        lastInput = input
        return .idle
    }
}
