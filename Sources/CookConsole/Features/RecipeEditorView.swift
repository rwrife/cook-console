import SwiftUI
import UIKit

struct RecipeEditorView: View {
    private enum EditorField: Hashable {
        case title
        case servings
        case ingredientName(UUID)
        case ingredientAmount(UUID)
        case stepInstruction(UUID)
        case stepTimer(UUID)
        case tags
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecipeDraft
    @State private var validationMessage: String?
    @FocusState private var focusedField: EditorField?

    private let isNew: Bool

    init(recipe: Recipe?) {
        isNew = recipe == nil
        _draft = State(initialValue: RecipeDraft(recipe: recipe))
    }

    var body: some View {
        Form {
            Section("Recipe") {
                TextField("Title", text: $draft.title)
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("Recipe title")
                    .accessibilityIdentifier("Recipe title")
                TextField("Servings", text: $draft.servings)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .servings)
                    .accessibilityIdentifier("Servings")
                Toggle("Favorite", isOn: $draft.isFavorite)
            }

            Section("Ingredients") {
                ForEach($draft.ingredients) { $ingredient in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Ingredient name", text: $ingredient.name)
                            .focused($focusedField, equals: .ingredientName(ingredient.id))
                            .accessibilityIdentifier("Ingredient name \(ingredient.position)")
                        HStack {
                            TextField("Amount", text: $ingredient.amount)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .ingredientAmount(ingredient.id))
                                .accessibilityIdentifier("Ingredient amount \(ingredient.position)")
                            Picker("Unit", selection: $ingredient.unit) {
                                ForEach(IngredientUnit.allCases, id: \.self) { unit in
                                    Text(unit.symbol).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("Ingredient unit \(ingredient.position)")
                        }
                        Button("Remove Ingredient", role: .destructive) {
                            draft.removeIngredient(id: ingredient.id)
                        }
                        .disabled(draft.ingredients.count == 1)
                    }
                }
                Button("Add Ingredient", systemImage: "plus") {
                    draft.addIngredient()
                }
            }

            Section("Steps") {
                ForEach($draft.steps) { $step in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Step \(step.position)")
                            .font(.headline)
                        TextEditor(text: $step.instruction)
                            .frame(minHeight: 90)
                            .focused($focusedField, equals: .stepInstruction(step.id))
                            .accessibilityIdentifier("Step \(step.position)")
                        TextField("Timer minutes (optional)", text: $step.timerMinutes)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .stepTimer(step.id))
                            .accessibilityIdentifier("Step timer \(step.position)")
                        Button("Remove Step", role: .destructive) {
                            draft.removeStep(id: step.id)
                        }
                        .disabled(draft.steps.count == 1)
                    }
                }
                Button("Add Step", systemImage: "plus") {
                    draft.addStep()
                }
            }

            Section("Tags") {
                TextField("Comma-separated tags", text: $draft.tags)
                    .focused($focusedField, equals: .tags)
                    .accessibilityLabel("Tags")
                    .accessibilityIdentifier("Tags")
            }
        }
        .accessibilityIdentifier("Recipe editor form")
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(isNew ? "New Recipe" : "Edit Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Recipe") { save() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissKeyboard()
                }
                .accessibilityIdentifier("Done Editing")
            }
        }
        .alert("Unable to Save", isPresented: validationBinding) {
            Button("OK") { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var validationBinding: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }

    private func dismissKeyboard() {
        focusedField = nil

        let activeWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        _ = activeWindow?.endEditing(true)
    }

    private func save() {
        do {
            try store.save(draft.makeRecipe(), isNew: isNew)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
