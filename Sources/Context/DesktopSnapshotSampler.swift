public struct DesktopSnapshotSampler: Sendable {
    public typealias CurrentDisplays = @Sendable () -> [DisplaySnapshot]
    public typealias ActiveSpaceIdentifier = @Sendable () -> String
    public typealias CurrentCursorPosition = @Sendable () -> Point
    public typealias FrontmostApplicationName = @Sendable () -> String?
    public typealias CurrentVisibleWindows = @Sendable () -> [VisibleWindowSnapshot]
    public typealias AccessibilityIsTrusted = @Sendable () -> Bool

    private let currentDisplays: CurrentDisplays
    private let activeSpaceIdentifier: ActiveSpaceIdentifier
    private let currentCursorPosition: CurrentCursorPosition
    private let frontmostApplicationName: FrontmostApplicationName
    private let currentVisibleWindows: CurrentVisibleWindows
    private let accessibilityIsTrusted: AccessibilityIsTrusted

    public init(
        currentDisplays: @escaping CurrentDisplays = { [] },
        activeSpaceIdentifier: @escaping ActiveSpaceIdentifier = { "unknown" },
        currentCursorPosition: @escaping CurrentCursorPosition,
        frontmostApplicationName: @escaping FrontmostApplicationName,
        currentVisibleWindows: @escaping CurrentVisibleWindows = { [] },
        accessibilityIsTrusted: @escaping AccessibilityIsTrusted = { false }
    ) {
        self.currentDisplays = currentDisplays
        self.activeSpaceIdentifier = activeSpaceIdentifier
        self.currentCursorPosition = currentCursorPosition
        self.frontmostApplicationName = frontmostApplicationName
        self.currentVisibleWindows = currentVisibleWindows
        self.accessibilityIsTrusted = accessibilityIsTrusted
    }

    public func sample() -> DesktopSnapshot {
        DesktopSnapshot(
            displays: currentDisplays(),
            activeSpaceIdentifier: activeSpaceIdentifier(),
            cursorPosition: currentCursorPosition(),
            visibleApplicationName: frontmostApplicationName(),
            visibleWindows: currentVisibleWindows(),
            accessibilityIsTrusted: accessibilityIsTrusted()
        )
    }
}
