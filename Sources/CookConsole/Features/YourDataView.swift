import SwiftUI
import UniformTypeIdentifiers

/// In-app "Your data" screen (issue #6): documents the local-first privacy
/// contract and hosts one-tap export (JSON backup + CSV history via the
/// share sheet) and validated JSON import via the system file picker.
///
/// Every path here is a local file operation — `ShareLink` hands the
/// already-written file to the system share sheet / Files, and
/// `.fileImporter` hands a user-picked file back to us. No network API is
/// used or referenced (the CI zero-network grep gate enforces that).
struct YourDataView: View {
    @EnvironmentObject private var store: AppStore
    @State private var jsonExportURL: URL?
    @State private var csvExportURL: URL?
    @State private var showingImporter = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Import") {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import JSON backup…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("Import JSON backup")
                Text("Backups merge by item ID — existing recipes are kept or updated, never duplicated, and a file that fails validation changes nothing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Button {
                    do {
                        jsonExportURL = try store.exportedJSONBackupURL()
                        statusMessage = "Backup written. Use the share item below to save or move it."
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export JSON backup (recipes + history)", systemImage: "doc.badge.arrow.up")
                }
                .accessibilityIdentifier("Export JSON backup")

                Button {
                    do {
                        csvExportURL = try store.exportedHistoryCSVURL()
                        statusMessage = "History CSV written. Use the share item below to save or move it."
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export cook history (CSV)", systemImage: "tablecells")
                }
                .accessibilityIdentifier("Export CSV history")

                if let jsonExportURL {
                    ShareLink(
                        "Share JSON backup",
                        item: jsonExportURL,
                        preview: SharePreview("Cook Console backup", image: Image(systemName: "doc"))
                    )
                    .accessibilityIdentifier("Share JSON backup")
                }
                if let csvExportURL {
                    ShareLink(
                        "Share history CSV",
                        item: csvExportURL,
                        preview: SharePreview("Cook Console history", image: Image(systemName: "tablecells"))
                    )
                    .accessibilityIdentifier("Share CSV history")
                }
            }

            Section("Import") {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import JSON backup…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("Import JSON backup")
                Text("Backups merge by item ID — existing recipes are kept or updated, never duplicated, and a file that fails validation changes nothing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Your data, on your phone") {
                Text("""
                Every recipe, cook session, and timer log lives in a local \
                SQLite database inside this app's private storage. Cook \
                Console performs zero network requests — there are no \
                accounts, no analytics, no ads, and no cloud sync.
                """)
                .accessibilityIdentifier("Privacy storage statement")
                Text("""
                The only permission Cook Console can ask for is notifications \
                (for local cook timers); declining it keeps on-screen alerts \
                while the app is open. Camera, microphone, contacts, and \
                location are never requested.
                """)
                .accessibilityIdentifier("Privacy permissions statement")
                Text("""
                Deleting the app deletes everything: the database, exported \
                copies inside the app container, and any scheduled \
                notifications. Export first if you want to keep your library.
                """)
                .accessibilityIdentifier("Privacy deletion statement")
                if let summary = store.importSummary {
                    Text("Last import: \(summary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Import summary")
                }
            }
        }
        .navigationTitle("Your Data")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else {
                    errorMessage = "No file was selected."
                    return
                }
                do {
                    try store.importJSONBackup(from: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Export ready", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .alert("Import failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
