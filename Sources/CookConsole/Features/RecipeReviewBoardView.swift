import SwiftUI

/// Issue #21 review board: shows the desk-review status of every recipe
/// (from the curated pack), the physical kitchen-test queue, and lets a
/// cook record a real kitchen test with reproducible notes.
///
/// UI rule followed (see #5/#20 CI history): identifiers live on leaf
/// controls only, never on container rows or Sections — container ids
/// fan out over children in the XCUITest hierarchy.
struct RecipeReviewBoardView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingRecordSheet = false
    @State private var selectedRecipeID: UUID?

    var body: some View {
        List {
            Section {
                if let summary = store.reviewGapSummary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Desk review passed: \(summary.deskPassedCount) · defects open: \(summary.openDefectCount) · kitchen-tested: \(summary.kitchenTestedCount)")
                            .font(.subheadline)
                            .accessibilityIdentifier("Review gap counts")
                        Text("A timer or automated check never establishes doneness — physical tests need written notes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("No review pack is bundled with this build.")
                        .foregroundStyle(.secondary)
                }
                // In-list leaf button: toolbar items are unreliable in the
                // XCUITest hierarchy (issue #7 finding); in-list leaf
                // controls bridge reliably.
                Button {
                    selectedRecipeID = store.reviewBoardRows.first(where: \.existsLocally)?.recipeID
                    showingRecordSheet = true
                } label: {
                    Label("Record Kitchen Test", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("Record Kitchen Test")
            } header: {
                Text("Coverage")
            }

            Section("Recipes") {
                ForEach(store.reviewBoardRows, id: \.recipeID) { row in
                    reviewRow(row)
                }
            }
        }
        .navigationTitle("Recipe Review")
        .accessibilityIdentifier("Review browser")
        .sheet(isPresented: $showingRecordSheet) {
            NavigationStack {
                KitchenTestRecordView(selectedRecipeID: $selectedRecipeID)
            }
        }
    }

    @ViewBuilder
    private func reviewRow(_ row: RecipeReviewBoardRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .font(.headline)
                    .accessibilityIdentifier("Review title \(row.title)")
                Spacer()
                Text(deskBadge(row))
                    .font(.caption)
                    .accessibilityIdentifier("Desk state \(row.title)")
            }
            HStack {
                Text(kitchenBadge(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Kitchen state \(row.title)")
                Spacer()
                if let priority = row.queuePriority {
                    Text("Test queue #\(priority)")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("Queue priority \(row.title)")
                }
            }
            if let provenance = row.provenance {
                Text(provenance)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("Provenance \(row.title)")
            }
            if row.exceptionCount > 0 {
                // Borderless (not .link — .link is unavailable on iOS).
                Button("\(row.exceptionCount) editorial exception\(row.exceptionCount == 1 ? "" : "s")") {
                    // Exceptions carry justifications in the pack; the
                    // button keeps them discoverable instead of silent.
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("Exceptions \(row.title)")
            }
        }
        .padding(.vertical, 2)
    }

    private func deskBadge(_ row: RecipeReviewBoardRow) -> String {
        switch row.deskState {
        case .passed: "Desk review ✓"
        case .issuesOpen: "Desk defect open"
        case .notInReviewPack: "Not in review pack"
        }
    }

    private func kitchenBadge(_ row: RecipeReviewBoardRow) -> String {
        switch row.kitchenTestStatus {
        case .notTested: "Kitchen: not tested (\(row.observationCount) notes)"
        case .passed: "Kitchen: passed (\(row.observationCount) notes)"
        case .failed: "Kitchen: failed (\(row.observationCount) notes)"
        }
    }
}

/// Records one physical kitchen test. Notes are mandatory — this is the
/// ONLY entry point for a kitchen-tested claim, and an empty note fails
/// at the domain layer (`KitchenTestObservation.init`), not just the UI.
struct KitchenTestRecordView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedRecipeID: UUID?
    @State private var result: KitchenTestResult = .passed
    @State private var notes = ""
    @State private var tester = "cook"

    var body: some View {
        Form {
            Picker("Recipe", selection: $selectedRecipeID) {
                Text("Choose a recipe").tag(UUID?.none)
                // Physical tests persist against a cookable local recipe
                // (FK); pack-only rows cannot accept observations.
                ForEach(store.reviewBoardRows.filter(\.existsLocally), id: \.recipeID) { row in
                    Text(row.title).tag(UUID?.some(row.recipeID))
                }
            }
            .accessibilityIdentifier("Test recipe picker")

            Picker("Result", selection: $result) {
                Text("Passed").tag(KitchenTestResult.passed)
                Text("Failed").tag(KitchenTestResult.failed)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Test result picker")

            Section {
                TextField("Reproducible notes (what you cooked, deviations, sensory results)", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("Test notes field")
                TextField("Tester", text: $tester)
                    .accessibilityIdentifier("Tester field")
            } header: {
                Text("Evidence")
            } footer: {
                Text("Elapsed time alone never establishes doneness. Describe the sensory cue you actually observed.")
            }

            Button("Save Kitchen Test") {
                save()
            }
            .disabled(selectedRecipeID == nil || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("Save Kitchen Test")
        }
        .navigationTitle("Kitchen Test")
    }

    private func save() {
        guard let recipeID = selectedRecipeID else { return }
        let observation = try? KitchenTestObservation(
            result: result,
            notes: notes,
            tester: tester
        )
        guard let observation else { return }
        store.recordKitchenTestObservation(observation, recipeID: recipeID)
        dismiss()
    }
}
