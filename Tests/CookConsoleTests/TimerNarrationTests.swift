import XCTest
@testable import CookConsole

/// Issue #7: the spoken/state mapping that drives VoiceOver values and the
/// WCAG state colors is a pure domain function — verified here on Linux so
/// the SwiftUI layer is a dumb projection.
final class TimerNarrationTests: XCTestCase {
    // MARK: visual state

    func testRunningTimerAboveThresholdIsRunningState() {
        XCTAssertEqual(
            TimerNarration.visualState(status: .running, remaining: 61),
            .running
        )
        XCTAssertEqual(
            TimerNarration.visualState(status: .running, remaining: 1200),
            .running
        )
    }

    func testRunningTimerAtOrBelowThresholdIsNearZeroState() {
        // The threshold boundary itself counts as near-zero.
        XCTAssertEqual(
            TimerNarration.visualState(status: .running, remaining: TimerNarration.nearZeroThreshold),
            .nearZero
        )
        XCTAssertEqual(
            TimerNarration.visualState(status: .running, remaining: 0),
            .nearZero
        )
    }

    func testPausedCompletedCancelledMapThrough() {
        XCTAssertEqual(
            TimerNarration.visualState(status: .paused, remaining: 5),
            .paused,
            "Paused must never take the near-zero urgency color."
        )
        XCTAssertEqual(
            TimerNarration.visualState(status: .completed, remaining: 0),
            .done
        )
        XCTAssertEqual(
            TimerNarration.visualState(status: .cancelled, remaining: 300),
            .cancelled
        )
    }

    // MARK: spoken remaining time

    func testRemainingPhrasing() {
        XCTAssertEqual(TimerNarration.remaining(0), "time elapsed")
        XCTAssertEqual(TimerNarration.remaining(2), "2 seconds remaining")
        XCTAssertEqual(TimerNarration.remaining(2.1), "3 seconds remaining",
                       "Rounds up so the last partial second still reads non-empty.")
        XCTAssertEqual(TimerNarration.remaining(59.2), "1 minute remaining",
                       "59.2s rounds up to 60 — past the minute boundary.")
        XCTAssertEqual(TimerNarration.remaining(60), "1 minute remaining")
        XCTAssertEqual(TimerNarration.remaining(90), "1 minute 30 seconds remaining")
        XCTAssertEqual(TimerNarration.remaining(120), "2 minutes remaining")
        XCTAssertEqual(TimerNarration.remaining(600), "10 minutes remaining")
        XCTAssertEqual(TimerNarration.remaining(1260), "21 minutes remaining")
        XCTAssertEqual(TimerNarration.remaining(-5), "time elapsed",
                       "Negative clock skew must not produce '-5 seconds'.")
    }

    func testRemainingNeverContainsBareColonClock() {
        // VoiceOver dictates "3:45" digit-by-digit; every phrasing must be
        // word-based.
        for seconds in stride(from: 0.0, through: 3600.0, by: 7.0) {
            XCTAssertFalse(
                TimerNarration.remaining(seconds).contains(":"),
                "Spoken time must not use mm:ss: \(TimerNarration.remaining(seconds))"
            )
        }
    }

    // MARK: spoken duration labels

    func testDurationLabelPhrasing() {
        XCTAssertEqual(TimerNarration.durationLabel(45), "45 seconds")
        XCTAssertEqual(TimerNarration.durationLabel(1), "1 second")
        XCTAssertEqual(TimerNarration.durationLabel(60), "1 minute")
        XCTAssertEqual(TimerNarration.durationLabel(80), "1 minute 20 seconds")
        XCTAssertEqual(TimerNarration.durationLabel(1200), "20 minutes")
    }

    // MARK: state words

    func testAccessibilityWords() {
        XCTAssertEqual(TimerVisualState.running.accessibilityWord, "running")
        XCTAssertEqual(TimerVisualState.nearZero.accessibilityWord, "running, almost done")
        XCTAssertEqual(TimerVisualState.paused.accessibilityWord, "paused")
        XCTAssertEqual(TimerVisualState.done.accessibilityWord, "finished")
        XCTAssertEqual(TimerVisualState.cancelled.accessibilityWord, "cancelled")
    }
}
