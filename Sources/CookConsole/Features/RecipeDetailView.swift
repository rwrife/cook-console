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
                                Text("servings")
                                    .foregroundStyle(.secondary)
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
                        Button("Reset") { targetServings = recipe.servings }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Reset servings")
                    } header: {
                        Text("Scale")
                    }

                    Section("Ingredients") {
                        ForEach(scaledIngredients(for: recipe)) { ingredient in
                            Text(RecipeAmountFormatter.ingredient(ingredient))
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

    private func scaledIngredients(for recipe: Recipe) -> [Ingredient] {
        do {
            return try ScalingEngine.scaledIngredients(
                for: recipe,
                targetServings: targetServings
            )
        } catch {
            store.present(error)
            return recipe.ingredients
        }
    }
}

enum RecipeAmountFormatter {
    static func string(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    static func ingredient(_ ingredient: Ingredient) -> String {
        "\(string(ingredient.amount)) \(ingredient.unit.symbol) \(ingredient.name)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        return "\(string(minutes)) min"
    }
}
