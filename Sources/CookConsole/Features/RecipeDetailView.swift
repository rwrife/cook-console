import SwiftUI

struct RecipeDetailView: View {
    @EnvironmentObject private var store: AppStore
    let recipeID: UUID

    @State private var recipe: Recipe?
    @State private var targetServings: Double = 1
    @State private var showingEdit = false
    @State private var showingCook = false

    var body: some View {
        Group {
            if let recipe {
                List {
                    Section {
                        HStack {
                            Button {
                                changeServings(by: -0.5)
                            } label: {
                                Image(systemName: "minus")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Decrease servings by half")
                            .disabled(targetServings <= 0.5)

                            Spacer()
                            VStack {
                                Text(RecipeAmountFormatter.string(targetServings))
                                    .font(.title2.bold())
                                    .accessibilityLabel("Servings")
                                    .accessibilityValue(RecipeAmountFormatter.string(targetServings))
                                Text("servings")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            Spacer()

                            Button {
                                changeServings(by: 0.5)
                            } label: {
                                Image(systemName: "plus")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Increase servings by half")
                        }
                        Text("Original recipe: \(RecipeAmountFormatter.string(recipe.servings)) servings")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button("Reset to Original") { targetServings = recipe.servings }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Reset servings")
                            .disabled(isOriginalYield(recipe))
                    } header: {
                        Text("Scale")
                    }

                    Section("Ingredients") {
                        ForEach(scaledIngredients(for: recipe)) { ingredient in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(RecipeAmountFormatter.ingredient(ingredient))
                                if ingredient.wasRoundedForDisplay {
                                    Text(
                                        "Calculated: \(RecipeAmountFormatter.exactIngredient(ingredient)). "
                                        + "Shown as a practical kitchen measure."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("Rounding disclosure \(ingredient.name)")
                                }
                                if let guidance = ingredient.actionableGuidance {
                                    Label(guidance, systemImage: "lightbulb")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("Ingredient guidance \(ingredient.name)")
                                }
                            }
                        }
                        if !isOriginalYield(recipe) {
                            Text("Ingredient amounts are calculated from the original recipe every time. Practical display rounding never changes the saved quantities, and positive amounts never display as zero.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("Scaling rounding disclosure")
                        }
                    }

                    let guidance = ScalingLimitsGuidance.guidance(
                        for: recipe,
                        targetServings: targetServings
                    )
                    if guidance.hasGuidance {
                        Section("Scaling Notes") {
                            if let pan = guidance.panSizeGuidance {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "frying.pan")
                                        .accessibilityHidden(true)
                                    Text(pan)
                                        .font(.subheadline)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("Pan size guidance")
                            }
                            if let batch = guidance.batchGuidance {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "square.stack.3d.up")
                                        .accessibilityHidden(true)
                                    Text(batch)
                                        .font(.subheadline)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("Batch size guidance")
                            }
                            if let time = guidance.cookingTimeGuidance {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .accessibilityHidden(true)
                                    Text(time)
                                        .font(.subheadline)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("Cooking time guidance")
                            }
                        }
                    }

                    Section("Steps") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Step \(index + 1)")
                                    .font(.headline)
                                Text(step.instruction)
                                if let duration = step.timerDuration {
                                    Label(RecipeAmountFormatter.duration(duration), systemImage: "timer")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !recipe.tags.isEmpty {
                        Section("Tags") {
                            ForEach(recipe.tags, id: \.self) { Text($0) }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        // Flag the alert-routing surface at the exact moment
                        // the cover is requested, before CookModeView's own
                        // onAppear can run, so a completion that arrives
                        // mid-presentation is claimed by the cover's alert.
                        store.isCookSurfaceActive = true
                        showingCook = true
                    } label: {
                        Label("Cook", systemImage: "play.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    .background(.bar)
                }
                .navigationTitle(recipe.title)
                .toolbar {
                    Button("Edit") { showingEdit = true }
                }
                .sheet(isPresented: $showingEdit, onDismiss: load) {
                    NavigationStack { RecipeEditorView(recipe: recipe) }
                }
                .fullScreenCover(isPresented: $showingCook, onDismiss: load) {
                    CookModeView(recipe: recipe)
                }
            } else {
                ContentUnavailableView("Recipe Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let loaded = store.recipe(id: recipeID) else { return }
        let shouldResetScale = recipe == nil || recipe?.servings != loaded.servings
        recipe = loaded
        if shouldResetScale { targetServings = loaded.servings }
    }

    private func changeServings(by amount: Double) {
        targetServings = max(0.5, targetServings + amount)
    }

    private func isOriginalYield(_ recipe: Recipe) -> Bool {
        abs(targetServings - recipe.servings) < 0.000_001
    }

    private func scaledIngredients(for recipe: Recipe) -> [ScaledIngredient] {
        do {
            return try ScalingEngine.scaledIngredients(
                for: recipe,
                targetServings: targetServings
            )
        } catch {
            store.present(error)
            return recipe.ingredients.compactMap { try? ScalingEngine.scaled($0, ratio: 1) }
        }
    }
}

enum RecipeAmountFormatter {
    static func string(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    static func ingredient(_ ingredient: ScaledIngredient) -> String {
        "\(KitchenQuantityFormatter.string(ingredient.displayAmount)) \(ingredient.unit.symbol) \(ingredient.name)"
    }

    static func exactIngredient(_ ingredient: ScaledIngredient) -> String {
        "\(string(ingredient.exactAmount)) \(ingredient.unit.symbol)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        return "\(string(minutes)) min"
    }
}
