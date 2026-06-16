import Foundation

public final class WindowTracker: @unchecked Sendable {
    public typealias ReadVisibleWindows = @Sendable () -> [VisibleWindowSnapshot]
    public typealias ObserveChanges = @Sendable (@escaping @Sendable () -> Void) -> Void
    public typealias CurrentTime = @Sendable () -> TimeInterval

    private let readVisibleWindows: ReadVisibleWindows
    private let cacheLifetime: TimeInterval
    private let currentTime: CurrentTime
    private let lock = NSLock()
    private var storedWindows: [VisibleWindowSnapshot]?
    private var storedAt: TimeInterval?

    public var currentVisibleWindows: [VisibleWindowSnapshot] {
        lock.lock()
        let now = currentTime()
        if let cached = storedWindows,
           let savedAt = storedAt,
           now - savedAt <= cacheLifetime {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fresh = readVisibleWindows()
        lock.lock()
        storedWindows = fresh
        storedAt = now
        lock.unlock()
        return fresh
    }

    public init(
        readVisibleWindows: @escaping ReadVisibleWindows,
        observeChanges: ObserveChanges = { _ in },
        cacheLifetime: TimeInterval = 0.1,
        currentTime: @escaping CurrentTime = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.readVisibleWindows = readVisibleWindows
        self.cacheLifetime = cacheLifetime
        self.currentTime = currentTime
        observeChanges { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.storedWindows = nil
            self.storedAt = nil
            self.lock.unlock()
        }
    }
}
