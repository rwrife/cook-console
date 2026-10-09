# Issue #24 — Personal notes, ratings, and cooking history

- Recipe detail opens **Notes, rating & cooking history**. Every recipe, including starter content, supports free-text notes and an optional 1–5-star rating.
- Save commits both fields atomically. Cancel discards edits. Clear changes the draft only until Save. Notes preserve whitespace and line breaks, with a 20,000-character limit.
- Personal data lives in `personal_recipe_notes`, keyed by recipe ID, separately from instruction/content rows. `RecipeRepository.update` never writes it: future starter updates must preserve recipe IDs and update content in place rather than delete/reinsert rows.
- Archive/restore retains personal data and cooking history. Permanent deletion cascades both. Archived recipes cannot save new personal edits.
- Last cooked is the latest **completed session end date**, not start time, active progress, or abandoned sessions. The linked history shows completed sessions for this recipe only, newest completion first; never-cooked recipes show an explicit empty state.
- JSON v1 adds optional `personalNotes`. Imports validate IDs, uniqueness, ratings, and note length before any write. Incoming personal records win after recovery preview, including an explicitly cleared record. Absent/legacy records leave existing personal data untouched. Archived personal records also export/import. Preview reports record count and policy, rolls back all trial writes, and detects stale database state before apply.
- No cloud, accounts, networking, health claims, or fold SDK APIs were added.

## Evidence boundaries

Linux SwiftPM tests exercise repository persistence across database reopen, editing/content-update preservation, archive/restore/purge, validation, JSON round trips, legacy-field omission, incoming clear conflicts, preview rollback, and history dates including no completed sessions. Linux does not compile SwiftUI/UIKit application paths.

Native CI must build the iOS application and run the simulator UI journey (rating edit/save/relaunch, notes editor reachability, never-cooked history). TextEditor accessibility values are unreliable on iOS: exact note text persistence is proven by repository tests, not an invented UI value assertion. No physical-device or TestFlight evidence is claimed.

Verification results and CI links are recorded in the PR.
