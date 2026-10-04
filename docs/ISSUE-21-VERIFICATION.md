# Issue #21 Verification — Recipe Validation & Kitchen Testing

## What shipped

| Area | Artifact |
|---|---|
| Editorial audit (AC #1/#2/#3) | `Sources/CookConsole/Domain/RecipeTextMatching.swift`, `RecipeEditorialAudit.swift` — ingredient↔instruction cross-check with naive plural/part-name matching, curated glossary for unlisted-ingredient detection, salt/pepper/water/ice exemptions, oven-temperature requirement, 5 s–8 h timer plausibility band, and a `timeOnlyDoneness` advisory that states a timer never establishes doneness |
| Editorial exceptions (AC #1) | `EditorialException` — phrase + mandatory written justification; enforced by construction (custom `init(from:)` routes JSON through the validating initializer) and applied only via per-recipe reviewed allow-lists |
| Kitchen-test ledger (AC #4/#5) | `Domain/KitchenTestLedger.swift` — `RecipeReviewRecord` (status, provenance, content revision, exceptions, queue priority) + `KitchenTestObservation` (date, result, reproducible notes, tester). `kitchenTestStatus` is **derived only from observations**; there is no setter and no code path from the audit engine to a kitchen-tested claim |
| Persistence | migration `v10_create_recipe_review_ledger` (`recipe_reviews`, `kitchen_test_observations`) + `Data/RecipeReviewRepository.swift` (upsert metadata, append-only observations, FK-cascading delete, observations clear the queue slot) |
| Review pack | `ReviewPack/RecipeReviewPack.starter-seed-v1.json` — desk-review status, provenance, justified exceptions, prioritized queue for the 6 starter-seed recipes; bundled as a blue-folder resource |
| CI gates (AC #6) | `Tests/CookConsoleTests/RecipeReviewLedgerTests.swift` — bidirectional status↔audit gates (a `desk_review_passed` claim must audit clean; an `issues_open` claim must still reproduce), no-tested-without-evidence canary, seed↔pack coverage, queue/gap-summary determinism, repository round-trip/FK/validation tests |
| In-app review board (AC #4/#5) | `Features/RecipeReviewBoardView.swift` — library footer "Review" entry, coverage banner, per-recipe desk/kitchen badges, provenance, queue ranks, and a kitchen-test recorder with domain-enforced mandatory notes. `RecipeReviewBoardUITests` covers the journey |

## Honest status of the "100 recipes" premise

The issue text assumes a 100-recipe starter catalog. As of `f68c5ac` the repository
contains **no 100-recipe catalog** — the only starter content is the 6-recipe demo
seed in `Tools/seed_screenshot_recipes.py` (used for screenshots/simulator seeding).
The review pack therefore covers those 6 recipes exhaustively; a future 100-recipe
catalog ships as additional pack files that the same CI gates consume (the pack
schema already supports optional embedded content snapshots). **This is a scope
finding, not a silent skip**: AC #2's "all 100 recipes" cannot be truthfully
satisfied against content that does not exist in the repo.

## Desk review actually performed (AC #2/#3)

Every seed recipe was desk-reviewed through the audit engine on 2026-10-04:

- **Creamy Tomato Soup, Lemon Herb Rice, Roasted Carrots, Sunday Pancakes,
  Garlic Butter Pasta** — content is editorially sound; Pancakes carries three
  *justified* batter-style exceptions (step 1 references the whole list
  collectively). Kitchen-tested: no. Queue priorities 2–6 assigned.
- **Chickpea Salad — REAL DEFECT FOUND**: step 2 uses lemon juice but the list
  omits it. Marked `desk_review_issues_open` with priority #1. Correct fix is a
  content revision, not an exception (recorded in the pack's review note).
- Timer plausibility: all six timers sit inside 5 s–8 h; the two timed-only steps
  keep `timeOnlyDoneness` advisories open (doneness cues to be added when the
  content revision lands).

## Verification evidence (exact provenance)

- **Linux (real tests, this host)**: `wine-vault-swift-sqlite:6.1`,
  `swift test -Xswiftc -warnings-as-errors` → **179 XCTest passed + 6
  swift-testing passed** (baseline was 150+6; +23 review-related). Zero warnings.
- **Local static only**: `swiftc -parse` clean on the three Darwin-only files
  (AppStore.swift, RecipeReviewBoardView.swift, RecipeLibraryView.swift) —
  parse-only, member names NOT checked there.
- **Privacy gate**: local reproduction of the CI grep → zero networking-API
  references in Sources/ Tests/.
- **Not yet proven (CI-gated)**: the macOS/iOS build of the new SwiftUI views,
  the UI journey test on the iPhone 17 simulator, and the pbxproj wiring —
  these run in the PR's GitHub Actions run; see the PR CI link in this issue's
  closing comment. No simulator or device behavior is claimed here.

## Remaining manual gaps (published by CI, AC #6)

Physical kitchen tests: **0 of 6** — the queue (Chickpea Salad #1, Sunday
Pancakes #2, Garlic Butter Pasta #3, Creamy Tomato Soup #4, Roasted Carrots #5,
Lemon Herb Rice #6) stays open until cooked with written notes. Doneness-cue
advisories and the Chickpea Salad data defect remain open editorial work.
