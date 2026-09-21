# Cook Console

**Cook Console is a local-first iPhone cooking companion: glance at the next step and live timers while folded, then unfold into a full cook mode with ingredient scaling and multi-timer control — no accounts, no cloud.**

## Overview

Cooking from a phone is awkward. The recipe app wants you scrolling through paragraphs while your hands are wet, timers live in a separate app and expire unnoticed, and scaling a recipe for two-into-four means mental math over the cutting board. Cook Console is designed around how people actually cook: a persistent, glanceable console surface that always shows *what's happening now* — the current step, the next step, and any running timers — while a fuller detail surface holds the complete recipe, notes, and substitutions.

The project is an **iPhone Duo dual-screen design target**: on the dual-screen device, one screen becomes the persistent cook console (big step text, timer tiles, start/stop/skip controls) while the other shows the full recipe, notes, and timer history. Until the iPhone Duo fold SDK matures, the app ships as a **standard iOS app with an optional tablet/adaptive size-class layout** — a regular-width two-column mode (console pane + detail pane) that is the documented migration target for native dual-screen APIs.

## Motivation

- Recipe apps are built for *reading*, not *cooking mid-flight*. The information you need at 60 seconds-to-empty-the-pan is buried behind scrolling.
- Timers are the #1 cooking interruption. Phone timers are single-purpose, easy to lose, and don't tie back to a recipe step.
- The iPhone Duo's second/unfolded screen is exactly the right shape for a "console + content" split: one screen you glance and poke with knuckles, one screen you read. But the fold SDK isn't available yet, so the value must be delivered today through adaptive layout.

## Target users

- Home cooks who follow recipes on their phone and juggle multiple timers.
- iPhone Duo early adopters who want a real dual-screen workflow, not a gimmick.
- Meal-preppers and batch cooks who scale recipes and need timers per item.
- Privacy-conscious users who don't want their food diary in someone's cloud.

## Concrete use cases

1. **Weeknight dinner, folded**: one hand scrolling the ingredient list; the console strip shows "Step 4 of 9 — Sauté onions" and a live "5:00" timer tile.
2. **Sunday batch cook, unfolded/regular width**: left pane is the timer wall (3 running timers, per-step labels), right pane is the full recipe with notes. Tap a timer tile to pause, extend, or mark done.
3. **Scaling**: toggle servings 2 → 6; every ingredient amount, cookware hint, and per-step timing note recomputes instantly.
4. **Walk-away step**: start the braise timer, lock the phone, the console surface keeps timers visible; a notification fires at zero with the step name ("Braise — reduce heat now").

## MVP feature list

- Local recipe library: create/import recipes (manual entry + plain-text import), edit steps, notes, tags.
- Servings-based ingredient scaling with sensible fraction rounding.
- Step-by-step cook mode: one step at a time, big readable text, advance/back with mis-touch tolerance.
- Per-step timers: named, started from the step, multiple concurrent, pause/extend, completion notifications.
- Console surface (the dual-screen design target): persistent "now/next step + timer wall" pane. Today it is the compact top strip on phones and the left pane in the regular-width adaptive layout; later it maps to the second screen.
- Local notes & history: per-cook session note, timer log, "make again" favorites.
- Export/backup: user-owned JSON + CSV export of recipes and history.
- VoiceOver labels, Dynamic Type, and large hit targets throughout.

### Non-goals (MVP)

- No accounts, cloud sync, or social features.
- No recipe scraping from websites or OCR of printed books.
- No grocery-list integration, meal planning calendar, or nutrition/health claims.
- No dependency on unavailable iPhone Duo fold APIs (dual-screen is a documented design target and migration path only).
- No Android build in MVP (iOS is the required primary platform).
- No AI recipe generation in MVP (a local, gracefully-degrading assistant is a post-MVP exploration).

## How to use — intended end-to-end workflow

1. Add a recipe (manual entry or plain-text import) or import a JSON backup.
2. Open the recipe → set servings → tap **Cook**.
3. Cook mode shows the current step large; the console pane shows next step + timer slots.
4. Tap **Start timer** on any timer-able step; run several at once.
5. When a timer fires, a notification names the step; unlock to dismiss/extend from the console.
6. Finish → keep or discard a session note; history and favorites update locally.

## Privacy, permissions, and data storage

- **Local-first**: all recipes, notes, timer history, and settings are stored on-device (SQLite). No accounts, no analytics, no ad SDKs, no background network use. The app performs no network requests in MVP.
- **Notifications** (optional): local timers only; denied or failed scheduling
  falls back to app-level on-screen alerts while Cook Console remains open.
- No camera, microphone, contacts, or location permissions. Photo attachment for finished-dish photos (optional) uses the photo picker with limited access and stores copies in app storage.
- **Data ownership**: the in-app **Your data** screen offers one-tap JSON backup export (versioned schema: recipes + cook sessions + timer logs, with export date and app version), CSV cook-history export, and validated JSON import. Imports land in the system share sheet / Files (no network is ever used); import validates schema and cross-references first and applies everything inside one transaction (a rejected file changes nothing), and merges by stable item IDs — existing recipes are kept or updated, never duplicated. The same screen states the on-device storage, zero-network, optional-permissions, and delete-app-deletes-everything semantics. The CI zero-network grep gate (`privacy-gate` job) keeps the no-network claim enforceable.

## iPhone Duo / build shape

- **Design target**: dual-screen spanned layout — console surface on the secondary display, detail on the primary, with continuity when folding/unfolding (session state and timer set survive the transition).
- **Build shape today**: standard SwiftUI iOS app with size-class-adaptive layouts. Compact width = single-column with pinned console strip; regular width (iPad/unfolded) = two-column console + detail. This is the exact layout the dual-screen migration will bind to the second display once Apple's fold APIs ship — no screen-management APIs are used now.
- **iOS SDK**: iOS 26 SDK or newer is required for builds and CI.
- **Bundle ID**: `com.infinityball.cookconsole` — registered in App Store Connect (result: `CREATED com.infinityball.cookconsole`). Signing/TestFlight releases use the App Store Connect API Actions secrets already configured on this repo (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` — names only, values never shown).

## Current status & milestones

- **Status:** M1/M2 plus the recipe library, editor, serving scaler, persisted
  step-by-step cook workflow, and concurrent per-step timers are implemented.
  Broader history UI, export, adaptive console work, and device verification
  remain future milestones.
- M1: Xcode project skeleton (iOS 26 SDK, SwiftUI), CI build, unit-test target. **Complete.**
- M2: Pure recipe domain, GRDB recipe store, servings scaling, and plain-text recipe parser with tests. **Complete for issue #2; history belongs to later session work.**
- M3: Cook mode + step timers + notifications. **Timer scope complete; broader history remains.**
- M4: Adaptive console/detail layout (regular-width two-column = Duo migration target).
- M5: Import/export/backup + privacy review.
- M6: Accessibility hardening + TestFlight release pipeline.

## Development quickstart

Planning shape (available once M1 lands):

```
# Requires Xcode on macOS with the current iOS 26+ SDK
xcodebuild -scheme CookConsole -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme CookConsole -destination 'platform=iOS Simulator,name=iPhone 17'
```

CI builds with the iOS 26-or-newer SDK and uploads TestFlight candidates via the App Store Connect API using the repo secrets above.

## License

MIT — see [LICENSE](LICENSE).
