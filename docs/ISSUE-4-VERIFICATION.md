# Issue 4 timer verification

## Repair status — review blockers addressed, pending native CI

The 2026-09-16 draft failed independent review on three races; a follow-up
review of the first repair pass flagged three residual weaknesses. This cycle
closes all six with structural fixes instead of weakened assertions:

1. **Double acknowledgment (original + residual).** The alert's OK action
   acknowledges exactly one completion, guarded by `presentedCompletionID`
   and cleared up front so repeated dismissal-path invocations cannot consume
   a second timer. Crucially, queue advancement no longer happens inside the
   OK action at all: SwiftUI writes `false` to the alert binding only after
   the alert is actually gone, and that dismissal signal
   (`completionAlertDismissed()`) advances the queue after a short delay, so
   a new alert can never be swallowed by the previous alert's in-flight
   dismissal window. A swipe-away without OK keeps the durable queue row for
   later re-presentation. Regressed by
   `testDoubleAcknowledgmentCannotConsumeTheNextQueuedCompletion` (store
   level) and `testConsecutiveQueuedCompletionAlertsPresentInOrder` (UI
   level, two real one-alert-then-another timers).
2. **Stale foreground delivery (original + residual deadline-tolerance
   gap).** A persisted `schedule_generation` counter (migration
   `v6_timer_schedule_generation`) is bumped by every state-changing
   transition and captured in each scheduled notification payload.
   `TimerEngine.completeIfDelivered(timerID:scheduleGeneration:)` requires
   exact generation equality and a passed deadline, so obsolete deliveries
   cannot complete the current schedule even when a pause-then-resume lands
   two deadlines within a fraction of a second. Regressed by
   `testNearCoincidentResumeDeadlineCannotBeCompletedByObsoleteDelivery`,
   `testForegroundDeliveryCompletesOnlyTheCurrentSchedule`,
   `testForegroundDeliveryCannotCompletePausedOrCancelledTimer`, and
   `testDelayedDeliveryAfterExpiryReconciliationCannotDoubleFire`.
3. **Polling cancelling actionable notifications (original + residual
   error-path gap).** Expiry completion no longer removes pending requests;
   removal belongs to acknowledgment, pause, cancel, restart, and session
   end. The permanent once-per-second root publisher is replaced by a single
   cancellable deadline wake-up Task (`nextExpiryDate()` → `Task.sleep` →
   reconcile) whose chain is self-healing: any reconcile or lookup failure
   re-arms a bounded short retry (≤5 attempts) instead of stranding timers
   until the next scene transition. Regressed by
   `testNextExpiryDateTracksOnlyRunningDeadlines` plus the updated
   pending-removal expectations.

Additional native-run hardening in this cycle:

- `reloadTimers()` only writes `@Published timers` when the value changed,
  so post-dismissal reconciliation passes no longer re-invalidate an alert's
  presenting view.
- The scheduling-failure modal is suppressed while permission is denied (the
  persistent fallback banner covers that state), so it cannot collide with
  the completion alert in the same presentation window.
- UI `tapWhenHittable` polls `isHittable` up to 5s before acting, because a
  closed menu Picker exposes zero-frame option buttons that produce
  `{{inf, inf}, {0, 0}}` activation points immediately after a tap. The
  strict hittability gate is retained.
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
- generation-exact delivery validation, including near-coincident
  pause/resume deadlines, delayed delivery after reconciliation, and
  paused/cancelled/extended rejection;
- expiry ticks that preserve pending requests and never reschedule unchanged
  requests; delivered/pending removal on acknowledgment instead;
- +2/+5 notification handling after termination and while an expired timer is
  still stored as running;
- ordinary extension at and after expiry, with the full extension measured
  from action time;
- delayed notification-scheduling failure reporting;
- next-expiry tracking over running timers only (wake-up scheduling);
- transactional cancellation of active timers when their session ends; and
- timer state-shape and recipe/step/session identity validation, plus the
  v6 schema assertion for `schedule_generation`.

`AppStoreQueryTests` (native target; compiles only where SwiftUI is
importable) exercises launch/foreground completion, single-shot
acknowledgment under repeated dismissal-path calls, and dismissal-signal
queue advancement with two durably queued completions.

Development followed focused red/green cycles. Linux validates the portable
package with warnings as errors; it cannot type-check SwiftUI/UserNotifications
or run an iOS simulator. Canonical validation of the native adapter, AppStore
behavior, alert presentation, and UI journeys remains the macOS 26 CI job using
Xcode 26.6 and the iOS 26.5 iPhone 17 simulator. Local notification delivery
timing and permission UI are OS behaviors, not exact-delivery guarantees.
Simulator-only evidence is labeled as such; no device or TestFlight validation
is claimed.
