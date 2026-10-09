import SwiftUI
import UIKit

struct PersonalRecipeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingNotes: Bool
    @State private var notes = ""
    @State private var rating = 0
    @State private var loaded = false
    @State private var summary: RecipeCookingSummary?
    let recipeID: UUID

    var body: some View {
        Form {
            Section("Your rating") {
                Picker("Rating", selection: $rating) {
                    Text("Unrated").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) stars").tag($0) }
                }
                .accessibilityIdentifier("Personal rating")
            }
            Section("Personal notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 140)
                    .focused($editingNotes)
                    .accessibilityLabel("Personal notes")
                    .accessibilityIdentifier("Personal notes")
                Text("Substitutions, taste adjustments, or less salt next time. These notes never change the recipe instructions. Maximum 20,000 characters.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let summary {
                Section("Cooking history") {
                    if let date = summary.lastCookedAt {
                        Text("Last cooked: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityIdentifier("Last cooked")
                    } else {
                        Text("Not cooked yet").accessibilityIdentifier("Last cooked")
                    }
                    NavigationLink("View completed cooking history") {
                        List {
                            if summary.completedSessions.isEmpty {
                                Text("No completed cooking sessions")
                            }
                            ForEach(summary.completedSessions) { session in
                                VStack(alignment: .leading) {
                                    Text(session.endedAt!.formatted(date: .abbreviated, time: .shortened))
                                    Text("Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .navigationTitle("Cooking history")
                    }
                    .accessibilityIdentifier("Personal cooking history")
                }
            }
            Section {
                Button("Clear notes and rating", role: .destructive) { notes = ""; rating = 0 }
                    .accessibilityIdentifier("Clear personal notes")
                Text("Clear is saved only when you tap Save. Cancel discards all changes. Deleted Recipes retains notes and history; permanent deletion removes them. Backups include personal data; incoming personal records replace yours after preview, while older backups keep yours.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notes & rating")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        let value = try PersonalRecipeNotes(recipeID: recipeID, notes: notes, rating: rating == 0 ? nil : rating)
                        try store.savePersonalNotes(value)
                        dismiss()
                    } catch { store.present(error) }
                }
                .disabled(!loaded || notes.count > 20_000)
                .accessibilityIdentifier("Save personal notes")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    editingNotes = false
                    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                        .flatMap(\.windows).first(where: \.isKeyWindow)?.endEditing(true)
                }
                .accessibilityIdentifier("Done Editing")
            }
        }
        .onAppear {
            if !loaded, let value = store.personalNotes(for: recipeID) {
                notes = value.notes; rating = value.rating ?? 0; loaded = true
            }
            summary = store.cookingSummary(for: recipeID)
        }
    }
}
