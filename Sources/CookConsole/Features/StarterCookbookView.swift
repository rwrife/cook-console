import SwiftUI

struct StarterCookbookView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var review: StarterCookbookReview?
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let review {
                Section {
                    Text("Starter cookbook version \(review.pack.version): \(review.entries.count) recipes bundled with this app. Review the content below before accepting. No recipes are installed until you accept.")
                        .accessibilityIdentifier("Starter update introduction")
                    Text("Accept updates unedited starter content and adds new recipes. Edited recipes and archived or removed recipes stay as they are. Favorites, personal notes, ratings, and cooking history are preserved.")
                }
                Section("Recipe changes") {
                    ForEach(review.entries) { entry in
                        NavigationLink {
                            StarterCookbookEntryView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.proposed.title).font(.headline)
                                Text(entry.action.rawValue).font(.subheadline)
                            }
                        }
                        .accessibilityIdentifier("Review starter \(entry.proposed.title)")
                    }
                }
                Section {
                    Button("Accept Starter Update") { decide(accept: true) }
                        .disabled(!review.canAccept)
                        .accessibilityIdentifier("Accept Starter Update")
                    Button("Skip This Version") { decide(accept: false) }
                        .accessibilityIdentifier("Skip Starter Version")
                    if !review.canAccept {
                        Text("An active cook or timer blocks this update. Finish cooking and stop timers, then refresh, or skip this version.")
                    }
                    Text("Skipping dismisses this version. A later bundled version can offer another update.")
                        .font(.footnote)
                }
            } else if loaded && errorMessage == nil {
                Text("No pending starter update. This bundled version has already been accepted or skipped.")
                    .accessibilityIdentifier("No pending starter update")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Starter Cookbook")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("Close Starter Cookbook")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { refresh() }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        do {
            review = try store.reviewStarterCookbook()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        loaded = true
    }

    private func decide(accept: Bool) {
        guard let review else { return }
        do {
            if accept { try store.acceptStarterCookbook(review) }
            else { try store.skipStarterCookbook(review) }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }
}

private struct StarterCookbookEntryView: View {
    let entry: StarterCookbookReview.Entry
    var body: some View {
        List {
            Section("Decision") { Text(entry.action.rawValue) }
            if let current = entry.current {
                Section("Your current recipe") { content(current, identifier: "Starter current title") }
            }
            Section("Bundled recipe") { content(entry.proposed, identifier: "Starter bundled title") }
        }
        .navigationTitle(entry.proposed.title)
    }

    @ViewBuilder private func content(_ recipe: Recipe, identifier: String) -> some View {
        Text(recipe.title).font(.headline).accessibilityIdentifier(identifier)
        Text("Servings: \(recipe.servings.formatted())")
        ForEach(recipe.ingredients) { ingredient in
            Text("\(ingredient.amount.formatted()) \(ingredient.unit.symbol) \(ingredient.name)")
        }
        ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
            Text("\(index + 1). \(step.instruction)")
            if let seconds = step.timerDuration { Text("Timer: \(seconds.formatted()) seconds").font(.footnote) }
        }
        if !recipe.tags.isEmpty { Text("Tags: " + recipe.tags.joined(separator: ", ")) }
        if let text = recipe.panSizeGuidance { Text(text) }
        if let text = recipe.batchSizeGuidance { Text(text) }
        if let text = recipe.cookingTimeGuidance { Text(text) }
    }
}
