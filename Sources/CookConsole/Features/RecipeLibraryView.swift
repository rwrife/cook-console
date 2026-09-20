import SwiftUI

/// Compact-width library: library content inside its own NavigationStack.
/// (Pre-#5 shape, unchanged behavior.)
struct RecipeLibraryView: View {
    var body: some View {
        NavigationStack {
            RecipeLibraryContent()
        }
    }
}

/// Regular-width workspace: the console/detail split. The leading column
/// is `ConsoleSplitPane` — the surface `docs/dual-screen-migration.md`
/// names as the future iPhone Duo secondary-display binding — and the
/// trailing column is the ordinary library/detail navigation stack, so a
/// size-class transition preserves the recipe journey and cook session
/// (both are durable in `AppStore`/GRDB, not in view state).
struct RecipeWorkspaceView: View {
    var body: some View {
        NavigationSplitView {
            ConsoleSplitPane()
        } detail: {
            NavigationStack {
                RecipeLibraryContent()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("Console workspace")
    }
}

/// The library itself (list, search, tag filter, add sheet, push
/// destinations). Hosted by whichever navigation container the active
/// console layout provides.
struct RecipeLibraryContent: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var showingCreate = false

    var body: some View {
        Group {
            if store.recipes.isEmpty {
                ContentUnavailableView {
                    Label("No Recipes", systemImage: "fork.knife")
                } description: {
                    Text(emptyMessage)
                } actions: {
                    Button("Create Recipe") { showingCreate = true }
                }
                // Covers both the empty and populated states so size-class
                // transition tests can prove the detail column stayed mounted.
                .accessibilityIdentifier("Recipe browser")
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
                .accessibilityIdentifier("Recipe browser")
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
