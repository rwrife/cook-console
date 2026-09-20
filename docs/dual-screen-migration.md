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
  else. Compact → `RecipeLibraryView` (with the console strip pinned as a
  `safeAreaInset` above cook-mode content). Regular →
  `RecipeWorkspaceView`, a `NavigationSplitView` whose **leading column is
  `ConsoleSplitPane`** (the console wall) and whose trailing column is the
  normal library/detail navigation.
- Cook Mode pins its own copy of the wall (`ConsoleStripView` via
  `safeAreaInset`), so the timer wall is glanceable in every layout; the
  root strip and the split pane suppress themselves while the cook cover
  is up, so shared timer-control accessibility identifiers are never
  duplicated in the hierarchy.
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

## Out of scope (MVP hard line)

- No fold SDK APIs, no multi-scene/multi-window sessions today, no
  Android, no network. The zero-network CI gate keeps the last one honest.
