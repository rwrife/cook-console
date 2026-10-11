# Dual-Screen Migration — the Console/Detail Seam

Issue #5 builds the console/detail split as the **documented migration
target** for the iPhone Duo's second display. This file describes exactly
how a future fold/split-display API plugs in — and what must not change
when it does.

## Today's shape

- `ConsoleLayout` (`Sources/CookConsole/Domain/ConsoleLayout.swift`) is the
  **single seam** for layout choice: `.compactStrip` or `.splitView`.
- Its only input is `ConsoleLayoutInput`, which carries **nothing but the
  horizontal size class signal** (`.compact` / `.regular`). The
  initialization is a total, pure function of that input.
- `ContentView.syncConsoleLayout()` is the app's **only** writer of the
  layout input: it reads `@Environment(\.horizontalSizeClass)` and nothing
  else. Compact → `RecipeLibraryView` with the console strip pinned as a
  **top** `safeAreaInset` (bottom insets collided with the bottom-anchored
  Cook/Add buttons in hosted simulators — see runs 35513947368 and
  35516090570). Regular → `RecipeWorkspaceView`, an explicit two-pane
  split (`HStack`: `ConsoleSplitPane` leading + library/detail navigation
  trailing). `NavigationSplitView` is deliberately avoided: on iPhone even
  regular widths it presents one column at a time, hiding the library.
- Cook Mode keeps its own inline timer wall (unchanged from #4). The root
  strip and the split pane suppress themselves while the cook cover is up,
  so shared timer-control accessibility identifiers are never duplicated
  in the hierarchy.
- Console state is durable, not view-local: `AppStore` mirrors the active
  `CookSession` (reloaded from the repository via `fetchCookSession(id:)`
  whenever a cook surface (re)adopts its timers), so the session survives
  rotation, size-class transitions, and modal presentation alike. The UI
  test `ConsoleSplitUITests.testCookSessionSurvivesRotationAcrossSizeClasses`
  exercises this rotation (compact ↔ regular) rehearsal.

## Review invariants (code review enforces)

1. Layout selection derives **only** from `ConsoleLayoutInput`. No device
   model checks, no geometry/posture/fold APIs anywhere in layout logic.
2. Only `ContentView.syncConsoleLayout()` writes
   `AppStore.consoleLayout`, and only through
   `applyConsoleLayout(input:)`.
3. `ConsoleLayoutInput` stays a pure size-class signal (see
   `ConsoleLayoutTests` exhaustive switch).
4. The console wall is exactly one mounted control surface at a time.

## Tomorrow's fold/split-display binding

When Apple ships fold or split-display APIs, migration is a **source-of-
input swap**, touching one function:

1. Observe the API's display partition (e.g. "the app spans two displays"
   or "second display available").
2. Where the partition means "the console has its own screen", call
   `store.applyConsoleLayout(input: .regular)` from that observer instead
   of (or in addition to) the size-class onChange, and present
   `ConsoleSplitPane` on the secondary display while the primary shows the
   detail column. Because `ConsoleLayout`/`ConsoleSurface` content already
   renders identically wherever it is mounted, no view body, domain type,
   or repository changes are needed.
3. `ConsoleSplitPane` remains the sole renderer of the console surface, so
   the secondary-display host is just another mounting site for it.

If a future API instead exposes an explicit topology signal, it maps onto
the same two-element input enum (`.compact` = single display,
`.regular` = console gets its own surface). The enum deliberately has no
third state: the MVP never branches on topology beyond "console together
vs. apart".


## Issue #26 iPhone Duo Steps/Prep Implementation (2026-10-11)

### Official SDK Findings (WWDC / Tech Talks)
1. **Outer Display & Simultaneous Multi-display**:
   - `CameraCaptureAccessory` is the only official public API for outer-display pairing on iPhone Duo; it strictly requires a foreground, full-screen inner display with an active camera session (`AVCaptureSession`). Starting a camera session purely to unlock a secondary cooking display violates privacy, power, and app intent principles.
   - Secondary standalone window creation via `UIWindowScene` is restricted by Apple to the **inner display** (outer display does not allow arbitrary extra scene creation).
2. **Inner Display Dual-Pane Architecture**:
   - The supported inner-display experience for side-by-side workflows is an adaptive two-pane layout (`Steps` & `Prep`) with automatic fallback to single-screen modal presentation on compact sizes.
   - To avoid hardcoded hinge thresholds or device checks, layout responds to standard SwiftUI `horizontalSizeClass` and system display regions.
3. **Session & Persistence Model**:
   - Single shared `CookSession` in GRDB ensures both panes reflect the identical state.
   - Preparation state (`servings`, `checkedIngredientIDs`, `equipment`, `swapped`) is persisted in `cook_prep` (migration `v14_cook_prep`), keyed by `session_id`.
   - Browsing or toggling prep ingredients never mutates `currentStepIndex`.
   - Role swapping ("Swap Steps and Prep") is supported on regular width without resetting active step, prep checks, or running timers.
