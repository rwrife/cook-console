# Issue #25: bundled starter cookbook updates

Version 1 contains **two authored recipes**, Simple Stovetop Oats and Lemon
Cucumber Chickpeas. `StarterCookbookPack.bundled()` compiles the content into
both the app and the Linux core target. The six pre-existing demo screenshot
seed recipes are test fixtures, not an installed user cookbook. There is no
100-recipe catalog, and neither new recipe has a claimed physical kitchen test.

The library's Starter Cookbook toolbar entry opens a read-only review. Each
recipe shows its action and links to current/proposed ingredients, instructions,
timers, tags, and guidance. Accept installs new recipes and updates unedited
starter content; edited recipes, identity collisions, and archived/purged entries
are explicitly kept. Skip suppresses that version; a higher bundled version can
be offered. Simply launching, refreshing, or dismissing never installs anything.

Recipe, ingredient, and step UUIDs are fixed. Matching never uses titles. Future
pack revisions must increment the version and retain UUIDs for the same logical
items. Include the complete offered cookbook in each version so users can skip
intermediate releases. Omitted recipes are not deleted.

Baselines and version decisions use existing `app_metadata`; no migration or
backup schema-version bump is needed. The optional `starterCookbookMetadata`
backup field carries only validated starter keys. Legacy imports preserve local
provenance, local decisions never downgrade, and existing baseline/tombstone
metadata wins import collisions. A retained baseline with no recipe is a purge
tombstone. Backups preserve that state even when no recipe remains to export.

Acceptance compares a freshly read review inside the same database write
transaction that updates recipes, baselines, and the accepted version. It rejects
stale reviews and blocks destructive updates during active cooks or running/paused
timers. Favorites are copied from the current recipe; personal notes, ratings,
completed sessions, and timer/event history are untouched. Child replacement uses
the existing repository operation only after these checks.

Validation performed locally:

- Initial focused XCTest failed at runtime because backup/restore lost a skipped
  version; the minimal backup change made it pass before service implementation.
- Expanded service tests first failed to compile for the missing service, then
  passed after implementation. Fourteen focused XCTests cover install/review,
  repeated acceptance/reopen, skipped versions, edits, UUID/title collisions,
  archive/purge, backup/legacy import, active cooks/live timers, stale review,
  rollback after additions and updates, and retained completed timer history.
- Docker `swift:6.1` with `libsqlite3-dev`: **216 XCTest + 6 Swift Testing passed**,
  using `swift test -Xswiftc -warnings-as-errors`.
- Docker `swiftc -parse` passed for AppStore, every feature source, and the new
  UI tests. This checks syntax, not SwiftUI/UIKit type correctness.
- Xcodeproj regenerated using `ruby:3.3-slim`; its generated Package.resolved
  deletion was restored. Source/test membership includes all four new Swift files.

The first dependency checkout stalled on the NFS worktree. SwiftPM initially
contacted GitHub to resolve the pinned GRDB dependency; subsequent runs used a
local mirror of the same pinned revision and container-local scratch storage.
No GitHub API/issue/PR operations, commits, or pushes were performed. A first full
suite overlapped project regeneration and failed its project-file checks; the
finalized project's complete suite passed on rerun.

CI-only gaps: native iOS compilation and simulator/device execution, including
the two new accept/skip/relaunch UI journeys, toolbar reachability, and VoiceOver
layout. These have not been run or claimed green locally. No CI was triggered.
