# Cook Console — Release Runbook (TestFlight)

Issue #8 pipeline: a green `main` + a version tag produces a signed TestFlight
build via the App Store Connect API. No fastlane/npm is pinned — the pipeline
is `.github/workflows/release.yml` plus `Tools/asc_jwt.rb` (dependency-free
ES256 JWT minter using the runner's stock openssl).

## Secrets (names only — values must never appear in any log)

| Secret | Purpose |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key ID (JWT `kid`) |
| `ASC_ISSUER_ID` | ASC issuer UUID (JWT `iss`) |
| `ASC_KEY_P8` | PKCS#8 EC private key body; written to `$RUNNER_TEMP/asc-api-key.p8` (mode 600), deleted in an `always()` step |
| `ASC_TEAM_ID` | Developer team for automatic signing (`DEVELOPMENT_TEAM`) |

The workflow's first step verifies each secret NAME is present (checking
presence only — it never echoes a value). GitHub's log masking additionally
redacts registered secrets; the pipeline's own rule is "secret variables are
consumed as env inputs only, never interpolated into echo statements."

## Versioning + changelog convention

- `VERSION` (repo root) holds the marketing version `x.y.z` (semver).
- The app's `MARKETING_VERSION` is seeded from `VERSION` by
  `Tools/gen_project.rb`; `Tests/CookConsoleTests/VersioningTests.swift`
  fails Linux CI if the two ever drift apart.
- **Build number = the Actions run number** of the release workflow. It is
  strictly monotonic across every release ever run, so ASC never sees a
  recycled `CFBundleVersion`. `CURRENT_PROJECT_VERSION` in the project is
  only a local baseline (1); the workflow overrides it.
- The tag must equal `v$VERSION`. Mismatch = instant failure, no upload.
- Changelog: `gh release create --generate-notes` anchors each tag with the
  commit history since the previous release; the TestFlight "What to test"
  note is seeded from the tag commit's subject line.

### Icon + launch screen

- App icon: single 1024×1024 universal master at
  `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (hand-authored
  art, committed binary). It is a plain square; iOS applies the superellipse
  mask itself (no alpha). `VersioningTests` guards the catalog shape (single
  1024 master, valid PNG).
- Launch screen: `INFOPLIST_KEY_UILaunchScreen_Generation = YES` (system
  default launch screen matching the app background) — no custom storyboard,
  so there is nothing to drift.

## Cutting a release (internal TestFlight group)

1. On `main` (must be green in CI):
   `echo 1.0.1 > VERSION && ruby Tools/gen_project.rb && git commit -am "chore: release 1.0.1"`
   — or open a PR bumping `VERSION`, merge when green.
   (The very first release used `v1.0.0`; the steps are identical for any bump.)
2. Tag and push: `git tag v1.0.1 && git push origin v1.0.1`.
3. Watch `Actions → Release (TestFlight)`:
   archive (iOS 26+ SDK, signed `com.infinityball.cookconsole`) → export
   (`method=app-store-connect`, `manageAppVersionAndBuildNumber=false`) →
   upload → ASC polling until the build is `VALID` → build attached to the
   **Internal** beta group with release notes → GitHub release created.
4. TestFlight: within minutes (usually <15) the build appears for internal
   testers; the run log prints the exact `BUILD_ID` (ASC evidence) and the
   release page links the tag.

`workflow_dispatch` exists for re-runs; it refuses any version that doesn't
match the `VERSION` file, so it can only redo the *current* release.

## Manual checks with the same JWT minter

```bash
export ASC_KEY_FILE=~/private/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=...
JWT=$(ruby Tools/asc_jwt.rb)
curl -sS -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds?limit=1" | jq '.data[0].id'
```

The minter is deliberately key-agnostic (any PKCS#8 EC key works) so it is
testable without production secrets — `Tests`-adjacent local testing uses a
throwaway `openssl ecparam` key.
