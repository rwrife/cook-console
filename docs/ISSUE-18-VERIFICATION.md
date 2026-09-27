# Issue #18 — Pantry recipe suggestions

## User flow

1. Open **What Can I Make?** from the persistent recipe-browser footer.
2. Add or remove ingredients on hand. Entries are stored in the local SQLite database.
3. Review ranked recipe suggestions. **Ready** means every ingredient name matched either an on-hand item or a configured staple; partial matches list missing ingredients before navigation.
4. Open **Assumed Pantry Staples** to inspect, add, or remove assumptions. Defaults are seeded once and remain removed when configured.
5. Open a suggestion to view its current recipe detail.

## Matching contract

Matching is conservative and name-based:

- Comparison is case-insensitive and trims surrounding whitespace/punctuation.
- A small explicit alias table covers equivalent common names, including chickpeas/garbanzo beans and scallions/green onions.
- Preparation or form words are retained. For example, `dried basil` does not match `fresh basil`.
- No ingredient is silently treated as a substitution for another.
- Name coverage does not track quantity. The UI always states: “Name matches do not confirm that you have enough quantity. Check amounts before cooking.”

## Offline and privacy contract

The feature uses only the existing on-device GRDB/SQLite store and in-process matching. It adds no account, cloud, network, analytics, or fold-SDK dependency. The repository’s zero-network CI gate covers the new source and tests.

## Verification

- Linux domain/data suite: `swift test -Xswiftc -warnings-as-errors` in the pinned Swift 6.1 + SQLite container.
- Native CI: generic iOS simulator build; iPhone 17 unit/UI suite; iPad split-layout test; iPhone 17 Pro Max rotation rehearsal; zero-network gate.
- Pantry tests cover aliases and non-equivalent forms, empty pantry plus visible staples, complete-vs-partial ranking, persistence/removal after database reopen, one-time staple defaults, edited recipe ingredients, and the quantity disclaimer.
- UI test covers entry, pantry editing, default-staple coverage, alias matching, missing-ingredient disclosure, and opening a suggested recipe.

Native results and simulator behavior must be cited from the pull request’s GitHub Actions run; Linux checks do not establish iOS runtime behavior.
