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

/// Regular-width workspace: the console/detail split. The leading pane is
/// `ConsoleSplitPane` — the surface `docs/dual-screen-migration.md` names
/// as the future iPhone Duo secondary-display binding — and the trailing
/// pane is the ordinary library/detail navigation stack, so a size-class
/// transition preserves the recipe journey and cook session (both are
/// durable in `AppStore`/GRDB, not in view state).
///
/// Deliberately a plain HStack, not `NavigationSplitView`: on iPhone even
/// regular widths NavigationSplitView presents a single column at a time,
/// which would hide the library beside the console pane (the acceptance
/// criterion is a visible two-pane split). An explicit half-width split is
/// deterministic in both simulators the CI exercises.
struct RecipeWorkspaceView: View {
    var body: some View {
        HStack(spacing: 0) {
            ConsoleSplitPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NavigationStack {
                RecipeLibraryContent()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    @State private var discovery = RecipeDiscoveryFilter()
    @State private var showingFilters = false
    @State private var showingCreate = false
    @State private var showingYourData = false
    @State private var showingPantrySuggestions = false
    @State private var showingGroceryList = false
    @State private var showingReviewBoard = false
    @State private var showingStarterCookbook = false

    var body: some View {
        Group {
            if store.recipes.isEmpty {
                VStack(spacing: 12) {
                    if hasActiveFilters {
                        Text("0 matching recipes")
                            .font(.headline)
                            .accessibilityIdentifier("Discovery result count")
                        ForEach(activeFilterLabels, id: \.self) { label in
                            Text(label).accessibilityIdentifier("Active filter \(label)")
                        }
                    }
                    ContentUnavailableView {
                        Label("No Recipes", systemImage: "fork.knife")
                    } description: {
                        Text(emptyMessage)
                    } actions: {
                        if hasActiveFilters {
                            Button("Clear Filters") { clearAllFilters() }
                        }
                        Button("Create Recipe") { showingCreate = true }
                    }
                }
                // Covers both the empty and populated states so size-class
                // transition tests can prove the detail column stayed mounted.
                .accessibilityIdentifier("Recipe browser")
            } else {
                List {
                    if hasActiveFilters {
                        activeFiltersSection
                    }
                    ForEach(store.recipes) { recipe in
                        NavigationLink(value: recipe.id) {
                            HStack(spacing: 12) {
                                Image(systemName: recipe.isFavorite ? "star.fill" : "fork.knife")
                                    .foregroundStyle(recipe.isFavorite ? .yellow : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.title)
                                        .font(.headline)
                                    Text(discoveryRowSubtitle(for: recipe))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // Title as the label, tags as the value: the earlier
                        // bare `.accessibilityLabel(title)` replaced the row's
                        // combined narration, hiding tags from VoiceOver.
                        .accessibilityLabel(recipe.title)
                        .accessibilityValue(recipe.tags.isEmpty ? "no tags" : recipe.tags.joined(separator: ", "))
                        .accessibilityIdentifier("Recipe row \(recipe.title)")
                    }
                }
                .accessibilityIdentifier("Recipe browser")
            }
        }
        .navigationTitle("Recipes")
        .searchable(text: $searchText, prompt: "Search titles")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Starter Cookbook", systemImage: "books.vertical") {
                    showingStarterCookbook = true
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Starter Cookbook")
                .accessibilityIdentifier("Starter Cookbook")
            }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingYourData = true
                } label: {
                    Label("Backup & recovery", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("Your data")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingReviewBoard = true
                } label: {
                    Label("Recipe Review", systemImage: "checkmark.seal")
                }
                .accessibilityIdentifier("Recipe Review")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Discovery Filters", systemImage: discovery.isActive ? "line.3.filter.decline.fill" : "line.3.filter") {
                    showingFilters = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("Discovery Filters")
                .accessibilityIdentifier("Discovery Filters")

                Button("What Can I Make?", systemImage: "cabinet.fill") {
                    showingPantrySuggestions = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("What Can I Make?")
                .accessibilityIdentifier("What Can I Make")

                // Issue #20: the combined grocery list lives at the same
                // persistent bottom inset as the pantry entry — toolbar
                // items disappear under an active search field (issue #3
                // finding), and the grocery flow must stay reachable.
                // Issue #27 repair: the pantry/grocery entries became
                // icon-only so the fourth bottom-row entry (Discovery
                // Filters) fits at compact width without truncation;
                // tests and VoiceOver still see the full labels.
                Button("Grocery", systemImage: "cart.fill") {
                    showingGroceryList = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("Grocery")
                .accessibilityIdentifier("Grocery List")

                Spacer()

                Button("Add Recipe", systemImage: "plus") {
                    showingCreate = true
                }
                .buttonStyle(.borderedProminent)
            }
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
        .sheet(isPresented: $showingYourData) {
            NavigationStack {
                YourDataView()
            }
        }
        .sheet(isPresented: $showingPantrySuggestions) {
            NavigationStack {
                WhatCanIMakeView()
                    .navigationDestination(for: UUID.self) { recipeID in
                        RecipeDetailView(recipeID: recipeID)
                    }
            }
        }
        .sheet(isPresented: $showingGroceryList) {
            NavigationStack {
                GroceryListView()
            }
        }
        .sheet(isPresented: $showingStarterCookbook) {
            NavigationStack { StarterCookbookView() }
        }
        .sheet(isPresented: $showingReviewBoard) {
            NavigationStack {
                RecipeReviewBoardView()
                    .onAppear { store.loadRecipeReviews() }
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                RecipeDiscoveryFilterView(discovery: $discovery)
            }
        }
        .onAppear { reload() }
        .onChange(of: searchText) { _, _ in reload() }
        .onChange(of: selectedTag) { _, _ in reload() }
        .onChange(of: discovery) { _, _ in reload() }
    }

    private var hasActiveFilters: Bool {
        discovery.isActive || selectedTag != nil || !searchText.isEmpty
    }

    private func clearAllFilters() {
        discovery = RecipeDiscoveryFilter()
        selectedTag = nil
        searchText = ""
    }

    private var activeFilterLabels: [String] {
        var labels = discovery.activeLabels
        if let selectedTag { labels.append("Tag: \(selectedTag)") }
        if !searchText.isEmpty { labels.append("Search: \(searchText)") }
        return labels
    }

    /// Result count + every active filter + clear-all (issue #27). The
    /// list itself stays the primary surface; this header never replaces it.
    private var activeFiltersSection: some View {
        Section {
            ForEach(activeFilterLabels, id: \.self) { label in
                HStack {
                    Image(systemName: "line.3.filter")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(label)
                    Spacer()
                }
                .accessibilityIdentifier("Active filter \(label)")
            }
            Button("Clear all filters") {
                clearAllFilters()
            }
            .accessibilityIdentifier("Clear all filters")
        } header: {
            Text(resultCountText)
                .accessibilityIdentifier("Discovery result count")
        }
    }

    private var resultCountText: String {
        let count = store.recipes.count
        let noun = count == 1 ? "recipe" : "recipes"
        return "\(count) matching \(noun)"
    }

    private func discoveryRowSubtitle(for recipe: Recipe) -> String {
        var parts: [String] = []
        if !recipe.tags.isEmpty { parts.append(recipe.tags.joined(separator: " · ")) }
        // Unknown duration is labeled, never shown as "0 min" (issue #27).
        parts.append(recipe.totalMinutes.map { "\($0) min" } ?? "duration unknown")
        parts.append("\(recipe.ingredients.count) ingredients")
        return parts.joined(separator: " · ")
    }

    private var emptyMessage: String {
        if !searchText.isEmpty || selectedTag != nil || discovery.isActive {
            return "No recipes match your search and filters. Clear filters or loosen duration, ingredient, meal, or dietary options."
        }
        return "Create your first local recipe. No account or cloud is used."
    }

    private func reload() {
        store.loadLibrary(searchText: searchText, selectedTag: selectedTag, discovery: discovery)
    }
}

/// Filter sheet: quick collections plus explicit filters (issue #27).
/// The 30-minute shortcut documents the unknown-duration rule; the
/// five-ingredient shortcut documents the counting rule in-view.
struct RecipeDiscoveryFilterView: View {
    @Binding var discovery: RecipeDiscoveryFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Quick collections") {
                Toggle(isOn: quickCollection($discovery.maxMinutes, 30)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("30 minutes or less")
                        Text("Only recipes with a stated total time. Recipes without a stated duration are hidden, never treated as 0 minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("Quick 30 minutes or less")

                Toggle(isOn: quickCollection($discovery.maxIngredients, 5)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Five ingredients or fewer")
                        Text("Rule: every ingredient row counts once — salt, water, and repeated names included. Unknown duration is not counted as zero.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("Quick five ingredients or fewer")
            }

            Section("Filters") {
                TextField("Ingredient name", text: $discovery.ingredient)
                    .accessibilityIdentifier("Ingredient filter")

                Picker("Meal type", selection: $discovery.mealType) {
                    Text("Any meal").tag(String?.none)
                    ForEach(RecipeDiscoveryFilter.mealTypes, id: \.self) { meal in
                        Text(meal.capitalized).tag(String?.some(meal))
                    }
                }
                .accessibilityIdentifier("Meal type filter")

                Picker("Dietary tag", selection: $discovery.dietaryTag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(RecipeDiscoveryFilter.dietaryTags, id: \.self) { tag in
                        Text(tag.capitalized).tag(String?.some(tag))
                    }
                }
                .accessibilityIdentifier("Dietary tag filter")
                // Issue #27 scope: dietary picks match USER TAGS only.
                // No ingredient-based inference — an unlabeled recipe is
                // simply excluded, so the app never makes dietary claims.
                Text("Matches recipe tags only. The app never infers dietary claims from ingredients.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clear") {
                Button("Clear all filters", role: .destructive) {
                    discovery = RecipeDiscoveryFilter()
                }
                .accessibilityIdentifier("Clear discovery filters")
            }
        }
        .navigationTitle("Discovery Filters")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("Done with discovery filters")
            }
        }
    }

    /// Binding that maps a nil-or-value cap onto a toggle, so the quick
    /// collections stay in sync with the same fields a manual edit uses.
    private func quickCollection(_ cap: Binding<Int?>, _ value: Int) -> Binding<Bool> {
        Binding(
            get: { cap.wrappedValue == value },
            set: { cap.wrappedValue = $0 ? value : nil }
        )
    }
}
