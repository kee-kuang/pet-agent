import Foundation

public final class SpaceTracker: @unchecked Sendable {
    public typealias ReadActiveSpaceIdentifier = @Sendable () -> String
    public typealias ObserveChanges = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let readActiveSpaceIdentifier: ReadActiveSpaceIdentifier
    private let lock = NSLock()
    private var storedIdentifier: String?

    public var currentActiveSpaceIdentifier: String {
        lock.lock()
        if let cached = storedIdentifier {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fresh = readActiveSpaceIdentifier()
        lock.lock()
        storedIdentifier = fresh
        lock.unlock()
        return fresh
    }

    public init(
        readActiveSpaceIdentifier: @escaping ReadActiveSpaceIdentifier,
        observeChanges: ObserveChanges = { _ in }
    ) {
        self.readActiveSpaceIdentifier = readActiveSpaceIdentifier
        observeChanges { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.storedIdentifier = nil
            self.lock.unlock()
        }
    }
}
