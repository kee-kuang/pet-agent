#if canImport(ApplicationServices)
import ApplicationServices
#endif

public struct AccessibilityBridge: Sendable {
    public typealias IsProcessTrustedCheck = @Sendable () -> Bool
    public typealias RequestPrompt = @Sendable () -> Void

    private let isProcessTrustedCheck: IsProcessTrustedCheck
    private let requestPrompt: RequestPrompt

    public init(
        isProcessTrustedCheck: @escaping IsProcessTrustedCheck = AccessibilityBridge.defaultIsProcessTrustedCheck,
        requestPrompt: @escaping RequestPrompt = AccessibilityBridge.defaultRequestPrompt
    ) {
        self.isProcessTrustedCheck = isProcessTrustedCheck
        self.requestPrompt = requestPrompt
    }

    public var isProcessTrusted: Bool {
        isProcessTrustedCheck()
    }

    public func requestPermissionsPrompt() {
        requestPrompt()
    }

    public static let defaultIsProcessTrustedCheck: IsProcessTrustedCheck = {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    public static let defaultRequestPrompt: RequestPrompt = {
        #if canImport(ApplicationServices)
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [key: kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
    }
}
