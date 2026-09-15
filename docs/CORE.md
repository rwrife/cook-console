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
