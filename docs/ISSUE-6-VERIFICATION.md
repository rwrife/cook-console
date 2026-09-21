# Issue #6 verification — export/import + privacy audit

## What shipped

- `BackupDocument` (versioned schema v1: header {schemaVersion, exportedAt,
  appVersion} + recipes + sessions + timers + timer events).
- `DataTransferService` (`Sources/CookConsole/Data/`): JSON backup export,
  cook-history CSV export, pure pre-write validation (schema version,
  per-item semantic + cross-reference checks with `path: reason` errors),
  and all-or-nothing merge inside one `database.write` transaction.
  Merge-not-clobber keyed on stable item IDs: unknown recipe IDs are added;
  known IDs are replaced only when the incoming copy re-validates through
  the domain model; session/timer/event rows are append-only (existing IDs
  skipped). Restored timer rows temporarily reactivate their session (the
  app's own `cook_timers_valid_identity_insert` trigger requires an active
  session) and the session's true final status is restored before commit.
- In-app **Your data** screen (`Features/YourDataView.swift`, toolbar entry
  in the library): one-tap JSON backup + CSV history export through
  `ShareLink` (system share sheet / Files), JSON import through
  `.fileImporter`, the last-import conflict summary, and the written
  privacy statement (on-device storage, zero network requests, optional
  notifications-only permission, delete-app-deletes-everything).
- `AppStore.exportedJSONBackupURL() / exportedHistoryCSVURL() /
  importJSONBackup(from:)` — security-scoped access around the picker URL.
- `AppInfo.versionStamp` embedded in every backup header (provenance).
- README privacy section now documents the shipped behavior.
- CI zero-network grep gate (pre-existing `privacy-gate` job) already covers
  the audit criterion; it passes on this tree.

## Evidence (2026-09-21)

- Linux core (`wine-vault-swift-sqlite:6.1`, Swift 6.1.3,
  `swift test -Xswiftc -warnings-as-errors`): **95 tests, 0 failures**
  (12 new `DataTransferServiceTests`: versioned header provenance,
  encode/decode round-trip, full export→import→export fidelity into a clean
  store (recipe, session, completed timer, started/extended events),
  identical-reimport no-op, replace-vs-add merge, unknown-reference rejection,
  mid-file failure rollback, schema-version rejection, malformed rejection,
  per-item `ingredient[0]` path reporting, timer-shape rejection, CSV
  headers/quoting). These are real GRDB + trigger-gated SQLite runs, not
  mocks. **Not iOS evidence.**
- `swiftc -parse` clean on all changed/new files (incl. SwiftUI layer).
- `Tools/gen_project.rb` regenerated `CookConsole.xcodeproj` (Docker ruby);
  new sources/tests present in the pbxproj.
- Zero-network grep gate pattern run locally over Sources/ + Tests/: pass.
- Native merge gate: CI `build-test` (macos-26, iPhone 17 + iPad (A16)
  destinations) must go green before merge, including the new
  `DataOwnershipUITests` (toolbar entry, privacy statement by AX id, export
  -> share item, import entry point). CI run URL recorded in the PR.
