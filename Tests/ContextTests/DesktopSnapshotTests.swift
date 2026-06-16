import Testing
@testable import Context

@Test("Empty desktop snapshot uses stable defaults")
func emptySnapshotUsesStableDefaults() {
    let snapshot = DesktopSnapshot.empty

    #expect(snapshot.displays.isEmpty)
    #expect(snapshot.activeSpaceIdentifier == "unknown")
    #expect(snapshot.cursorPosition == .zero)
    #expect(snapshot.visibleApplicationName == nil)
    #expect(snapshot.visibleWindows.isEmpty)
    #expect(snapshot.accessibilityIsTrusted == false)
}

@Test("Desktop snapshot sampler reflects current accessibility trust")
func desktopSnapshotSamplerReflectsCurrentAccessibilityTrust() {
    let sampler = DesktopSnapshotSampler(
        currentCursorPosition: { .zero },
        frontmostApplicationName: { nil },
        accessibilityIsTrusted: { true }
    )

    let snapshot = sampler.sample()

    #expect(snapshot.accessibilityIsTrusted)
}

@Test("Desktop snapshot sampler maps live desktop facts into a snapshot")
func desktopSnapshotSamplerMapsLiveDesktopFactsIntoASnapshot() {
    let expectedDisplays = [
        DisplaySnapshot(id: 1, width: 1440, height: 900),
        DisplaySnapshot(id: 2, width: 1728, height: 1117)
    ]
    let expectedVisibleWindows = [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 800, height: 600),
            workspace: 7
        ),
        VisibleWindowSnapshot(
            ownerName: "Xcode",
            bounds: Rect(origin: Point(x: 20, y: 40), width: 1200, height: 800),
            workspace: 7
        )
    ]
    let sampler = DesktopSnapshotSampler(
        currentDisplays: { expectedDisplays },
        activeSpaceIdentifier: { "space-7" },
        currentCursorPosition: { Point(x: 12, y: 34) },
        frontmostApplicationName: { "Finder" },
        currentVisibleWindows: { expectedVisibleWindows }
    )

    let snapshot = sampler.sample()

    #expect(snapshot.displays == expectedDisplays)
    #expect(snapshot.activeSpaceIdentifier == "space-7")
    #expect(snapshot.cursorPosition == Point(x: 12, y: 34))
    #expect(snapshot.visibleApplicationName == "Finder")
    #expect(snapshot.visibleWindows == expectedVisibleWindows)
}
