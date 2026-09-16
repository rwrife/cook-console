# Issue 4 timer verification

## Draft status — not merge-ready

The 2026-09-16 candidate passes 68 Linux tests but failed independent review
after two repair cycles. Issue #4 must remain open until these are fixed:

- Both the alert action and dismissal binding acknowledge completion, which
  can silently consume the next queued timer.
- An obsolete foreground notification can complete a newly paused or extended
  timer because its callback does not validate the current deadline/state.
- Expiry polling can cancel an actionable notification before delayed OS
  delivery. The existing pending-removal test does not validate that race.

Native CI evidence is recorded in the draft PR; no device or TestFlight
validation is claimed.

## Portable automated coverage

`TimerEngineTests` uses an injected mutable clock and never sleeps. Its fake
notification scheduler records replacement and removal calls. Coverage includes:

- persisted recipe, step, and cook-session identities and wall-clock deadlines;
- independent concurrent pause/resume/extend/cancel transitions;
- started, fired, and extended session logs;
- file-backed SQLite close/reopen and future-deadline restoration;
- engine-level launch/reopen and foreground-style expiry reconciliation;
- idempotent fired logging;
- a durable, unacknowledged completion queue that survives relaunch;
- pending-only removal at expiry and delivered removal on cancellation,
  acknowledgment, or restart;
- +2/+5 notification handling after termination and while an expired timer is
  still stored as running;
- ordinary extension at and after expiry, with the full extension measured
  from action time;
- delayed notification-scheduling failure reporting;
- expiry ticks that do not reschedule unchanged requests;
- transactional cancellation of active timers when their session ends; and
- timer state-shape and recipe/step/session identity validation.

Development followed focused red/green cycles. The captured Linux Swift 6.1
logs for this review fix are `/tmp/cook-console-issue4-fix2-*.log`. These are
local ephemeral evidence and are intentionally not repository artifacts.

## Native coverage and limitations

The native test targets now include AppStore launch/foreground completion and
acknowledgment coverage with an injected clock. A UI regression uses a real
one-second production timer with notifications denied, waits through XCTest
expectations rather than sleeping, and checks the app-root completion alert
both above the cook full-screen cover and after **Full recipe** exits it. The
UI test does not substitute a fake alert. These native tests are staged for
macOS CI and are not claimed as executed locally.

The iOS UI target also contains interaction tests for concurrent timer controls
and process relaunch. The native service registers the `COOK_TIMER` category
with +2/+5 actions, presents foreground notifications, and routes action
identifiers back to the durable engine.

Linux validates the portable package with warnings as errors and parses all
Swift sources. It cannot type-check SwiftUI/UserNotifications or run an iOS
simulator. Canonical validation of the native adapter, AppStore behavior, and
app-root presentation remains the macOS 26 CI job using Xcode 26.6 and the iOS
26.5 iPhone 17 simulator. Local notification delivery timing and permission UI
are OS behaviors, not exact-delivery guarantees.
