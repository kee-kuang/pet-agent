import Foundation
import Testing
@testable import Context

@Test("AX frontmost window observer returns nil when accessibility is not trusted")
@MainActor
func axFrontmostWindowObserverReturnsNilWhenAccessibilityIsNotTrusted() {
    let observer = AXFrontmostWindowObserver(
        isProcessTrustedCheck: { false },
        frontmostApplicationPID: { 1234 }
    ) {
        // unreachable when not trusted
    }

    #expect(observer == nil)
}
