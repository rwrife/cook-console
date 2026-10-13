# Recipe discovery (#27)

Search titles offline in Recipes. Open **Discovery Filters** for quick collections, ingredient-name search, meal type, and dietary tag. Filters combine with title search and tag menu. Active labels, result count, and clear-all appear above matches; empty results show zero matches and a clear-filters action.

- **30 minutes or less:** only recipes with an explicit total-minutes value of 1–30. Duration is editable in recipe editor and stored locally; missing value stays unknown, never treated as zero. Existing recipes and earlier JSON backups retain unknown duration until edited. Step timer lengths and free-form cooking guidance do not imply total time.
- **Five ingredients or fewer:** count every ingredient row in recipe, including salt, water, and repeated names; one row counts once regardless of amount or unit. Six rows do not match, even when names repeat. Minimum one row required by recipe validation.
- **Ingredient filter:** case-insensitive substring of ingredient names; not pantry availability.
- **Meal type:** exact case-insensitive match against recipe's user-authored `breakfast`, `lunch`, `dinner`, or `snack` tag. Untagged recipes are excluded when active. Edit comma-separated tags in editor; no automatic meal inference.
- **Dietary preference:** exact case-insensitive match against recipe's user-authored `vegetarian`, `vegan`, `gluten-free`, or `dairy-free` tag. This is a **label filter**, not allergen analysis or certification. No tag means unknown, never a dietary claim. Check ingredients and packaging yourself.

All data remains on device. JSON export/import carries optional `totalMinutes`; imports of older files without it leave duration unknown. Edits and imports refresh library filters from current GRDB state. No network or account required.
