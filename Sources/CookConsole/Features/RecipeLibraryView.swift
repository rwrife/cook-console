import SwiftUI

struct RecipeLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if store.recipes.isEmpty {
                    ContentUnavailableView {
                        Label("No Recipes", systemImage: "fork.knife")
                    } description: {
                        Text(emptyMessage)
                    } actions: {
                        Button("Create Recipe") { showingCreate = true }
                    }
                } else {
                    List(store.recipes) { recipe in
                        NavigationLink(value: recipe.id) {
                            HStack(spacing: 12) {
                                Image(systemName: recipe.isFavorite ? "star.fill" : "fork.knife")
                                    .foregroundStyle(recipe.isFavorite ? .yellow : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.title)
                                        .font(.headline)
                                    Text(recipe.tags.joined(separator: " · "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel(recipe.title)
                    }
                }
            }
            .navigationTitle("Recipes")
            .searchable(text: $searchText, prompt: "Search titles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All Tags") { selectedTag = nil }
                        ForEach(store.allTags, id: \.self) { tag in
                            Button(tag) { selectedTag = tag }
                        }
                    } label: {
                        Label(selectedTag ?? "All Tags", systemImage: "tag")
                    }
                    .accessibilityLabel("Filter by tag")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add Recipe", systemImage: "plus") {
                    showingCreate = true
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationDestination(for: UUID.self) { recipeID in
                RecipeDetailView(recipeID: recipeID)
            }
            .sheet(isPresented: $showingCreate) {
                NavigationStack {
                    RecipeEditorView(recipe: nil)
                }
            }
            .onAppear { reload() }
            .onChange(of: searchText) { _, _ in reload() }
            .onChange(of: selectedTag) { _, _ in reload() }
        }
    }

    private var emptyMessage: String {
        if !searchText.isEmpty || selectedTag != nil {
            return "No recipes match this search and tag filter."
        }
        return "Create your first local recipe. No account or cloud is used."
    }

    private func reload() {
        store.loadLibrary(searchText: searchText, selectedTag: selectedTag)
    }
}
