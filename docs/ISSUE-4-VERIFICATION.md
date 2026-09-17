# Issue 4 timer verification

## Repair status — review blockers addressed, pending native CI

The 2026-09-16 draft failed independent review on three races. This cycle
addresses all three at the source instead of weakening any assertion:

1. **Double acknowledgment.** The completion alert's `isPresented` setter is
   now a deliberate no-op. SwiftUI writes `false` to the binding whenever the
   alert dismisses, *including* as part of the OK action's own dismissal;
   treating that write as a second acknowledgment used to consume the next
   queued timer before its alert was shown. Only the OK action acknowledges,
   guarded by `presentedCompletionID`, and the next queued completion is
   presented on a follow-up main-actor turn so a stale dismissal write can
   neither consume nor suppress it. Regressed by
   `testDoubleAcknowledgmentCannotConsumeTheNextQueuedCompletion`.
2. **Stale foreground delivery.** Notification payloads now carry the exact
   scheduled deadline. `TimerEngine.completeIfDelivered(timerID:deadline:)`
   completes a timer only while it is still `running` with a matching current
   deadline (±0.5s tolerance), so an obsolete in-flight delivery cannot
   complete a timer that was paused, resumed, extended, already completed, or
   cancelled. Regressed by `testForegroundDeliveryCompletesOnlyTheCurrentRunningDeadline`,
   `testForegroundDeliveryCannotCompletePausedOrCancelledTimer`, and
   `testDelayedDeliveryAfterExpiryReconciliationCannotDoubleFire`.
3. **Polling cancelling actionable notifications.** Expiry completion no
   longer removes the pending request at all, so a delivery race can never
   destroy the only actionable +2/+5 presentation; removal belongs to
   acknowledgment, pause, cancel, restart, and session end (all already
   covered). The app layer also replaced the permanent once-per-second root
   `onReceive` publisher with a single cancellable deadline wake-up Task
   (`nextExpiryDate()` → `Task.sleep` → reconcile), which was the source of
   the observed simulator UI instability (per-second `@Published` invalidation
   disrupted menu presentation and alert presentation; the publisher also
   kept the app forever "non-idle" for XCTest waits). Regressed by
   `testNextExpiryDateTracksOnlyRunningDeadlines` plus the updated
   pending-removal expectations.

Additional native-run fixes in this cycle:

- `reloadTimers()` only writes `@Published timers` when the value actually
  changed, so post-dismissal reconciliation passes no longer re-invalidate an
  alert's presenting view.
- The scheduling-failure modal is suppressed while permission is denied (the
  persistent fallback banner already explains that state), so it cannot race
  the completion alert in the same presentation window.
- UI `tapWhenHittable` now polls `isHittable` for up to 5s before acting,
  because a closed menu Picker exposes zero-frame option buttons that produce
  `{{inf, inf}, {0, 0}}` activation points immediately after a tap. The strict
  hittability gate is retained; nothing was weakened.
- `TimerRepository` gained direct SQL for fetch-by-id, fetch-by-session, and
  `MIN(deadline)`, replacing per-tick full-table scans.

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
- deadline-matched delivery validation for paused/resumed/extended/cancelled/
  already-completed timers and delayed delivery after reconciliation;
- expiry ticks that preserve pending requests and never reschedule unchanged
  requests; delivered/pending removal on acknowledgment instead;
- +2/+5 notification handling after termination and while an expired timer is
  still stored as running;
- ordinary extension at and after expiry, with the full extension measured
  from action time;
- delayed notification-scheduling failure reporting;
- next-expiry tracking over running timers only (wake-up scheduling);
- transactional cancellation of active timers when their session ends; and
- timer state-shape and recipe/step/session identity validation.

Development followed focused red/green cycles. Linux validates the portable
package with warnings as errors; it cannot type-check SwiftUI/UserNotifications
or run an iOS simulator. Canonical validation of the native adapter, AppStore
behavior, alert presentation, and UI journeys remains the macOS 26 CI job using
Xcode 26.6 and the iOS 26.5 iPhone 17 simulator. Local notification delivery
timing and permission UI are OS behaviors, not exact-delivery guarantees.
Simulator-only evidence is labeled as such; no device or TestFlight validation
is claimed.
