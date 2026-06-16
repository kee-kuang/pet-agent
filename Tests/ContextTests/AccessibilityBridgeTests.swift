import Foundation
import Testing
@testable import Context

@Test("Accessibility bridge reports trusted state from injected check")
func accessibilityBridgeReportsTrustedStateFromInjectedCheck() {
    let trustedBridge = AccessibilityBridge(isProcessTrustedCheck: { true })
    let untrustedBridge = AccessibilityBridge(isProcessTrustedCheck: { false })

    #expect(trustedBridge.isProcessTrusted)
    #expect(untrustedBridge.isProcessTrusted == false)
}

@Test("Accessibility bridge re-evaluates trust each call")
func accessibilityBridgeReEvaluatesTrustEachCall() {
    let toggling = TogglingTrustSource()
    let bridge = AccessibilityBridge(isProcessTrustedCheck: { toggling.next() })

    #expect(bridge.isProcessTrusted == false)
    #expect(bridge.isProcessTrusted == true)
    #expect(bridge.isProcessTrusted == false)
}

@Test("Accessibility bridge forwards permissions prompt request to injected sink")
func accessibilityBridgeForwardsPermissionsPromptRequestToInjectedSink() {
    let promptCounter = PromptCounter()
    let bridge = AccessibilityBridge(
        isProcessTrustedCheck: { false },
        requestPrompt: { promptCounter.increment() }
    )

    bridge.requestPermissionsPrompt()
    bridge.requestPermissionsPrompt()

    #expect(promptCounter.count == 2)
}

private final class PromptCounter: @unchecked Sendable {
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

private final class TogglingTrustSource: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let sequence: [Bool] = [false, true, false]

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = sequence[index % sequence.count]
        index += 1
        return value
    }
}
