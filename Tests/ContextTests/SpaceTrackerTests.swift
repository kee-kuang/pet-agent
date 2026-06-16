import Foundation
import Testing
@testable import Context

@Test("Space tracker reads active space lazily and caches result")
func spaceTrackerReadsActiveSpaceLazilyAndCachesResult() {
    let counter = SpaceReadCounter()
    let tracker = SpaceTracker(
        readActiveSpaceIdentifier: {
            counter.increment()
            return "space-7"
        }
    )

    #expect(counter.count == 0)
    #expect(tracker.currentActiveSpaceIdentifier == "space-7")
    #expect(counter.count == 1)
    _ = tracker.currentActiveSpaceIdentifier
    #expect(counter.count == 1)
}

@Test("Space tracker re-reads active space identifier when change notification fires")
func spaceTrackerReReadsActiveSpaceIdentifierWhenChangeNotificationFires() {
    let queue = SpaceIdentifierQueue(["space-7", "space-9"])
    let trigger = SpaceChangeTrigger()
    let tracker = SpaceTracker(
        readActiveSpaceIdentifier: { queue.next() },
        observeChanges: { handler in trigger.register(handler) }
    )

    #expect(tracker.currentActiveSpaceIdentifier == "space-7")
    trigger.fire()
    #expect(tracker.currentActiveSpaceIdentifier == "space-9")
}

private final class SpaceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

private final class SpaceIdentifierQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]

    init(_ queue: [String]) {
        self.queue = queue
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return queue.removeFirst()
    }
}

private final class SpaceChangeTrigger: @unchecked Sendable {
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
