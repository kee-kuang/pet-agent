import Foundation
import Testing
@testable import Context

private final class FakeChangeTrigger: @unchecked Sendable {
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

@Test("Display tracker captures initial displays on construction")
func displayTrackerCapturesInitialDisplaysOnConstruction() {
    let tracker = DisplayTracker(
        readDisplays: {
            [DisplaySnapshot(id: 0, width: 800, height: 600)]
        }
    )

    #expect(tracker.currentDisplays == [DisplaySnapshot(id: 0, width: 800, height: 600)])
}

@Test("Display tracker refreshes displays when change notification fires")
func displayTrackerRefreshesDisplaysWhenChangeNotificationFires() {
    let snapshots: SnapshotQueue = SnapshotQueue([
        [DisplaySnapshot(id: 0, width: 800, height: 600)],
        [
            DisplaySnapshot(id: 0, width: 1920, height: 1080),
            DisplaySnapshot(id: 1, width: 1440, height: 900),
        ],
    ])
    let trigger = FakeChangeTrigger()
    let tracker = DisplayTracker(
        readDisplays: { snapshots.next() },
        observeChanges: { handler in
            trigger.register(handler)
        }
    )

    #expect(tracker.currentDisplays.count == 1)
    trigger.fire()

    #expect(tracker.currentDisplays.count == 2)
    #expect(tracker.currentDisplays[1].width == 1440)
}

private final class SnapshotQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[DisplaySnapshot]]

    init(_ queue: [[DisplaySnapshot]]) {
        self.queue = queue
    }

    func next() -> [DisplaySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return queue.removeFirst()
    }
}
