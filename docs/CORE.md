# Recipe Core

## Domain validation

`Recipe`, `Ingredient`, `RecipeStep`, and `IngredientUnit` live under
`Sources/CookConsole/Domain`. They import only Foundation. UUIDs are accepted
by every entity initializer and remain unchanged through scaling and storage.

- Titles, ingredient names, and step instructions are trimmed and nonempty.
- Servings and ingredient amounts are finite and greater than zero.
- Optional timer durations are expressed in seconds and, when present, are
  finite and greater than zero.
- Tags are trimmed, blank tags are removed, and duplicates are removed
  case-insensitively while preserving first-seen order and spelling.

## SQLite schema and migrations

GRDB applies these migrations in order:

1. `v1_create_recipe_core` creates `recipes`, ordered `ingredients`, ordered
   `recipe_steps`, and ordered `recipe_tags`. Child rows reference recipes with
   `ON DELETE CASCADE`; indexes support child loading and tag queries. SQL
   constraints mirror domain scalar validation.
2. `v2_add_recipe_favorite` adds the non-null `is_favorite` column with a
   default of false and a Boolean-only `0`/`1` check.
3. `v3_create_cook_sessions` stores active, completed, and abandoned local cook
   sessions, including the current zero-based step and start/end timestamps.
4. `v4_create_step_timers` stores each timer's recipe, step, and cook-session
   identity, wall-clock deadline or paused remainder, terminal state, and local
   started/fired/extended event log.
5. `v5_timer_invariants_and_completion_queue` enforces valid running, paused,
   and terminal row shapes, validates timer ownership, permits restarted timers
   to fire again, and persists completion alerts until explicit acknowledgment.
6. `v6_timer_schedule_generation` persists a per-timer notification-schedule
   generation used to reject obsolete notification deliveries.

Text checks use SQLite's built-in two-argument `trim` with the explicit Unicode
characters in Foundation's `whitespacesAndNewlines`, so every database
connection enforces the same nonblank rule without connection-local functions.

Repository create and update operations use GRDB writer transactions. An
error in any child write rolls back the parent and all earlier child writes.
Update replaces ordered child collections in the same transaction. Delete
cascades through SQLite foreign keys. `RecipeDatabase.make(at:)` migrates a
file-backed database; `makeInMemory()` uses a real in-memory SQLite database
for tests.

## Servings scaling and rounding

The raw amount is `ingredient amount × target servings / recipe servings`.
Inputs and results must be finite and greater than zero. Values are snapped to
the nearest increment below, with a minimum of one increment so a positive
ingredient never rounds to zero:

| Unit | Amount range | Increment |
|---|---:|---:|
| tsp, tbsp, cup | below 1 / 1–4 / above 4 | 1/8 / 1/4 / 1/2 |
| g, mL | below 1 / 1–10 / 10–100 / 100+ | 0.1 / 0.5 / 1 / 5 |
| kg, L | below 1 / 1+ | 0.05 / 0.1 |
| each | all | 0.5 |
| oz | all | 0.25 |
| lb | all | 0.125 |

Snapped results are normalized to nine decimal places to avoid exposing
binary floating-point noise in otherwise simple fractions.

## Plain-text import grammar

Blank lines are ignored, but error line numbers refer to the original input.
The grammar is:

```text
Title: Weeknight Pancakes
Servings: 4
Tags: breakfast, quick

Ingredients:
- 1 1/2 cups flour
- 2 each eggs
- 0.5 tsp salt
Steps:
1. Whisk the ingredients.
2. Cook on a hot griddle.
```

`Tags:` is optional. Amounts accept unsigned positive finite decimals (`0.5`),
slash fractions with positive integer numerators and denominators (`3/4`), and
mixed fractions with a nonnegative integer whole and proper fractional suffix
(`1 1/2`). Signs, nonfinite values, and malformed numeric tokens are rejected.
Supported unit spellings are
`each`/`ea`, teaspoon/tsp, tablespoon/tbsp, cup, mL/milliliter, L/liter,
g/gram, kg/kilogram, oz/ounce, and lb/pound, including documented plurals.
Steps must start at 1, be sequential, and use `1.` or `1)` notation. Every
parse failure is a `RecipeImportError` with the original line number and a
specific reason.

Imports are rejected before full parsing when they exceed 1,048,576 UTF-8
bytes or 10,000 logical lines. Parsing also stops before accepting more than
1,000 ingredients or 1,000 steps. CRLF counts as one logical newline.

## Local verification evidence

Development used behavior-first red/green cycles in the Swift 6.1 SQLite
container. The observed red failures and subsequent green results were:

| Cycle | Red evidence | Green evidence |
|---|---|---|
| Domain | missing `Ingredient`, `RecipeStep`, and `Recipe` symbols | 5 tests passed |
| Scaling | missing `ScalingEngine`; later metric result exposed `0.8500000000000001` | 7 tests passed |
| Parser | missing parser and error symbols | 8 tests passed |
| Repository | missing database/repository symbols | 7 tests passed |
| SQL validation | invalid rows were initially accepted (2 assertion failures) | repository suite: 8 tests passed |

Each focused cycle used `swift test --filter <suite>` in
`wine-vault-swift-sqlite:6.1`, running as the host UID/GID with a writable,
temporary container home. Final verification uses the unfiltered command in
`docs/BUILD.md`. iOS builds and iPhone 17 simulator tests require macOS/Xcode
26 and remain the canonical CI evidence; Linux results are not iOS results.

## Recipe library and cook workflow

The library query groups favorites first, then orders each group by the most
recent completed cook and finally title. Title search trims the query and is
case-insensitive; tag filtering matches a complete normalized tag
case-insensitively. Both filters compose without changing the library order.

Opening cook mode creates an active session before showing a step. Re-entry
resumes that active row and its persisted position. Next/back movement is
bounded to one step. Leaving through **Full recipe** deliberately leaves the
session active; **Complete** and **Abandon Cook** store terminal outcomes and
end timestamps locally. Only completed outcomes affect recently-cooked order.

The recipe detail passes its target-serving ratio to `ScalingEngine` on every
render. Controls change the target in 0.5-serving increments, clamp at 0.5,
and reset to the recipe's stored servings.

## Concurrent step timers

Every timer is tied to a recipe, recipe step, and cook session. Running timers
persist an absolute wall-clock deadline rather than a decrementing counter;
paused timers persist their remaining duration. `TimerEngine` accepts an
injected clock, and launch/foreground reconciliation completes deadlines that
passed while the process was suspended or the device rebooted. Each timer is
independent and supports start, pause, resume, extend, cancel, and completion.
The timer row snapshots its original step UUID and display text when it starts.
Editing or removing that recipe step later does not rewrite an active timer:
the timer deliberately retains that historical identity and text for its
remaining lifetime and event history.

Starting, firing, and every extension are stored in `timer_events`. Completion
reconciliation is safe to repeat and cannot create a second fired event.
Expiry deliberately keeps the pending request alive: polling can reach a
deadline before the OS delivers, and removing a still-pending request would
destroy its only actionable +2/+5 presentation. Cancellation, explicit
acknowledgment, and restart remove pending and delivered notifications.
Resuming or extending a running timer replaces its request at the new
deadline. Extending at or after expiry first records the completion, then
restarts the timer for the full extension measured from the action time. Each
timer row persists a `schedule_generation` counter that every state-changing
transition bumps; a scheduled notification payload captures that generation and
a foreground delivery completes its timer only when the payload generation
still equals the stored row's and the deadline has passed. Two distinct
schedules can therefore share a near-identical deadline (pause-then-resume
inside one second) without an obsolete delivery ever completing the current
schedule.

Cook mode offers one-tap start on timer-enabled steps and a timer wall with
pause/resume, +2 minutes, +5 minutes, and cancel controls. When notification
permission is denied or notification scheduling fails, timers remain fully
functional and the app explains the on-screen fallback. Expiry handling is a
single deadline wake-up owned by the app store — one Task that sleeps until the
earliest running deadline, cancels and reschedules whenever timers change, and
reconciles on wake — rather than a permanent once-per-second root publisher,
which kept the view tree non-idle and disrupted presentation animations during
simulator UI runs. A failed reconciliation or deadline lookup re-arms a short
bounded retry (up to five attempts) so a transient database error cannot
permanently strand the wake-up chain.

Local notification content names the step and registers +2/+5-minute actions.
An action received after process termination, or while an expired timer is
still stored as running, reconciles expiry and restarts from the action time.
Completing or abandoning a cook transactionally cancels all active timers in
that session, so no live timer becomes invisible. Notification delivery
remains subject to normal iOS scheduling policy; there is no claim of exact
background execution.
