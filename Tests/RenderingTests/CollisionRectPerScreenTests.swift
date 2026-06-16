import AppKit
import Testing
@testable import RuntimeBridge
import Context

// MARK: - Helpers

/// Build a DesktopSnapshot with one display and one or more visible windows.
private func makeSnapshot(
    displayID: UInt32 = 1,
    displayWidth: Double = 1920,
    displayHeight: Double = 1080,
    windows: [VisibleWindowSnapshot] = []
) -> DesktopSnapshot {
    DesktopSnapshot(
        displays: [DisplaySnapshot(id: displayID, width: displayWidth, height: displayHeight)],
        cursorPosition: .zero,
        visibleWindows: windows
    )
}

/// Build a fake NSScreen-like description structure for use in per-screen tests.
/// Since we cannot instantiate NSScreen in tests, we carry `frame` as a plain NSRect.
private struct FakeScreen {
    let displayID: CGDirectDisplayID
    let frame: NSRect // global NSScreen coordinates (bottom-origin)
}

// MARK: - Tests

// ---------------------------------------------------------------------------
// Test 1: window on screen A → only A's collisionRects contain it, B does not
// ---------------------------------------------------------------------------
@Test("Window in screen A global coords appears only in A per-screen collection")
func windowOnScreenAAppearsOnlyInScreenACollection() {
    // Screen A: left display (x: 0..1920, y: 0..1080)
    let screenA = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    // Screen B: right display (x: 1920..3840, y: 0..1080)
    let screenB = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    // Window sitting fully in screen A (global top-origin CGWindow coords):
    // center = (960, 400) global  →  inside screenA.
    let window = VisibleWindowSnapshot(
        ownerName: "TestApp",
        bounds: Rect(origin: Point(x: 860, y: 350), width: 200, height: 100)
    )
    let snapshot = makeSnapshot(displayWidth: 1920, displayHeight: 1080, windows: [window])

    let rectsA = CollisionRect.collection(from: snapshot, screen: screenA)
    let rectsB = CollisionRect.collection(from: snapshot, screen: screenB)

    #expect(rectsA.count == 1, "Screen A should contain the window")
    #expect(rectsB.count == 0, "Screen B should not contain the window")
}

// ---------------------------------------------------------------------------
// Test 2: window center crossing boundary → belongs to screen containing center
// ---------------------------------------------------------------------------
@Test("Window whose center is in screen B is assigned to B not A")
func windowCenterInScreenBAssignedToB() {
    // Screen A: x 0..1920
    let screenA = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    // Screen B: x 1920..3840
    let screenB = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    // Window overlaps both A and B but center is in B (globalX center = 1950)
    let window = VisibleWindowSnapshot(
        ownerName: "Straddler",
        bounds: Rect(origin: Point(x: 1850, y: 400), width: 200, height: 100)
    )
    // center.x = 1850 + 100 = 1950 → inside screenB (origin 1920)
    let snapshot = makeSnapshot(displayWidth: 3840, displayHeight: 1080, windows: [window])

    let rectsA = CollisionRect.collection(from: snapshot, screen: screenA)
    let rectsB = CollisionRect.collection(from: snapshot, screen: screenB)

    #expect(rectsA.count == 0, "Window center is in B → A should not claim it")
    #expect(rectsB.count == 1, "Window center is in B → B should claim it")
}

// ---------------------------------------------------------------------------
// Test 3: global→local coordinate transform math (§2.4 critical verify)
//
// macOS NSScreen: bottom-origin, Y increases upward.
// CGWindow bounds: top-origin, Y increases downward.
//
// Given:
//   screenB origin = (1920, 0), height = 1080
//   window global (CGWindow top-origin): x=2000, y=100, w=300, h=200
//
// Expected local coords (bottom-origin):
//   localX = 2000 - 1920 = 80
//   localY = 1080 - (100 - 0) - 200 = 1080 - 100 - 200 = 780
// ---------------------------------------------------------------------------
@Test("Global-to-local coordinate transform math is correct (§2.4)")
func globalToLocalCoordinateTransformIsCorrect() {
    let screenB = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    // Window in CGWindow global top-origin coords
    let window = VisibleWindowSnapshot(
        ownerName: "TransformTest",
        bounds: Rect(origin: Point(x: 2000, y: 100), width: 300, height: 200)
    )
    // center.x = 2000 + 150 = 2150 → in screenB (1920..3840) ✓
    // center.y (CGWindow top-origin) = 100 + 100 = 200
    //   → in NSScreen bottom-origin, y = 1080 - 200 = 880, which is ≥0 and <1080 ✓
    let snapshot = makeSnapshot(displayWidth: 3840, displayHeight: 1080, windows: [window])

    let rects = CollisionRect.collection(from: snapshot, screen: screenB)
    #expect(rects.count == 1)

    let rect = rects[0]
    #expect(abs(rect.bounds.origin.x - 80) < 0.001,
            "localX should be globalX - screenOriginX = 2000 - 1920 = 80, got \(rect.bounds.origin.x)")
    #expect(abs(rect.bounds.origin.y - 780) < 0.001,
            "localY should be screenH - (globalY - screenOriginY) - windowH = 1080 - (100-0) - 200 = 780, got \(rect.bounds.origin.y)")
    #expect(abs(rect.bounds.width - 300) < 0.001)
    #expect(abs(rect.bounds.height - 200) < 0.001)
}

// ---------------------------------------------------------------------------
// Test 4: per-screen wallpaper filter uses the screen's own frame.size
// ---------------------------------------------------------------------------
@Test("Wallpaper-sized window filtered against its own screen size not displays.first")
func wallpaperFilterUsesScreenOwnSize() {
    // Secondary screen is smaller: 1280x800
    let screenB = NSRect(x: 1920, y: 0, width: 1280, height: 800)

    // Window exactly covering 95% of screenB → should be filtered as wallpaper
    let wallpaperWindow = VisibleWindowSnapshot(
        ownerName: "Finder",
        bounds: Rect(origin: Point(x: 1920, y: 0), width: 1280 * 0.95, height: 800 * 0.95)
    )
    // center.x = 1920 + 1280*0.95/2 = 1920 + 608 = 2528 → inside screenB ✓
    // Even if displays.first is 1920x1080, this window covers 63%×70% of it → NOT filtered
    // But it covers 95%×95% of screenB → MUST be filtered
    let snapshot = DesktopSnapshot(
        displays: [DisplaySnapshot(id: 1, width: 1920, height: 1080)], // main screen, NOT screenB
        cursorPosition: .zero,
        visibleWindows: [wallpaperWindow]
    )

    let rects = CollisionRect.collection(from: snapshot, screen: screenB)

    #expect(rects.count == 0,
            "Wallpaper window should be filtered using the screen's own frame size, not displays.first")
}

// ---------------------------------------------------------------------------
// Test 5: single-screen case matches original collection(from:) behaviour
// ---------------------------------------------------------------------------
@Test("Single-screen per-screen collection matches original collection(from:) result")
func singleScreenPerScreenMatchesOriginal() {
    let screenA = NSRect(x: 0, y: 0, width: 1920, height: 1080)

    let windows = [
        VisibleWindowSnapshot(
            ownerName: "App",
            bounds: Rect(origin: Point(x: 100, y: 200), width: 400, height: 300)
        ),
        VisibleWindowSnapshot(
            ownerName: "ToolWindow",
            bounds: Rect(origin: Point(x: 500, y: 400), width: 200, height: 150)
        )
    ]
    let snapshot = makeSnapshot(displayWidth: 1920, displayHeight: 1080, windows: windows)

    let perScreen = CollisionRect.collection(from: snapshot, screen: screenA)
    let original = CollisionRect.collection(from: snapshot)

    // Both should produce same count and same y-flipped coordinates
    #expect(perScreen.count == original.count,
            "Per-screen (single screen at origin 0,0) should match original")
    for (ps, orig) in zip(perScreen, original) {
        #expect(abs(ps.bounds.origin.x - orig.bounds.origin.x) < 0.001)
        #expect(abs(ps.bounds.origin.y - orig.bounds.origin.y) < 0.001)
        #expect(abs(ps.bounds.width - orig.bounds.width) < 0.001)
        #expect(abs(ps.bounds.height - orig.bounds.height) < 0.001)
    }
}

// ---------------------------------------------------------------------------
// Test 6: window completely off all screens → belongs to no screen
// ---------------------------------------------------------------------------
@Test("Window completely outside all screen bounds belongs to no screen")
func windowCompletelyOffScreenBelongsToNoScreen() {
    let screenA = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let screenB = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    // Window way off to the right of both screens
    let offscreenWindow = VisibleWindowSnapshot(
        ownerName: "OffscreenApp",
        bounds: Rect(origin: Point(x: 5000, y: 200), width: 400, height: 300)
    )
    let snapshot = makeSnapshot(displayWidth: 3840, displayHeight: 1080, windows: [offscreenWindow])

    let rectsA = CollisionRect.collection(from: snapshot, screen: screenA)
    let rectsB = CollisionRect.collection(from: snapshot, screen: screenB)

    #expect(rectsA.count == 0, "Off-screen window should not appear in A")
    #expect(rectsB.count == 0, "Off-screen window should not appear in B")
}
