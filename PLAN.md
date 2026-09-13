# Cook Console — PLAN.md

## Scope

A local-first iOS cooking companion whose core interaction is the **console/detail split**: a persistent, glanceable "now cooking" surface (current step, next step, live timer wall) plus a detail surface (full recipe, notes, history). MVP is manual/plain-text recipes with servings scaling, step-by-step cook mode, multiple concurrent per-step timers with local notifications, session notes, and user-owned JSON/CSV export.

Explicitly out of scope for MVP: accounts/cloud, recipe scraping/OCR, meal planning, grocery integration, nutrition/health claims, AI features, Android, and any use of unavailable iPhone Duo fold SDK APIs.

## Architecture

```
CookConsoleApp (SwiftUI, iOS 26 SDK)
├─ App layer          App entry, navigation, size-class router
├─ Feature views
│   ├─ LibraryView    recipe list, search, tags, create/import
│   ├─ RecipeView     full recipe, servings scaler, start cook
│   ├─ CookModeView   step pager (one step, large text), timer slots
│   ├─ ConsoleView    now/next + timer wall (compact strip / left pane)
│   └─ HistoryView    sessions, notes, favorites, exports
├─ Domain layer (pure Swift, no UI/DB imports)
│   ├─ Recipe model, Ingredient (amount+unit), Step (timerable)
│   ├─ ScalingEngine  servings ratio -> human-friendly amounts (fractions)
│   ├─ TimerEngine    concurrent named timers, state machine, persistence
│   └─ Session        cook session log (steps done, timers, notes)
├─ Data layer         GRDB/SQLite store; JSON/CSV exporters; file import
└─ Services           LocalNotificationService, BackupCoordinator
```

- **State**: observable view models over the domain layer; timer ticks via a single scheduler; timer state persisted so force-quit/reboot resumes with correct remaining time (wall-clock deadlines, not tick counters).
- **Size-class routing** is the Duo seam: `ConsoleLayout = .compactStrip | .splitView`. Today the choice comes from horizontal size class; the future fold API will drive the same enum to bind `ConsoleView` to the secondary display. No other code may assume screen topology.

## Technology choices

| Choice | Rationale |
|---|---|
| Swift + SwiftUI, iOS 26 SDK (required minimum for build & CI) | Team-standard declarative UI; Dynamic Type/accessibility come free; iOS 26 is a hard project requirement. |
| GRDB (SQLite) | Local-first relational store, migrations, strong testability; no cloud coupling. |
| UserNotifications (local only) | Timer completion alerts; zero network surface. |
| XCTest (unit + snapshot-style layout tests) | First-party, CI-friendly. |
| GitHub Actions + App Store Connect API | iOS 26 SDK macOS runner builds, signs with ASC secrets (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`), uploads to TestFlight. Secret names only, never values. |

## Milestones & dependency order

1. **M1 Skeleton** — Xcode project, iOS 26 SDK pin, CI build+test job, lint. *(blocks everything)*
2. **M2 Data/domain core** — Recipe/Step/Ingredient models, GRDB store, ScalingEngine with fraction-rounding rules, unit tests. *(depends on M1)*
3. **M3 Cook mode + timers** — step pager, TimerEngine state machine, local notifications, crash-resume from deadlines. *(depends on M2)*
4. **M4 Adaptive console/detail layout** — compact strip vs regular-width split, fold/unfold continuity of cook session. *(depends on M3)*
5. **M5 Import/export/backup** — JSON/CSV export, JSON import with validation + merge, privacy doc. *(depends on M2; can parallel M3)*
6. **M6 Release** — accessibility audit pass, TestFlight pipeline via ASC API, versioning/notes. *(depends on M3–M5)*

## Testing strategy

- **Domain unit tests**: scaling math (ratio edge cases, zero/fractional servings), timer state machine (start/pause/extend/fire/deadline-resume), session logging.
- **Persistence tests**: in-memory SQLite migrations, repository CRUD, import validation failures.
- **UI tests**: cook-mode happy path, timer tile interaction, size-class layout swap preserving session state.
- **Notification tests**: scheduling/cancellation contract via injected `NotificationCenter` fake (no wall-clock sleeps).
- No test may claim device/hardware results from simulator runs; TestFlight beta feedback is the device-evidence channel.

## Packaging / distribution

- Ad-hoc debug builds from CI artifacts.
- TestFlight first release via App Store Connect API (bundle ID `com.infinityball.cookconsole`, already registered; signing team = `ASC_TEAM_ID`).
- Public App Store submission deferred until M6 evidence exists.

## iPhone Duo migration path

1. Now: adaptive two-column layout chosen by size class. `ConsoleLayout` enum is the single seam.
2. When Apple ships fold/split-display APIs: map the API's display partition to `.splitView`, host `ConsoleView` on the secondary display, keep domain layer untouched.
3. Add fold/unfold continuity handling (scene phase + session snapshot) — session and timers already survive process restart, so this is a presentation concern.
4. Re-audit hit targets/orientation for the second display geometry.

## Risks

| Risk | Mitigation |
|---|---|
| Fold SDK timelines shift | Design target only; adaptive layout ships value today. |
| Timer reliability under OS backgrounding | Wall-clock deadlines + notification-based completion + on-launch reconciliation. |
| Scaling produces ugly amounts ("0.33 tsp") | Rounding rules table with unit-specific fraction snapping, covered by unit tests. |
| Scope creep toward recipe platforms (scraping, plans) | Hard non-goals list; issues must fit MVP. |
| iOS 26 SDK availability on CI runners | Pin runner image; fail CI loudly if SDK < 26. |

## Non-goals (restated)

No cloud, accounts, scraping, OCR, nutrition advice, medical claims, Android MVP, or fold-API dependencies.
