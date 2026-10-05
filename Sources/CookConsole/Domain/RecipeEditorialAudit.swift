import Foundation

/// Issue #21: mechanical editorial audit for recipes.
///
/// The audit distinguishes THREE evidence levels and never conflates them:
/// 1. structural validation (Recipe/Ingredient invariants — already enforced),
/// 2. this editorial audit (deterministic text checks — CI-provable),
/// 3. physical kitchen testing (only recorded via the kitchen-test ledger;
///    no automated check here may EVER mark a recipe kitchen-tested).
enum RecipeEditorialAudit {
    struct Finding: Equatable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            /// Listed ingredient whose name never appears in any instruction.
            case ingredientAbsentFromInstructions
            /// Ingredient-like noun used in an instruction but missing from
            /// the ingredient list (and not an editorial exception).
            case instructionMentionsUnlistedIngredient
            /// A "preheat/heat oven" step that never states a temperature.
            case missingOvenTemperature
            /// Timer outside the plausible per-step band (5 s … 8 h).
            case timerOutOfRange
            /// Advisory: a timed step whose instruction has no doneness cue,
            /// i.e. elapsed time alone is asked to establish doneness.
            case timeOnlyDoneness
        }

        enum Severity: String, Codable, Sendable {
            case advisory
            case blocking
        }

        let kind: Kind
        let severity: Severity
        let message: String
        /// Zero-based step index when the finding is step-scoped.
        let stepIndex: Int?
    }

    /// Timers shorter than this are almost certainly typos (a step that
    /// genuinely needs <5 s is really part of the previous step).
    static let minimumPlausibleTimer: TimeInterval = 5
    /// Timers longer than this belong in a scheduler/note, not a cook-mode
    /// step timer (overnight proves, long brines).
    static let maximumPlausibleTimer: TimeInterval = 8 * 3600

    /// Words that, when present in a step, make an explicit oven
    /// temperature mandatory for that step.
    private static let ovenHeatWords: Set<String> = [
        "preheat", "heat", "set", "bring",
    ]

    /// Doneness vocabulary: sensory completion cues that a timer can
    /// accompany but never replace. Multi-word entries are matched against
    /// the raw instruction text; single words against its tokens.
    static let donenessCues: Set<String> = [
        "golden", "browned", "browning", "caramelized", "caramelised",
        "tender", "softened", "soft", "translucent", "frothy", "glossy",
        "thickened", "thick", "reduced", "bubbly", "bubbles", "bubbling",
        "simmering", "simmer", "simmered", "set", "firm",
        "crispy", "crisp", "crisp-tender", "crumbly", "opaque", "flaky",
        "springy", "juices", "aromatic", "fragrant",
        "pulling", "crackles", "sizzling", "steaming", "wilted",
        "melty", "melted", "puffed", "risen", "doubled", "shiny",
        "coat", "coats", "nappe", "ribbon", "clings", "peels",
        "bubbling vigorously",
    ]

    /// Doneness-connective phrases (checked on raw text, case-insensitive).
    static let donenessConnectives: [String] = [
        "until", "till ", "when the", "is golden", "are golden",
        "cooked through", "done", "no longer", "internal temperature",
        "instant-read", "thermometer", "toothpick", "knife", "jiggl",
        "spring back", "pulls away", "comes away",
    ]

    /// Run the full editorial audit. Findings are ordered deterministically:
    /// ingredient findings (list order), then step findings (step order).
    ///
    /// `editorialExceptions` are per-recipe reviewed allow-lists (lowercase
    /// phrases, each with a written justification in the ledger): a finding
    /// naming an excepted phrase is suppressed — this is the ONLY way a
    /// blocking finding disappears, and it must be justified, never silent.
    static func audit(recipe: Recipe, editorialExceptions: Set<String> = []) -> [Finding] {
        var findings: [Finding] = []

        let stepWords = recipe.steps.map { RecipeTextMatching.words(in: $0.instruction) }
        let stepBigrams = stepWords.map { RecipeTextMatching.bigrams(in: $0) }
        let recipeMatchSet = Set(stepWords.flatMap { $0 } + stepBigrams.flatMap { $0 })

        auditIngredients(
            recipe: recipe,
            matchSet: recipeMatchSet,
            editorialExceptions: editorialExceptions,
            into: &findings
        )
        auditUnlistedIngredients(
            recipe: recipe,
            stepWords: stepWords,
            stepBigrams: stepBigrams,
            editorialExceptions: editorialExceptions,
            into: &findings
        )
        auditSteps(recipe: recipe, stepWords: stepWords, into: &findings)
        return findings
    }

    /// A recipe passes the editorial gate when no blocking findings remain.
    static func isEditoriallyClean(recipe: Recipe, editorialExceptions: Set<String> = []) -> Bool {
        !audit(recipe: recipe, editorialExceptions: editorialExceptions)
            .contains { $0.severity == .blocking }
    }

    /// True when an instruction text already contains a doneness cue.
    static func hasDonenessCue(_ instruction: String) -> Bool {
        let lowered = instruction.lowercased()
        if donenessConnectives.contains(where: { lowered.contains($0) }) { return true }
        let words = Set(RecipeTextMatching.words(in: instruction))
        return !words.isDisjoint(with: donenessCues)
    }

    // MARK: - Ingredient ↔ instruction cross-check

    private static func auditIngredients(
        recipe: Recipe,
        matchSet: Set<String>,
        editorialExceptions: Set<String>,
        into findings: inout [Finding]
    ) {
        for ingredient in recipe.ingredients where !isExemptIngredientName(ingredient.name) {
            if !RecipeTextMatching.isMentioned(ingredientName: ingredient.name, matchSet: matchSet) {
                let phrase = ingredient.name.lowercased()
                guard !editorialExceptions.contains(phrase) else { continue }
                findings.append(Finding(
                    kind: .ingredientAbsentFromInstructions,
                    severity: .blocking,
                    message: "Ingredient '\(ingredient.name)' never appears in any instruction.",
                    stepIndex: nil
                ))
            }
        }
    }

    private static func auditUnlistedIngredients(
        recipe: Recipe,
        stepWords: [[String]],
        stepBigrams: [[String]],
        editorialExceptions: Set<String>,
        into findings: inout [Finding]
    ) {
        var ingredientVocabulary = RecipeTextMatching.editorialExceptions
        for ingredient in recipe.ingredients {
            ingredientVocabulary.formUnion(RecipeTextMatching.vocabulary(forIngredientName: ingredient.name))
            // Bigram-capable names (e.g. "olive oil") are also matched via
            // their component words already inside the vocabulary set.
        }

        var flaggedPhrases: Set<String> = []
        var flaggedWords: Set<String> = []

        for (stepIndex, bigrams) in stepBigrams.enumerated() {
            for bigram in bigrams where isGlossaryPhrase(bigram) && !ingredientVocabulary.contains(bigram) {
                if flaggedPhrases.contains(bigram) || editorialExceptions.contains(bigram) { continue }
                flaggedPhrases.insert(bigram)
                findings.append(Finding(
                    kind: .instructionMentionsUnlistedIngredient,
                    severity: .blocking,
                    message: "Step \(stepIndex + 1) mentions '\(bigram)' which is not in the ingredient list.",
                    stepIndex: stepIndex
                ))
            }
        }
        // A flagged multi-word phrase already explains its component words.
        for phrase in flaggedPhrases {
            flaggedWords.formUnion(phrase.split(separator: " ").map(String.init))
        }

        for (stepIndex, words) in stepWords.enumerated() {
            for word in Set(words) where isGlossarySingleWord(word)
                && !ingredientVocabulary.contains(word)
                && !flaggedWords.contains(word)
                && !editorialExceptions.contains(word)
            {
                flaggedWords.insert(word)
                findings.append(Finding(
                    kind: .instructionMentionsUnlistedIngredient,
                    severity: .blocking,
                    message: "Step \(stepIndex + 1) mentions '\(word)' which is not in the ingredient list.",
                    stepIndex: stepIndex
                ))
            }
        }
    }

    // MARK: - Step checks

    private static func auditSteps(
        recipe: Recipe,
        stepWords: [[String]],
        into findings: inout [Finding]
    ) {
        for (stepIndex, step) in recipe.steps.enumerated() {
            auditOvenTemperature(
                instruction: step.instruction,
                words: Set(stepWords[stepIndex]),
                stepIndex: stepIndex,
                into: &findings
            )
            guard let timer = step.timerDuration else { continue }
            if timer < minimumPlausibleTimer || timer > maximumPlausibleTimer {
                findings.append(Finding(
                    kind: .timerOutOfRange,
                    severity: .blocking,
                    message: "Step \(stepIndex + 1) timer of \(Int(timer)) s is outside the plausible \(Int(minimumPlausibleTimer))–\(Int(maximumPlausibleTimer)) s band.",
                    stepIndex: stepIndex
                ))
            }
            if !hasDonenessCue(step.instruction) {
                findings.append(Finding(
                    kind: .timeOnlyDoneness,
                    severity: .advisory,
                    message: "Step \(stepIndex + 1) relies on elapsed time alone; add a doneness cue — a timer alone never establishes doneness.",
                    stepIndex: stepIndex
                ))
            }
        }
    }

    private static func auditOvenTemperature(
        instruction: String,
        words: Set<String>,
        stepIndex: Int,
        into findings: inout [Finding]
    ) {
        guard words.contains("oven") else { return }
        let heatsOven = words.contains("preheat")
            || (words.contains("oven") && !ovenHeatWords.isDisjoint(with: words))
        guard heatsOven else { return }
        let lowered = instruction.lowercased()
        let hasTemperature = lowered.contains("°c") || lowered.contains("°f")
            || lowered.contains("celsius") || lowered.contains("fahrenheit")
        if !hasTemperature {
            findings.append(Finding(
                kind: .missingOvenTemperature,
                severity: .blocking,
                message: "Step \(stepIndex + 1) heats the oven but never states a temperature.",
                stepIndex: stepIndex
            ))
        }
    }

    // MARK: - Glossary / exception helpers

    /// Precomputed: every naive form of every multi-word glossary entry
    /// (component-word plurals are NOT exploded to keep the phrase exact).
    private static let glossaryPhrases: Set<String> = {
        var phrases: Set<String> = []
        for entry in RecipeTextMatching.ingredientLikeNouns where entry.contains(" ") {
            phrases.insert(entry)
            let parts = entry.split(separator: " ").map(String.init)
            if let last = parts.last {
                for form in RecipeTextMatching.naiveForms(of: last) where form != last {
                    var variant = parts.dropLast()
                    variant.append(form)
                    phrases.insert(variant.joined(separator: " "))
                }
            }
            phrases.insert(entry + "s")
        }
        return phrases
    }()

    /// Precomputed: every naive form of every single-word glossary entry.
    private static let glossaryWords: Set<String> = {
        var words: Set<String> = []
        for entry in RecipeTextMatching.ingredientLikeNouns where !entry.contains(" ") {
            words.formUnion(RecipeTextMatching.naiveForms(of: entry))
        }
        return words
    }()

    static func isGlossaryPhrase(_ text: String) -> Bool {
        glossaryPhrases.contains(text)
    }

    static func isGlossarySingleWord(_ text: String) -> Bool {
        glossaryWords.contains(text)
    }

    /// Editorially exempt ingredients (salt/pepper/water/ice): assumed on
    /// hand, frequently "to taste", and never required to appear verbatim
    /// in either direction.
    static func isExemptIngredientName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if RecipeTextMatching.editorialExceptions.contains(lowered) { return true }
        let parts = lowered
            .split(whereSeparator: { ",/()".contains($0) || $0 == " " })
            .map(String.init)
        return parts.contains { RecipeTextMatching.editorialExceptions.contains($0) }
    }
}
