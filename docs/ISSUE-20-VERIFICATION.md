# Issue #20 — Combined grocery list

## Behavior

- The library footer's **Grocery** button opens the grocery sheet (persistent
  bottom inset, same placement lesson as the pantry entry — toolbar items
  disappear under an active search field).
- Recipes join via a toggle picker (re-tapping removes; a recipe contributes
  exactly once). Per-selection servings steppers scale only that selection's
  contributions from the recipe's ORIGINAL amounts via `ScalingEngine`, so
  shopping demand never accumulates rounding.
- Merging is conservative and unit-aware:
  - Equivalent names merge through the same strict alias table the pantry
    engine uses (preparation words like "fresh"/"dried" never collapse).
  - Same-family units convert at shopping granularity only (kg→g, oz→lb at
    ≥16 oz, tbsp→cup at ≥¼ cup, mL→L at ≥0.1 L); small doses keep their
    own bucket so "2 tbsp" never becomes "0.13 cup".
  - Incompatible families (volume vs mass vs count) always stay separate
    lines. A few weight-countable items (cheese, produce) fold `each` into
    grams at ~30 g each; indivisible counts (eggs) never convert.
  - "to taste" items never sum: they merge into one no-quantity line.
- Provenance ("For: Recipe × servings") is kept per line and included in the
  shared text. Optional/to-taste qualifiers survive merges.
- Check state is stored per (selection, ingredient key). A merged line shows
  checked iff EVERY contributing selection has bought its share; checking a
  line fans the flag out to exactly the contributing selections. Removing a
  selection or editing a recipe re-derives everything predictably — no
  silently lost checks.
- Manual items support free-text smart parsing ("2 tbsp soy sauce", "salt to
  taste"), lead the list, own their persisted check flag. "Done Shopping"
  clears bought manual items and all check flags while selections survive.
- Export writes a plain-text shopping list (amounts, qualifiers, checkboxes,
  provenance) and offers it through the system share sheet. All local — the
  zero-network gate stays green.

## Storage

Migration `v9_create_grocery_list` adds `grocery_selections` (FK →
recipes, CASCADE), `grocery_selection_checks` (composite PK
selection_id + ingredient_key, CASCADE), and `grocery_manual_items`, with
position indexes for stable ordering.

JSON backup (schema 1, optional additive fields): grocery selections export
`checkedKeys: [String]`; manual items export their flag. Pre-grocery files
decode unchanged (import reports zero grocery additions); re-import is
idempotent via stable-ID skip; a selection referencing a recipe missing from
the file fails validation before any write.

## Verification

- Linux Swift 6.1 + SQLite: `swift build` clean and `swift test` —
  150/150 XCTest + 6/6 swift-testing pass, including 17 new
  `GroceryAggregationTests` (deduplication, unit conversion at shopping
  granularity, fractional amounts, provenance, taste-dose separation,
  check stability across edits/serving changes, fan-out targeting) and 8
  new `GroceryRepositoryTests` (offline persistence, CASCADE behavior,
  bounds/blankness rejection, backup export→import round-trip incl. legacy
  files).
- Native CI must prove the iOS app build and the new
  `GroceryListUITests` journey (pick two fixture recipes, merged
  amounts/provenance, stepper recompute, manual add, merged-line check,
  export/share affordance). Linux checks do not establish iOS runtime
  behavior.
