# Issue #23 verification — cooking-screen accessibility + keep-screen-awake

Scope implemented:

1. **Keep-screen-awake (AC 1).** Opt-in `Toggle("Keep screen awake while cooking")`
   inside Cook Mode. The preference persists in `UserDefaults`; the actual
   `UIApplication.isIdleTimerDisabled` override is a pure predicate
   (`IdleTimerPolicy.shouldDisableIdleTimer`) of
   `preference && cook surface mounted && scene active`, applied by
   `AppStore.applyIdleTimerPolicy` from `ContentView` (onAppear, scenePhase,
   cook-surface and preference changes). Ending (complete/abandon/leave),
   disabling the setting, or backgrounding the scene restores normal idle
   behavior. Default OFF; nothing changes for existing users.

2. **Full instructions reachable at accessibility sizes (AC 3).** The step
   instruction uses `fixedSize(horizontal: false, vertical: true)` (no
   truncation) inside the scrollable column, gains the
   `Current instruction` identifier, and step changes move
   `@AccessibilityFocusState` to it so VoiceOver lands on the new step.
   Ingredients are reachable from the cook screen via an `Ingredients`
   button (sheet list, full names/amounts, no truncation) so essential
   content never depends on the detail page behind the cover.

3. **State feedback without color alone (AC 4).** Timer tiles now render the
   state word visibly ("Paused", "Running, almost done", "Finished",
   "Cancelled") beside the countdown, mirroring the existing VoiceOver
   value. The notification-permission fallback banner no longer rides on
   orange-only signalling (primary label + bell.slash icon + text).
   Timer controls relayout to a vertical stack at accessibility Dynamic
   Type sizes so they cannot be squeezed off-row.

4. **Regression coverage (AC 5).**
   - Linux (domain, CI `swift test` on the SPM core is unchanged; the
     predicate lives in `Domain/IdleTimerPolicy.swift`):
     `IdleTimerPolicyTests` exhaustively proves the truth table (8 cases),
     so the saved preference alone can never keep the screen awake.
   - Apple unit (`AppStoreQueryTests.testIdleTimerAppliesForegroundCookPolicyAndPersistsPreference`):
     asserts the real `UIApplication.shared.isIdleTimerDisabled` value for
     every preference/cook/foreground combination, preference persistence
     across a re-created store, and restore-to-normal when the setting is
     turned off mid-cook.
   - Apple UI (`AccessibilityUITests.testKeepAwakeOnlyWhileCooking`,
     iPhone 17 main lane): full journey through the exported idle-timer
     readout — off outside cooking, applied inside cooking, restored after
     Full recipe, re-applied on re-cook, restored after Complete and after
     Abandon, and the preference survives an app relaunch (second launch
     without `-ui-testing-reset`).
   - Apple UI (`AccessibilityUITests.testCookInstructionAndIngredientsAtAccessibilitySize`,
     AX XXXL): runs on iPhone 17 (main lane) AND a dedicated iPad A16 CI
     step (larger/split layout). Asserts the complete long instruction text
     is exposed (not truncated), the step counter and ≥44pt bottom-pinned
     pager stay reachable, and the full ingredient text is reachable via
     the Ingredients sheet.

## Evidence boundaries (honesty)

- The simulator cannot observe actual display sleep. CI proves the
  `isIdleTimerDisabled` flag value and its lifecycle (unit assertion on the
  real UIApplication property + the exported readout journey). Real-device
  lock-screen dimming with the setting ON has **not** been verified on
  physical hardware; treat hardware dimming as expected-but-unproven.
- Smallest supported layout = iPhone 17 portrait (the main CI lane, compact
  width); larger/split layout = iPad A16 regular width (dedicated CI step).
  "One-handed navigation" is evidenced by the bottom-pinned ≥44pt pager and
  toolbar placements already asserted in `AccessibilityUITests`; no new
  gesture claims are made.
- VoiceOver order is asserted indirectly (focus move on step change + the
  existing label/value contracts from #7); VoiceOver audio output itself is
  not drivable from XCUITest.

Local pre-push evidence: Linux Swift 6.1 suite green (see PR body), `swiftc
-frontend -parse` clean, xcodeproj regenerated with both new files, workflow
actionlint-clean.
