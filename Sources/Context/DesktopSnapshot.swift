public struct Point: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

public struct Rect: Sendable, Equatable {
    public let origin: Point
    public let width: Double
    public let height: Double

    public init(origin: Point, width: Double, height: Double) {
        self.origin = origin
        self.width = width
        self.height = height
    }

    public static let zero = Rect(origin: .zero, width: 0, height: 0)
}

public struct DisplaySnapshot: Sendable, Equatable {
    public let id: UInt32
    public let width: Double
    public let height: Double

    public init(id: UInt32, width: Double, height: Double) {
        self.id = id
        self.width = width
        self.height = height
    }
}

public struct VisibleWindowSnapshot: Sendable, Equatable {
    public let ownerName: String
    public let bounds: Rect
    public let workspace: Int?
    /// 窗口标题（`kCGWindowName`，需屏幕录制权限）。让 AI 知道用户在改哪个文件/看哪个页。
    /// 标题缺失（无权限 / app 未提供）时为 nil。
    public let title: String?

    public init(ownerName: String, bounds: Rect, workspace: Int? = nil, title: String? = nil) {
        self.ownerName = ownerName
        self.bounds = bounds
        self.workspace = workspace
        self.title = title
    }
}

public struct DesktopSnapshot: Sendable, Equatable {
    public let displays: [DisplaySnapshot]
    public let activeSpaceIdentifier: String
    public let cursorPosition: Point
    public let visibleApplicationName: String?
    public let visibleWindows: [VisibleWindowSnapshot]
    public let accessibilityIsTrusted: Bool

    public init(
        displays: [DisplaySnapshot] = [],
        activeSpaceIdentifier: String = "unknown",
        cursorPosition: Point = .zero,
        visibleApplicationName: String? = nil,
        visibleWindows: [VisibleWindowSnapshot] = [],
        accessibilityIsTrusted: Bool = false
    ) {
        self.displays = displays
        self.activeSpaceIdentifier = activeSpaceIdentifier
        self.cursorPosition = cursorPosition
        self.visibleApplicationName = visibleApplicationName
        self.visibleWindows = visibleWindows
        self.accessibilityIsTrusted = accessibilityIsTrusted
    }

    public static let empty = DesktopSnapshot()
}
