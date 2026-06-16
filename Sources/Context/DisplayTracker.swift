import Foundation

public final class DisplayTracker: @unchecked Sendable {
    public typealias ReadDisplays = @Sendable () -> [DisplaySnapshot]
    public typealias ObserveChanges = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let readDisplays: ReadDisplays
    private let lock = NSLock()
    private var storedDisplays: [DisplaySnapshot]

    public var currentDisplays: [DisplaySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storedDisplays
    }

    public init(
        readDisplays: @escaping ReadDisplays,
        observeChanges: ObserveChanges = { _ in }
    ) {
        self.readDisplays = readDisplays
        self.storedDisplays = readDisplays()
        observeChanges { [weak self] in
            guard let self else { return }
            let next = self.readDisplays()
            self.lock.lock()
            self.storedDisplays = next
            self.lock.unlock()
        }
    }
}
