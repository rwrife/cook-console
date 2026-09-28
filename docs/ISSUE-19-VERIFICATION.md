# Issue #19 — Practical serving adjustments

## Behavior

- Every serving change recalculates from the recipe’s original ingredient amounts. Exact results remain separate from kitchen-friendly display recommendations, preventing accumulated rounding.
- Display increments vary by unit and magnitude. Positive amounts have a nonzero display floor.
- Fractional `each` quantities disclose practical handling. Eggs recommend beating whole eggs and measuring a fraction of the mixture; other countable ingredients explain whole-item choices.
- Reset restores the recipe’s original yield and amounts.
- The recipe editor supports optional pan-size, batch-size, and cooking-time guidance. These notes persist locally and are included in JSON backup/export as additive optional fields.
- When author guidance is absent, scaling provides conservative baking or general-cooking guidance for substantial increases/decreases. Cooking time is never multiplied by the servings ratio.

## Storage

Migration `v8_add_scaling_guidance` adds nullable guidance columns to `recipes`. Existing recipes migrate with nil guidance. Blank editor values normalize to nil.

## Verification

- Linux Swift 6.1 + SQLite: `swift test -Xswiftc -warnings-as-errors`.
- Unit coverage includes small/large multipliers, exact-vs-display amounts, fractional eggs and other countable ingredients, incompatible units, nonzero tiny displays, reset-safe repeated scaling, baking/general guidance, recipe-specific overrides, and database migration/persistence.
- Native CI must prove the iOS app build and UI journey. Linux checks do not establish iOS runtime behavior.
