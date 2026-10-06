# Issue #22: backup and recovery

Changes are confined to the isolated `feat/issue-22-recovery` branch based on `c44fbba`. No credentials, tags, cron, networking APIs, or fold SDK changes are included.

## User behavior and exact backup scope

The existing library toolbar entry now says **Backup & recovery**, retaining the `Your data` accessibility identifier. The library footer remains three buttons. The data screen has one import entry, Save JSON backup, an explicit scope statement, persistent last confirmed save, Deleted Recipes with Restore and confirmed permanent deletion, CSV history sharing, and privacy statements.

JSON schema remains version 1. Existing grocery arrays stay optional, and `recipes[].deletedAt` is an optional additive ISO-8601 date. Included: every live/deleted recipe, deletion date, ingredients, steps, tags, favorites, scaling notes, cook sessions, timers/events, grocery recipe selections and checked ingredient keys, and manual grocery lines/checks. Excluded: pantry items and staples, review provenance/editorial exceptions/priorities and kitchen-test observations, settings, notification permission/schedules, pending completion alerts, and last confirmed backup timestamp. These omissions are explicitly explained in-app; JSON cannot recover them. Old documents may omit groceries or deletion dates.

Only `.fileExporter` success with a local destination URL calls save confirmation. Generation, cancellation, errors, and CSV do not. Confirmation is stored in `app_metadata`, surviving service/app recreation. Copies outside the app survive app removal; the database, archive, and temporary exports inside the app do not. No claim is made that a saved file remains available forever.

## Preview, conflict policy, and atomicity

The file is read under security-scoped access, decoded and semantically validated, then captured in an immutable preview. Preview runs the exact production merge in a rolled-back savepoint, reporting recipe additions/kept content/replacements and library/archive outcomes, plus counts for history and groceries. Apply uses the captured document; changing the source file cannot substitute different bytes after preview. Cancel discards the preview and changes no persisted data.

Backup content wins for matching recipe IDs; identical content is kept. History/timer/event/grocery/manual IDs already present are kept. Missing items are retained. Incoming deletion dates archive recipes; absence of a deletion date **never clears** an existing deletion date. Deleted recipes' active sessions are abandoned, running/paused timers canceled, completion alerts cleared, and grocery selections removed/excluded. Preview reports excluded grocery selections separately. Pantry and review records are untouched. Imported active timers for live recipes use their saved deadlines; this is disclosed in the conflict policy and preview.

Apply compares all user-table contents, plus SQLite change/data/schema counters, in the same transaction as the merge. Any intervening write (even a write restored to its original value), external commit, or schema change refuses apply and asks for a fresh file preview. Every import entry point validates, and merge failures roll back the whole file. UI refresh/notification failures after a successful transaction are reported as data already updated, rather than misreporting the import as uncommitted.

## Recoverable deletion

Migration `v11_recoverable_deletion` adds nullable `recipes.deleted_at`. Delete archives the parent and preserves recipe children, cook history, and local review/test records. Archived recipes are excluded from ordinary fetch, library/search, cook start, pantry suggestions, and grocery additions. Deletion stops active timers, increments notification generations, abandons sessions, clears completion alerts, removes grocery selections, and synchronizes scheduled notifications. The console clears its deleted/ended session mirror.

Retention has no expiry: deleted recipes remain until the user explicitly permanently deletes them. Restore clears only the deletion date; it does not restart cooking or restore shopping selections. Confirmed purge uses the existing FK cascades to remove the recipe, children, history, and review/test records. A previously saved JSON can recover recipe/history but not the excluded pantry/review records. App removal destroys the local archive.

## Paths

Production:
- `Sources/CookConsole/Application/AppStore.swift`
- `Sources/CookConsole/Data/DataTransferService.swift`
- `Sources/CookConsole/Data/RecipeDatabase.swift`
- `Sources/CookConsole/Data/RecipeRepository.swift`
- `Sources/CookConsole/Data/GroceryRepository.swift`
- `Sources/CookConsole/Features/YourDataView.swift`
- `Sources/CookConsole/Features/RecipeLibraryView.swift`
- `Sources/CookConsole/Features/RecipeDetailView.swift`

Tests:
- `Tests/CookConsoleTests/DataTransferServiceTests.swift`
- `Tests/CookConsoleTests/RecipeRepositoryTests.swift`
- `Tests/CookConsoleTests/RecipeReviewLedgerTests.swift`
- `Tests/CookConsoleTests/TimerEngineTests.swift`
- `Tests/CookConsoleUITests/DataOwnershipUITests.swift`

Documentation:
- `README.md`
- `docs/ISSUE-6-VERIFICATION.md` (historical workflow marked superseded)
- `docs/ISSUE-22-VERIFICATION.md`

## Automated and manual verification

Domain tests were added before implementation. Existing import tests remain in place. Added coverage includes preview additions/conflicts/cancel, mutation-free preview, stale and reverted-state refusal, source-file replacement after preview, malformed/direct-invalid imports, simulated mid-write failure during preview and apply with transaction rollback, archive JSON/history round trips, restore/purge, legacy imports retaining deletion state, grocery exclusions and no re-add on restore, canceled active sessions/timers, notification cleanup, and persistent save confirmation versus generation/CSV.

The UI suite uses `-ui-testing-reset -ui-testing-recovery-fixture`: a local recipe and local JSON fixture exercise production validation, preview cancellation, apply, deletion, and restore without automating the system file picker. Fixture controls require both flags. Existing UI identifiers are retained; identifiers are on leaves, and lazy List cells are realized before geometry-gated taps.

Final Linux results: **189 XCTest tests plus 6 Swift Testing versioning tests passed**, with `-warnings-as-errors`; Swift 6.2 parsed all Features sources, AppStore, and DataOwnershipUITests successfully; `git diff --check` passed. Test logs are in `/home/rwrife/.hermes/cache/scratch/issue22-tests.log`.

The successful container invocation used the existing Swift 6.2 image, installed `libsqlite3-dev` only inside the container, and ran as container UID/GID 1000 under `--userns=keep-id:uid=1000,gid=1000`. This maps to the invoking host user (UID 1001 here), avoiding the initial shared-build ownership error. Scratch build output is under `/home/rwrife/.hermes/cache/scratch/issue22-build`, mounted as `/build`; the tested command was `swift test --scratch-path /build -Xswiftc -warnings-as-errors`. No host packages were installed.

Linux SwiftUI parsing does not typecheck SwiftUI/UIKit. Xcode iOS typechecking and simulator UI execution remain pending because this environment has no Xcode/iOS SDK.

Manual iOS checks:
1. With search dismissed, open Backup & recovery at normal and accessibility XXXL sizes; confirm footer still has three reachable actions.
2. Save JSON to Files; confirm the timestamp appears and survives relaunch. Prepare JSON then cancel Files; verify timestamp unchanged. Export/share CSV; verify timestamp unchanged.
3. Pick valid old/new JSON; inspect additions, conflicts, archive outcomes, grocery exclusions, and policy before Apply. Cancel and verify no change. Alter the library after preview and confirm refusal/re-preview guidance.
4. Pick malformed JSON; verify no mutation. Delete a recipe with an active timer; verify notification removal, idle console, no library/search/pantry/grocery contribution, archive Restore, stopped cook after restore, and confirmed permanent purge.
5. Save archive JSON outside the app, reset local storage, import, and Restore. Verify history remains; confirm pantry/review omissions match the disclosure.

The project generator ran successfully with Ruby 3.3 and xcodeproj 1.28.1. With no new source files, its random UUID-only churn was reverted, and the unintended `Package.resolved` deletion was restored. Generated files are owned by the invoking host user.

## PR #34 review blocker fixes

Completed-timer restart checks the persisted recipe deletion date, session identity/status, and current step inside the same database write transaction as the restart. Late delivered extension actions after archive or session end return false, clear pending/delivered notifications and completion alerts, and leave history unchanged; repeated actions are benign. Restore does not make an abandoned cook eligible again.

Recipe replacement keeps exactly the incoming visible steps. Completed/cancelled timers retain their historical step UUID and nonblank immutable `stepName` snapshot even when that UUID is absent from current steps. Their recipe must exist and match the referenced session; an absent recipe/session or mismatched pair is rejected. A historical UUID is snapshot provenance, not a live foreign key to current steps. Completed/abandoned session positions retain nonnegative historical indices, which may exceed the current recipe length. Active session positions must remain in range. Running/paused imported timers still require a current step and active session; arbitrary dangling live step IDs are rejected. Replacing a recipe cancels retained running/paused timers for removed steps, increments notification generations, and clears their completion alerts, preserving snapshots/events. Existing active cook positions are clamped to the new steps. Migration `v12_historical_timer_identity` applies the same live-versus-ended identity policy to database inserts without temporarily activating ended sessions.

Regression coverage includes completed timer → archive/session end → repeated late extension, shortened replacement → export → clean-store preview/apply with unchanged historical snapshots/positions, removed live-step cancellation and clean restore, dangling live steps, negative historical positions, and recipe/session mismatch rejection. Linux validation uses Swift 6.2 with `-warnings-as-errors`, shared parent mount `/home/rwrife/repos`, and container scratch `/tmp/issue22-build`. No Xcode/iOS SDK is available locally.

Review-fix validation: **192 XCTest tests and 6 Swift Testing tests passed** with warnings as errors. Swift frontend parsing of all Features, AppStore, and DataOwnershipUITests passed; `git diff --check` passed. The two original blocker regressions were observed failing before production edits, then passing after the fixes. Logs: `/tmp/cook22-red.log` (RED), stopped container `cook22-review-tests` logs (targeted GREEN), and `/tmp/cook22-full.log` (final full suite and parsing). HEAD remains `fd1c49a`; no commit, push, or GitHub write was performed.
