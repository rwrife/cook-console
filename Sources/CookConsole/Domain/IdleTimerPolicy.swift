import Foundation

/// Issue #23: the keep-screen-awake decision is a pure predicate so the
/// "active only while cooking" rule is Linux-tested rather than hidden in a
/// UIApplication call. The SwiftUI layer may only call this with the three
/// observable inputs below; the saved preference alone must never keep the
/// screen awake outside a foreground cook surface.
enum IdleTimerPolicy {
    static func shouldDisableIdleTimer(
        keepAwakeEnabled: Bool,
        cookSurfaceActive: Bool,
        sceneActive: Bool
    ) -> Bool {
        keepAwakeEnabled && cookSurfaceActive && sceneActive
    }
}
