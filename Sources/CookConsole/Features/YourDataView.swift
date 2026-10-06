import SwiftUI
import UniformTypeIdentifiers

private struct JSONBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct YourDataView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportFile: JSONBackupFile?
    @State private var showingExporter = false
    @State private var csvExportURL: URL?
    @State private var showingImporter = false
    @State private var preview: JSONImportPreview?
    @State private var archived: [Recipe] = []
    @State private var purgeCandidate: Recipe?
    @State private var lastBackup: Date?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Backup") {
                Text(lastBackup.map { "Last confirmed JSON save: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No confirmed JSON backup saved yet.")
                    .accessibilityIdentifier("Last confirmed backup")
                Button {
                    do {
                        exportFile = JSONBackupFile(data: try Data(contentsOf: store.exportedJSONBackupURL()))
                        showingExporter = true
                    } catch { errorMessage = error.localizedDescription }
                } label: {
                    Label("Save JSON backup…", systemImage: "doc.badge.arrow.up")
                }
                .accessibilityIdentifier("Export JSON backup")
                Text("Includes export date/app version, all recipes (including deleted recipes and deletion dates), ingredients, steps, tags, favorites, scaling notes, cook sessions, timer logs/events, grocery selections and checked keys, and manual grocery items. Excludes pantry items/staples, review provenance and kitchen-test observations, settings, notification permission/schedules and pending completion alerts, and this backup-save timestamp. Those excluded records cannot be recovered from this file. Older JSON files may also omit groceries and deletion dates.")
                    .font(.footnote)
                    .accessibilityIdentifier("Backup contents")
                Text("Only a successful system save confirms a backup. Canceling or preparing a file does not. Keep a copy outside the app; CSV is a history report, not a restorable backup.")
                    .font(.footnote)
                Button {
                    do {
                        csvExportURL = try store.exportedHistoryCSVURL()
                        statusMessage = "History CSV prepared. Use Share history CSV to save it. This does not confirm a backup."
                    } catch { errorMessage = error.localizedDescription }
                } label: {
                    Label("Export cook history (CSV)", systemImage: "tablecells")
                }
                .accessibilityIdentifier("Export CSV history")
                if let csvExportURL {
                    ShareLink("Share history CSV", item: csvExportURL)
                        .accessibilityIdentifier("Share CSV history")
                }
            }
            Section("Recovery") {
                Button { showingImporter = true } label: {
                    Label("Import JSON backup…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("Import JSON backup")
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset"),
                   ProcessInfo.processInfo.arguments.contains("-ui-testing-recovery-fixture") {
                    Button("Preview local recovery fixture") {
                        do { preview = try store.recoveryFixturePreview() }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .accessibilityIdentifier("Preview recovery fixture")
                }
                Text("Preview before applying. Matching recipe IDs: backup content wins; identical recipes stay unchanged. Existing history and grocery IDs stay unchanged; new IDs are added. Items missing from a file are kept. Deleted recipes remain deleted even when an older backup has no deletion dates; their active cooks/timers stop and grocery selections are excluded. Imported active timers for live recipes use their saved deadlines. Pantry and reviews remain unchanged. Cancel changes nothing. If your data changes after preview, choose the file again to re-preview.")
                    .font(.footnote)
                    .accessibilityIdentifier("Import conflict policy")
                if let summary = store.importSummary {
                    Text("Last import: \(summary)").accessibilityIdentifier("Import summary")
                }
            }
            Section("Deleted Recipes") {
                Text("Retained until you explicitly permanently delete them; no automatic expiry. Restore keeps recipe and history, but does not restart cooking or re-add grocery selections. Permanently deleting also removes its cook history and review records. App removal deletes the archive too.")
                    .font(.footnote)
                    .accessibilityIdentifier("Archive retention")
                if archived.isEmpty { Text("No deleted recipes.") }
                ForEach(archived) { recipe in
                    Text(recipe.title).accessibilityIdentifier("Archived recipe \(recipe.title)")
                    Button("Restore \(recipe.title)") {
                        do { try store.restoreRecipe(id: recipe.id); try loadArchive() }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .accessibilityIdentifier("Restore recipe \(recipe.title)")
                    Button("Permanently delete \(recipe.title)…", role: .destructive) { purgeCandidate = recipe }
                        .accessibilityIdentifier("Purge recipe \(recipe.title)")
                }
            }
            Section("Your data, on your phone") {
                Text("Every recipe, cook session, and timer log lives in a local SQLite database inside this app's private storage. Cook Console performs zero network requests — there are no accounts, no analytics, no ads, and no cloud sync.")
                    .accessibilityIdentifier("Privacy storage statement")
                Text("The only permission Cook Console can ask for is notifications (for local cook timers); declining it keeps on-screen alerts while the app is open. Camera, microphone, contacts, and location are never requested.")
                    .accessibilityIdentifier("Privacy permissions statement")
                Text("Deleting the app deletes everything inside its storage, including the database, deleted archive, and temporary exports. Save a JSON backup outside the app first; copies you saved outside the app remain there.")
                    .accessibilityIdentifier("Privacy deletion statement")
            }
        }
        .navigationTitle("Your Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
        .onAppear {
            lastBackup = store.lastConfirmedBackup
            do { try loadArchive() } catch { errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $showingExporter, document: exportFile, contentType: .json, defaultFilename: "CookConsole-backup") { @MainActor @Sendable result in
            switch result {
            case .success(let url):
                do {
                    guard url.isFileURL else { throw CocoaError(.fileWriteUnknown) }
                    try store.confirmBackupSaved()
                    lastBackup = store.lastConfirmedBackup
                    statusMessage = "JSON backup saved."
                } catch { errorMessage = "File saved, but confirmation could not be recorded: \(error.localizedDescription)" }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { @MainActor @Sendable result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                preview = try store.previewJSONBackup(from: url)
            } catch { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                NavigationStack {
                    List {
                        Text("Backup content replaces matching recipes; existing history and grocery IDs are kept. Deleted recipes remain archived; their active cooks/timers stop and grocery selections are excluded. Imported active timers for live recipes use saved deadlines. Items absent from the file, pantry, and reviews are kept.")
                            .accessibilityIdentifier("Preview conflict policy")
                        Text(preview.outcome.summaryText).accessibilityIdentifier("Import preview summary")
                        ForEach(Array(preview.recipeOutcomes.enumerated()), id: \.offset) { _, outcome in Text(outcome) }
                        Button("Apply import") {
                            do {
                                try store.applyJSONPreview(preview)
                                self.preview = nil
                                try loadArchive()
                            } catch {
                                self.preview = nil
                                errorMessage = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("Apply JSON import")
                    }
                    .navigationTitle("Import Preview")
                    .toolbar { Button("Cancel", role: .cancel) { self.preview = nil } }
                }
            }
        }
        .confirmationDialog("Permanently delete recipe and history?", isPresented: Binding(get: { purgeCandidate != nil }, set: { if !$0 { purgeCandidate = nil } }), titleVisibility: .visible) {
            if let recipe = purgeCandidate {
                Button("Permanently delete", role: .destructive) {
                    do { try store.purgeRecipe(id: recipe.id); try loadArchive() }
                    catch { errorMessage = error.localizedDescription }
                    purgeCandidate = nil
                }
            }
        } message: { Text("This cannot be undone inside the app. Only a saved backup can recover it.") }
        .alert("Export ready", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(statusMessage ?? "") }
        .alert("Data operation failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func loadArchive() throws { archived = try store.archivedRecipes() }
}
