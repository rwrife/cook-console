import SwiftUI

struct WhatCanIMakeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newIngredientText = ""
    @State private var selectedFilter: SuggestionFilter = .all

    enum SuggestionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case completeOnly = "Ready to Cook"

        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pantry Suggestions")
                        .font(.headline)
                    Text(PantrySuggestionEngine.quantityDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Pantry quantity disclaimer")
                }
                .padding(.vertical, 2)
            }

            Section("Ingredients On Hand") {
                HStack {
                    TextField("Add ingredient (e.g. Eggs)", text: $newIngredientText)
                        .accessibilityIdentifier("Add pantry ingredient field")
                        .onSubmit(addIngredient)
                    Button("Add") {
                        addIngredient()
                    }
                    .disabled(newIngredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Add pantry ingredient button")
                }

                if store.pantryOnHand.isEmpty {
                    Text("No ingredients added yet. Enter items you have in your kitchen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.pantryOnHand) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Button(role: .destructive) {
                                store.removePantryItem(id: item.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(item.name)")
                            .accessibilityIdentifier("Remove \(item.name)")
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    StaplesConfigView()
                } label: {
                    HStack {
                        Label("Assumed Pantry Staples", systemImage: "takeoutbag.and.cup.and.straw")
                        Spacer()
                        Text("\(store.pantryStaples.count) items")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("Configure staples link")
            }

            Section {
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(SuggestionFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("Pantry suggestion filter")

                if filteredSuggestions.isEmpty {
                    ContentUnavailableView(
                        "No Matching Recipes",
                        systemImage: "magnifyingglass",
                        description: Text("Try adding more ingredients on hand or adjusting your staples.")
                    )
                } else {
                    ForEach(filteredSuggestions) { suggestion in
                        NavigationLink(value: suggestion.recipe.id) {
                            SuggestionRow(suggestion: suggestion)
                        }
                        .accessibilityIdentifier("Pantry suggestion \(suggestion.recipe.title)")
                    }
                }
            } header: {
                Text("Matching Recipes (\(filteredSuggestions.count))")
            }
        }
        .navigationTitle("What Can I Make?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            store.loadPantrySuggestions()
        }
    }

    private var filteredSuggestions: [RecipePantrySuggestion] {
        switch selectedFilter {
        case .all:
            return store.pantrySuggestions
        case .completeOnly:
            return store.pantrySuggestions.filter(\.isCompleteMatch)
        }
    }

    private func addIngredient() {
        let trimmed = newIngredientText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addPantryItem(name: trimmed, kind: .onHand)
        newIngredientText = ""
    }
}

private struct SuggestionRow: View {
    let suggestion: RecipePantrySuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.recipe.title)
                    .font(.headline)
                Spacer()
                if suggestion.isCompleteMatch {
                    Text("Ready")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("Ready badge \(suggestion.recipe.title)")
                } else {
                    Text("\(suggestion.missingIngredientNames.count) missing")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Missing badge \(suggestion.recipe.title)")
                }
            }

            if !suggestion.missingIngredientNames.isEmpty {
                Text("Missing: " + suggestion.missingIngredientNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("Missing list \(suggestion.recipe.title)")
            }

            if !suggestion.stapleIngredientNames.isEmpty {
                Text("Uses staples: " + suggestion.stapleIngredientNames.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StaplesConfigView: View {
    @EnvironmentObject private var store: AppStore
    @State private var newStapleText = ""

    var body: some View {
        List {
            Section {
                Text("Pantry staples are common items assumed to always be available unless you remove them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Staples") {
                HStack {
                    TextField("Add staple (e.g. Flour)", text: $newStapleText)
                        .accessibilityIdentifier("Add staple field")
                        .onSubmit(addStaple)
                    Button("Add") {
                        addStaple()
                    }
                    .disabled(newStapleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Add staple button")
                }

                ForEach(store.pantryStaples) { staple in
                    HStack {
                        Text(staple.name)
                        Spacer()
                        Button(role: .destructive) {
                            store.removePantryItem(id: staple.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(staple.name)")
                        .accessibilityIdentifier("Remove staple \(staple.name)")
                    }
                }
            }
        }
        .navigationTitle("Configured Staples")
    }

    private func addStaple() {
        let trimmed = newStapleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addPantryItem(name: trimmed, kind: .staple)
        newStapleText = ""
    }
}
