#if canImport(UIKit)
import UIKit

/// Issue #7 haptics: tactile confirmation for timer completion and step
/// progress. UIImpactFeedbackGenerator / UIFeedbackGenerator honor the
/// system "System Haptics" setting (Settings → Sounds & Haptics) and
/// System Accessibility → Voice Feedback automatically — when the user
/// disables system haptics, prepare()/impactOccurred() become no-ops, so
/// the app never needs its own toggle.
///
/// The fire path deliberately uses `notificationOccurred(.success)` (three
/// crisp pulses) rather than `.messageSuccess`: a notification-style pattern
/// is the established tactile language for "something finished while you
/// weren't looking" and stays distinct from the light tap used for
/// navigation.
enum CookHaptics {
    /// A timer finished (the completion alert's arrival).
    static func timerFinished() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The cook advanced to a new step (light, directional).
    static func stepAdvanced() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The final step was completed (heavy, terminal).
    static func cookCompleted() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}
#else
import Foundation

/// Linux (SPM core target) build: no UIKit, no haptics. The core package
/// never calls these — the guard exists so `Sources/CookConsole/Services`
/// stays inside the Linux-compiled target set.
enum CookHaptics {
    static func timerFinished() {}
    static func stepAdvanced() {}
    static func cookCompleted() {}
}
#endif
