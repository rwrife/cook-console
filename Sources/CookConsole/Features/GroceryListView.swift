import SwiftUI
import UIKit

/// Issue #20: the combined grocery list. Select recipes and per-selection
/// servings, shop one merged sheet. Everything is local (GRDB) — no account,
/// no cloud. The view renders `store.grocerySnapshot`, which the pure
/// `GroceryAggregationEngine` recomputes after every mutation, so merging,
/// provenance, optional/to-taste qualifiers, and derived check state can
/// never drift between the list and the selections.
struct GroceryListView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var entryFocused: Bool
    @State private var newItemText = ""
    @State private var showRecipePicker = false
    @State private var groceryExportURL: URL?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grocery List")
                        .font(.headline)
                    Text(store.grocerySnapshot.totalCount == 0
                        ? "Add recipes or type an item to build one shopping list for everything you plan to cook."
                        : "\(store.grocerySnapshot.uncheckedCount) to buy, \(store.grocerySnapshot.checkedCount) checked off. Merged amounts are shopping estimates; check quantities before cooking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Grocery summary")
                }
                .padding(.vertical, 2)
            }

            Section("Recipes on the List") {
                if store.grocerySelections.isEmpty {
                    Text("No recipes selected yet. Use Add Recipe below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.grocerySelections) { selection in
                        selectionRow(selection)
                    }
                }
                Button("Add Recipe") {
                    showRecipePicker = true
                }
                .accessibilityIdentifier("Add grocery recipe")
            }

            Section("Manual Items") {
                HStack {
                    TextField("Add item (e.g. Paper towels)", text: $newItemText)
                        .focused($entryFocused)
                        .accessibilityIdentifier("Grocery entry field")
                        .onSubmit(addManualItem)
                    Button("Add") {
                        addManualItem()
                    }
                    .disabled(newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Add grocery item")
                }
                if store.groceryManualItems.isEmpty {
                    Text("Nothing typed in yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.groceryManualItems) { item in
                        HStack(spacing: 10) {
                            checkButton(
                                id: "Check manual \(item.name)",
                                label: "Check \(item.name)",
                                isChecked: item.isChecked
                            ) {
                                store.setGroceryManualItemChecked(id: item.id, isChecked: !item.isChecked)
                            }
                            Text(item.name)
                            Spacer()
                            Button(role: .destructive) {
                                store.removeGroceryManualItem(id: item.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(item.name)")
                            .accessibilityIdentifier("Remove manual \(item.name)")
                        }
                        // No container identifier (child fan-out lesson).
                    }
                }
            }

            Section("Shopping List") {
                if store.grocerySnapshot.recipeLines.isEmpty {
                    Text("Nothing from recipes yet. Add a recipe above.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.grocerySnapshot.recipeLines) { line in
                        recipeLineRow(line)
                    }
                }
            }

            Section("Share") {
                Button {
                    do {
                        groceryExportURL = try store.exportedGroceryListURL()
                        statusMessage = "Grocery list written. Use the share item below to move it off-device."
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export grocery list (text)", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("Export grocery list")
                if let groceryExportURL {
                    ShareLink(
                        "Share grocery list",
                        item: groceryExportURL,
                        preview: SharePreview("Cook Console grocery list", image: Image(systemName: "cart"))
                    )
                    .accessibilityIdentifier("Share grocery list")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("Grocery export error")
                }
            }

            Section {
                Button("Done Shopping") {
                    store.doneShopping()
                    statusMessage = "Checked-off items cleared for the next trip."
                }
                .accessibilityIdentifier("Done shopping")
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Grocery status message")
                }
            }
        }
        .navigationTitle("Grocery List")
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissKeyboard()
                }
                .accessibilityIdentifier("Done Editing")
            }
        }
        .sheet(isPresented: $showRecipePicker) {
            NavigationStack {
                GroceryRecipePicker()
            }
        }
        .onAppear { store.loadGroceryList() }
    }

    /// NOTE: no `.accessibilityIdentifier` on the row container — an
    /// identifier on a multi-element row overwrites its children's
    /// identifiers (issue #19 lesson), which clobbers the stepper/label
    /// queries the UI test needs. Identity lives on each control instead.
    @ViewBuilder
    private func selectionRow(_ selection: GrocerySelection) -> some View {
        let title = store.recipe(id: selection.recipeID)?.title ?? "Deleted recipe"
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("Selection title \(title)")
                HStack(spacing: 8) {
                    Button {
                        store.updateGrocerySelectionServings(
                            id: selection.id,
                            servings: max(0.5, selection.servings - 0.5)
                        )
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Decrease servings for \(title)")
                    .accessibilityIdentifier("Decrease servings \(title)")

                    Text("\(KitchenQuantityFormatter.string(selection.servings)) servings")
                        .monospacedDigit()
                        .accessibilityIdentifier("Servings for \(title)")

                    Button {
                        store.updateGrocerySelectionServings(
                            id: selection.id,
                            servings: min(99, selection.servings + 0.5)
                        )
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Increase servings for \(title)")
                    .accessibilityIdentifier("Increase servings \(title)")
                }
                .font(.subheadline)
            }
            Spacer()
            Button(role: .destructive) {
                store.removeGrocerySelection(id: selection.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(title) from list")
            .accessibilityIdentifier("Remove selection \(title)")
        }
    }

    @ViewBuilder
    private func recipeLineRow(_ line: GroceryLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            checkButton(
                id: "Check recipe line \(line.name)",
                label: "Check \(line.name)",
                isChecked: line.isChecked
            ) {
                store.setGroceryRecipeLineChecked(key: line.normalizedKey, isChecked: !line.isChecked)
            }
            VStack(alignment: .leading, spacing: 4) {
                // NO identifier on the row container: identifiers on a
                // multi-element row overwrite every child's identifier
                // (issue #19 lesson — proved again by run 36954402316
                // where 'Check recipe line Olive oil' surfaced under the
                // container's id). Identity lives on each control.
                Text(rowText(line))
                    .strikethrough(line.isChecked)
                    .foregroundStyle(line.isChecked ? .secondary : .primary)
                    .accessibilityIdentifier("Grocery row text \(line.name)")
                if !line.sources.isEmpty {
                    Text("For: \(line.sources.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Grocery provenance \(line.name)")
                }
            }
        }
    }

    private func rowText(_ line: GroceryLine) -> String {
        var text: String
        if line.showsAmount, let amount = line.displayAmount, let unit = line.unit {
            text = "\(KitchenQuantityFormatter.string(amount)) \(unit.symbol) \(line.name)"
        } else {
            text = line.name
        }
        var qualifiers: [String] = []
        if line.isTasteDosed { qualifiers.append("to taste") }
        if line.hasOptionalContribution && !line.isTasteDosed {
            qualifiers.append("some recipes optional")
        }
        if !qualifiers.isEmpty { text += " (\(qualifiers.joined(separator: ", ")))" }
        return text
    }

    /// Check marks as borderless buttons rather than `Toggle`s: iOS 26
    /// List rows merge Toggle labels into one AX element whose synthesized
    /// taps can silently miss the switch (issue #5/#19 family of runner
    /// failures). A plain button's tap target is the whole glyph.
    @ViewBuilder
    private func checkButton(id: String, label: String, isChecked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isChecked ? Color.green : Color.secondary)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Keyboard dismissal identical to the recipe editor's proven pattern
    /// (issue #3 review): FocusState alone is unreliable on the hosted
    /// simulator — Done also asks the key window to end editing.
    private func dismissKeyboard() {
        entryFocused = false

        let activeWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        _ = activeWindow?.endEditing(true)
    }

    private func addManualItem() {
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addGroceryManualItem(name: text)
        newItemText = ""
    }
}

/// Picks which recipes join the shopping list. Already-selected recipes show
/// as checked and drop straight back out of the picker on tap (toggle-off),
/// so re-tapping can never double-count a recipe's ingredients.
private struct GroceryRecipePicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(store.recipes) { recipe in
            let isSelected = store.grocerySelections.contains { $0.recipeID == recipe.id }
            Button {
                if let existing = store.grocerySelections.first(where: { $0.recipeID == recipe.id }) {
                    store.removeGrocerySelection(id: existing.id)
                } else {
                    store.addGrocerySelection(recipeID: recipe.id)
                }
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.green : Color.secondary)
                    Text(recipe.title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Pick recipe \(recipe.title)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .navigationTitle("Add Recipes")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("Finish picking recipes")
            }
        }
    }
}
