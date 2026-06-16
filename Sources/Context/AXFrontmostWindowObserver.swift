#if canImport(ApplicationServices) && canImport(AppKit)
import ApplicationServices
import AppKit
import Foundation

@MainActor
public final class AXFrontmostWindowObserver {
    private let handler: @Sendable () -> Void
    private let runLoop: CFRunLoop
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var workspaceTokens: [NSObjectProtocol] = []

    public init?(
        isProcessTrustedCheck: @Sendable () -> Bool = AccessibilityBridge.defaultIsProcessTrustedCheck,
        frontmostApplicationPID: @Sendable () -> Int32? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        runLoop: CFRunLoop = CFRunLoopGetMain(),
        handler: @escaping @Sendable () -> Void
    ) {
        guard isProcessTrustedCheck() else {
            return nil
        }
        self.handler = handler
        self.runLoop = runLoop
        if let pid = frontmostApplicationPID() {
            attach(to: pid)
        }
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            MainActor.assumeIsolated {
                self.attach(to: app.processIdentifier)
            }
        }
        workspaceTokens.append(token)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    @MainActor
    private static var retainedObservers: [AXFrontmostWindowObserver] = []

    @MainActor
    @discardableResult
    public static func attachWithRetainer(
        isProcessTrustedCheck: @Sendable () -> Bool = AccessibilityBridge.defaultIsProcessTrustedCheck,
        handler: @escaping @Sendable () -> Void
    ) -> AXFrontmostWindowObserver? {
        guard let observer = AXFrontmostWindowObserver(
            isProcessTrustedCheck: isProcessTrustedCheck,
            handler: handler
        ) else {
            return nil
        }
        retainedObservers.append(observer)
        return observer
    }

    private static let watchedNotifications: [String] = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private func attach(to pid: pid_t) {
        guard pid > 0, pid != observedPID else {
            return
        }
        detach()
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, Self.observerCallback, &newObserver)
        guard result == .success, let newObserver else {
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let info = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.watchedNotifications {
            _ = AXObserverAddNotification(newObserver, element, notification as CFString, info)
        }
        CFRunLoopAddSource(
            runLoop,
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        observer = newObserver
        observedPID = pid
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        observedPID = 0
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else {
            return
        }
        let observer = Unmanaged<AXFrontmostWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
        observer.handler()
    }
}
#endif
