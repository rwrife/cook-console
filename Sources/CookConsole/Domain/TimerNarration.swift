import Foundation

/// Issue #7: the "almost done" window. A running timer with no more than
/// this many seconds left enters the `.nearZero` visual state (dedicated
/// WCAG-AA contrast token) so it is readable at a glance across a noisy
/// kitchen.
enum TimerNarration {
    static let nearZeroThreshold: TimeInterval = 60

    /// Spoken duration for a fresh timer ("20 minutes", "1 minute 20
    /// seconds", "45 seconds") — used in control labels so VoiceOver never
    /// dictates a raw "20:00" digit string.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let minutes = total / 60
        let secs = total % 60
        switch (minutes, secs) {
        case (0, 0):
            return "no time"
        case (0, _):
            return secs == 1 ? "1 second" : "\(secs) seconds"
        case (_, 0):
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        default:
            let minuteWord = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            return "\(minuteWord) \(secs) seconds"
        }
    }

    /// The visual/announce state of a timer, derived only from its status
    /// and remaining time — a pure function so the state machine is
    /// Linux-tested and the SwiftUI layer just maps states to tokens.
    static func visualState(status: CookTimerStatus, remaining: TimeInterval) -> TimerVisualState {
        switch status {
        case .running:
            return remaining <= nearZeroThreshold ? .nearZero : .running
        case .paused:
            return .paused
        case .completed:
            return .done
        case .cancelled:
            return .cancelled
        }
    }

    /// VoiceOver-friendly remaining time: "45 seconds remaining",
    /// "1 minute 20 seconds remaining", "2 minutes remaining", or
    /// "time elapsed" — never a raw "3:45" the screen reader would
    /// dictate digit-by-digit.
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let minutes = total / 60
        let secs = total % 60
        switch (minutes, secs) {
        case (0, 0):
            return "time elapsed"
        case (0, _):
            return "\(secs) seconds remaining"
        case (_, 0):
            return minutes == 1 ? "1 minute remaining" : "\(minutes) minutes remaining"
        default:
            let minuteWord = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            return "\(minuteWord) \(secs) seconds remaining"
        }
    }
}

enum TimerVisualState: Equatable, Sendable {
    case running
    case nearZero
    case paused
    case done
    case cancelled

    /// One spoken word appended to the remaining-time value so rotor
    /// focus announces "… remaining, paused" without extra navigation.
    var accessibilityWord: String {
        switch self {
        case .running: return "running"
        case .nearZero: return "running, almost done"
        case .paused: return "paused"
        case .done: return "finished"
        case .cancelled: return "cancelled"
        }
    }
}
