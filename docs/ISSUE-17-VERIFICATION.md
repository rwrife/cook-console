# Issue #17 verification — timer hardening

Hardening pass over the #4 timer engine (audit, not a rebuild). Date: 2026-09-26.
Issue: https://github.com/rwrife/cook-console/issues/17

## What shipped

1. **Launch notification sweep (`TimerEngine.synchronizeNotifications`).**
   Root cause: a crash/kill between a durable state commit (pause/cancel/ack)
   and the matching `UNUserNotificationCenter` cleanup call left a STALE
   actionable +2/+5 notification alive for a dead timer on next launch —
   the old sweep only called `removePending` for `.paused` and did nothing
   for `.cancelled`/acknowledged-`.completed`. New invariant, converged on
   every launch/foreground activation:
   - running timer with a future deadline → schedule current generation;
   - completed AND still in `timer_completion_alerts` → PRESERVE its
     delivered notification (it is the user's only actionable +2/+5 surface);
   - every other inactive/terminal row (paused, cancelled, acknowledged
     completion, overdue-reconciled) → `removeAll` (pending AND delivered;
     `removePending` alone leaves an already-delivered notification behind).
   Deterministic tests: stale-inactive sweep, unacknowledged preservation.
2. **Clock-change reconciliation.** Persisted deadlines are absolute dates.
   A backward wall-clock correction must NOT fire a running timer early; a
   forward correction past the deadline reconciles as overdue exactly once
   and repeated reconciliation is idempotent (no duplicate `.fired` event or
   queue entry). Deterministic test with a controllable clock.
3. **Permission guidance + Settings route.** New pure-domain
   `NotificationPermissionGuidance` (message/Settings-link policy per
   `NotificationAuthorization` state). `CookModeView`'s denied-permission
   fallback banner now projects that policy and adds an
   "Open Notification Settings" button using `@Environment(\.openURL)` +
   `UIApplication.openSettingsURLString` (local Settings deep-link only —
   no networking API; zero-network gate unaffected). UI test asserts the
   button appears alongside the fallback banner in the NoopScheduler
   (denied) test host.

## OS delivery limitations (issue AC #1 documentation)

Local notifications are **best effort**. Focus/Focus modes, the system
notification toggle, low-power mode, resource pressure, and OS scheduling
can delay or suppress presentation. A force-quit app receives nothing.
The app's durable guarantee is therefore NOT the notification: completion
state lives in GRDB, and the on-screen completion queue is recovered at the
next launch/foreground activation (`activateTimers` →
`reconcileExpiredTimers` + `synchronizeNotifications` + queue
presentation). Absolute persisted deadlines survive termination and device
restart (covered since #4:
`testDatabaseReopenRestoresFutureDeadlineAndForegroundReconcileCompletesIt`).

## Physical-device lock-screen check (AC #4)

**BLOCKED — cannot be performed by the Linux executor.** No physical device
or TestFlight build is available from this environment, and simulator
evidence cannot substitute (simulator notification behavior ≠ lock-screen
delivery). Per the run rules this AC is recorded as blocked, not passed.
Once a TestFlight build exists, a human should verify: start a 1-minute
timer, lock the device, confirm the actionable notification arrives and
+2 extends the durable timer.

## Evidence

- Linux core (`wine-vault-swift-sqlite:6.1`, Swift 6.1.3,
  `swift test -Xswiftc -warnings-as-errors`): **108 XCTest + 6 swift-testing,
  0 failures** — includes 3 new `NotificationPermissionGuidanceTests`
  (written first, observed RED), 3 new `TimerEngineTests` (clock-change
  convergence, stale-inactive launch sweep, unacknowledged preservation).
  Real GRDB/SQLite, not mocks. **Not iOS evidence.**
- `swiftc -parse` clean on all changed/new files (incl. the SwiftUI layer).
- `Tools/gen_project.rb` regenerated `CookConsole.xcodeproj` (Docker ruby);
  new sources/tests present in the pbxproj.
- Zero-network gate: `UIApplication.openSettingsURLString`/`openURL` are not
  in the banned pattern list; the existing CI `privacy-gate` job re-verifies.
- Native merge gate: CI `build-test` (macos-26, iPhone 17 + iPad (A16)) must
  go green before merge; run URL recorded in the PR.
