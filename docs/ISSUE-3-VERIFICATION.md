# Issue 3 workflow and verification

## Delivered workflow

- The Recipes screen sorts favorites first and then by latest completed cook,
  with title search and an exact tag menu filter.
- New and edit sheets persist title, servings, favorite state, ordered
  ingredients (amount, unit, name), ordered steps (including optional timer
  duration), and tags through the existing transactional repository.
- Recipe detail recalculates every displayed ingredient immediately through
  `ScalingEngine`, with `-0.5`, `+0.5`, and reset controls.
- Cook mode displays one Dynamic Type step, a counter, and next/back controls
  with a minimum height of 60 points. Full-recipe escape retains the active
  session and position. Completion and confirmed abandonment are local
  terminal session records.
- `-ui-testing-reset` deletes only the app's local SQLite test files before UI
  test launch; production launches never reset storage.

No network, account, cloud, or fold-device API was introduced.

## Strict red/green evidence

Each executable cycle used the Swift 6.1 SQLite image, host UID/GID, a fresh
writable temporary `HOME`, `/workspace` as the consistent mount, and
`swift test -Xswiftc -warnings-as-errors --filter <test>`.

| Behavior | Observed red | Green focused result |
|---|---|---|
| favorites then recency ordering | missing completed-cook and `fetchLibrary` APIs | 1 test, 0 failures |
| trimmed case-insensitive title search | `fetchLibrary` accepted no search argument | 1 test, 0 failures |
| case-insensitive whole-tag filter | extra `selectedTag` argument | 1 test, 0 failures |
| session begins immediately and resumes | missing `beginCook` and session APIs | 1 test, 0 failures |
| cook position persists | missing `updateCookPosition` | 1 test, 0 failures |
| complete and abandon logging | missing `endCook` | 1 test, 0 failures |
| bounded one-step navigation | missing `CookProgress` | 1 test, 0 failures |

The four UI tests were written before implementation, added to the generated
`CookConsoleUITests` target, and included in the shared scheme. They cover
create-to-library persistence, scaled amounts/reset, and cook next/back plus
position-preserving full-recipe escape, plus active-search retention after a
save. Long-form interactions explicitly wait for controls, scroll them into a
hittable position, and dismiss the keyboard before lower controls and Save.
Linux cannot execute iOS UI tests, so
their result is honestly pending the canonical macOS 26 / iPhone 17 CI run.

## Local integration evidence

- Full Linux core run: 49 tests executed, 0 failures, warnings as errors.
- Swift syntax parse: every `.swift` file under `Sources` and `Tests` parsed by
  the Swift 6.1 container with no diagnostics.
- Project: regenerated from `Tools/gen_project.rb` using `ruby:3.3-slim` and
  `xcodeproj` 1.28.1; generated files remain owned by the host user.
- GRDB: SwiftPM remains fixed at 7.11.1 and the Xcode project remains pinned to
  revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
- CI YAML parsed successfully; the zero-network scan and `git diff --check`
  passed. iOS build and UI execution require canonical macOS CI and are not
  claimed locally.
