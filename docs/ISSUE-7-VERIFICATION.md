# Issue #7 — Accessibility & one-handed ergonomics audit

Hardening pass over the surfaces shipped by #3–#6. Date: 2026-09-22.
Legend: ✅ fixed & covered by tests · ✅(static) fixed & reviewed statically
· ⚠️ known limitation.

## VoiceOver narration (per surface)

| Surface | Element | Before | After | Status |
|---|---|---|---|---|
| Library rows | title/tags | `accessibilityLabel(title)` suppressed tags | label = title, value = tag list ("weeknight, …" / "no tags"); stable id `Recipe row <title>` | ✅ (UI test: narration) |
| Library toolbar | Filter, Add, Your data | native labels | unchanged (already meaningful) | ✅(static) |
| Recipe detail | servings readout | bare digit + hidden word order fragile | label "Servings", value = amount; decorative word hidden | ✅ (UI test: narration) |
| Recipe detail | −/+ /Reset | "Decrease/Increase servings by half", "Reset servings" | unchanged | ✅(static) |
| Cook mode | step counter + instruction | plain Text | rotor-navigable static text; step counter asserted in tests | ✅(static) |
| Cook mode | Start timer | "Start 20:00 timer" (dictated digit-by-digit) | spoken label "Start step timer, 20 seconds" | ✅ (UI test: label) |
| Cook mode / console | countdown digits | value = "3:45" | label "<step> timer", value "1 minute 20 seconds remaining, running" — word-phrased + state word (`TimerNarration`, Linux-tested) | ✅ (UI test: paused value) |
| Cook mode | pager Back/Next/Complete | labels present | + ≥44pt, haptics, `Complete recipe` id | ✅ (UI test: hit targets) |
| Console tiles | Pause/Resume/+2/+5/Cancel | small-text buttons | ≥44pt frames (console keeps text-only layout — #5 proved icon widening breaks the strip) | ✅ (UI test on cook wall) |
| Timer alerts | OK | system alert | unchanged (UIKit-provided semantics) | ✅(static) |

## Dynamic Type (largest accessibility size)

- All text uses semantic fonts (`.largeTitle`, `.headline`, `.title2`,
  `.body`), never fixed point sizes, so AX sizes scale everything.
- The cook-mode step column is a ScrollView; the pager is bottom-pinned —
  step text may grow/truncate gracefully but the current step, timer
  controls, and pager stay reachable.
- UI test `testLargestAccessibilityTextKeepsCookControlsReachable` launches
  with `-UIPreferredContentSizeCategoryName
  UICTContentSizeCategoryAccessibilityXXXL` (the largest category) on
  iPhone 17 — the smallest supported test device — and asserts the step
  counter, start-timer, and pager remain hittable.
- Evidence: the test proves the override RESOLVED via the
  `-ui-testing-report-size-category` readout strip (an id'd caption that
  prints `EnvironmentValues.sizeCategory`; mounted only under the flag),
  and attaches AX-sized screenshots to the xcresult
  (`cook-ax-xxxl-entry`, `cook-ax-xxxl-controls`) — those attachments, in
  the run's `cookconsole-test-results` artifact, are the committed visual
  evidence (the runner is the only place iOS layout renders; no simulator
  exists on the Linux executor).

## Contrast (WCAG AA, timer states)

`TimerStatePalette` (Features/TimerStatePalette.swift) — measured ratios:

| State | Light mode | Dark mode |
|---|---|---|
| running | primary label (system-tuned ≥4.5:1) | primary label |
| near-zero (≤60s) | #7A4E00 on white = **7.20:1** (AAA) | #FFB340 on black = **11.77:1** (AAA) |
| done | #1B5E20 on white = **7.87:1** (AAA) | #A5D6A7 on black = **12.78:1** (AAA) |

Deliberately NOT system `.orange`/`.green` (light variants ≈3.1:1 on
white — fails AA). Color is never the only carrier: the state word rides
the accessibility value.

## Hit targets (≥44×44pt)

UI test `testCookModeControlsMeetMinimumHitTargets` measures frames:
pager (60pt), start-timer (56pt), Pause/Resume/+2/+5/Cancel (min-frame
44pt). Console strip buttons carry the same minimum frames.
Detail servings −/+ were already 44pt minimums (#3).

## Haptics (respecting the system setting)

- Timer completion → `UINotificationFeedbackGenerator.notificationSuccess`
  fired from the single presentation choke point
  (`AppStore.presentNextCompletionIfNeeded`), so both alert surfaces get
  it exactly once.
- Step advance → light impact; final Complete → rigid impact.
- UIKit feedback generators no-op when Settings → Sounds & Haptics →
  System Haptics is off — no app-side toggle needed, and none added.
- ⚠️ Haptic occurrence is not observable from XCUITest; verified by code
  path + the fact the call sites sit on asserted-reachable controls.

## Scope notes

- No new networking APIs (gate unaffected); no fold APIs.
- One-handed ergonomics: cook-mode controls stay bottom-weighted
  (pager bottom-pinned, Add Recipe in a bottom inset since #3); the
  console strip pins TOP per the #5 {-1,-1} safe-area lesson — a
  bottom-mounted strip is what broke the pager there.

## Test map

- Linux (`Tests/CookConsoleTests/TimerNarrationTests.swift`): state
  machine boundaries (60s threshold, paused-never-nearZero), spoken
  phrasing (no ':' anywhere in 0–3600s), duration labels, state words.
- iOS (`Tests/CookConsoleUITests/AccessibilityUITests.swift`): paused
  timer value "…, paused" without ':'; library row + servings narration;
  ≥44pt frames; AX XXXL reachability + screenshots.
