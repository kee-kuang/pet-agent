import Foundation
import Testing
@testable import Context

@Test("Window tracker captures initial visible windows on construction")
func windowTrackerCapturesInitialVisibleWindowsOnConstruction() {
    let tracker = WindowTracker(
        readVisibleWindows: {
            [
                VisibleWindowSnapshot(
                    ownerName: "Finder",
                    bounds: Rect(origin: Point(x: 0, y: 0), width: 800, height: 600)
                ),
            ]
        }
    )

    #expect(tracker.currentVisibleWindows.count == 1)
    #expect(tracker.currentVisibleWindows.first?.ownerName == "Finder")
}

@Test("Window tracker refreshes visible windows after cache lifetime expires")
func windowTrackerRefreshesVisibleWindowsAfterCacheLifetimeExpires() {
    let snapshots = WindowSnapshotQueue([
        [
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 0, y: 0), width: 800, height: 600)
            ),
        ],
        [],
    ])
    let clock = MutableClock(initial: 100.0)
    let tracker = WindowTracker(
        readVisibleWindows: { snapshots.next() },
        cacheLifetime: 0.1,
        currentTime: { clock.read() }
    )

    #expect(tracker.currentVisibleWindows.count == 1)
    // Same instant → still cached.
    #expect(tracker.currentVisibleWindows.count == 1)

    clock.advance(by: 0.2)
    // Cache lifetime expired → re-read returns the new (empty) snapshot.
    #expect(tracker.currentVisibleWindows.isEmpty)
}

@Test("Window tracker refreshes visible windows when ax notification fires")
func windowTrackerRefreshesVisibleWindowsWhenAXNotificationFires() {
    let snapshots = WindowSnapshotQueue([
        [
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 0, y: 0), width: 800, height: 600)
            ),
        ],
        [
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 100, y: 50), width: 800, height: 600)
            ),
            VisibleWindowSnapshot(
                ownerName: "Xcode",
                bounds: Rect(origin: Point(x: 200, y: 100), width: 1200, height: 800)
            ),
        ],
    ])
    let trigger = WindowChangeTrigger()
    let tracker = WindowTracker(
        readVisibleWindows: { snapshots.next() },
        observeChanges: { handler in
            trigger.register(handler)
        }
    )

    #expect(tracker.currentVisibleWindows.count == 1)
    trigger.fire()

    #expect(tracker.currentVisibleWindows.count == 2)
    #expect(tracker.currentVisibleWindows[0].bounds.origin.x == 100)
}

private final class WindowSnapshotQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[VisibleWindowSnapshot]]

    init(_ queue: [[VisibleWindowSnapshot]]) {
        self.queue = queue
    }

    func next() -> [VisibleWindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return queue.removeFirst()
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(initial: TimeInterval) {
        self.value = initial
    }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value += delta
    }
}

private final class WindowChangeTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let captured = handler
        lock.unlock()
        captured?()
    }
}
