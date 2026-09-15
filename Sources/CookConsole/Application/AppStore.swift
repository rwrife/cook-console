import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var allTags: [String] = []
    @Published var errorMessage: String?

    private let repository: RecipeRepository
    private var librarySearchText = ""
    private var librarySelectedTag: String?

    init(repository: RecipeRepository) {
        self.repository = repository
    }

    static func makeDefault() -> AppStore {
        do {
            let fileManager = FileManager.default
            let directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("CookConsole", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = directory.appendingPathComponent("recipes.sqlite")
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
                for suffix in ["", "-shm", "-wal"] {
                    let url = URL(fileURLWithPath: databaseURL.path + suffix)
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                }
            }
            return AppStore(
                repository: RecipeRepository(database: try RecipeDatabase.make(at: databaseURL.path))
            )
        } catch {
            fatalError("Unable to open the local recipe database: \(error.localizedDescription)")
        }
    }

    func loadLibrary(searchText: String = "", selectedTag: String? = nil) {
        librarySearchText = searchText
        librarySelectedTag = selectedTag
        reloadLibrary()
    }

    private func reloadLibrary() {
        do {
            recipes = try repository.fetchLibrary(
                searchText: librarySearchText,
                selectedTag: librarySelectedTag
            )
            var seenTags = Set<String>()
            allTags = try repository.fetchAll().flatMap(\.tags).filter {
                seenTags.insert($0.lowercased()).inserted
            }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            present(error)
        }
    }

    func recipe(id: UUID) -> Recipe? {
        do {
            return try repository.fetch(id: id)
        } catch {
            present(error)
            return nil
        }
    }

    func save(_ recipe: Recipe, isNew: Bool) throws {
        if isNew {
            try repository.create(recipe)
        } else {
            try repository.update(recipe)
        }
        reloadLibrary()
    }

    func beginCook(for recipeID: UUID) throws -> CookSession {
        try repository.beginCook(for: recipeID)
    }

    func updateCookPosition(sessionID: UUID, to stepIndex: Int) throws {
        try repository.updateCookPosition(sessionID: sessionID, to: stepIndex)
    }

    func endCook(sessionID: UUID, as status: CookSessionStatus) throws {
        try repository.endCook(sessionID: sessionID, as: status)
        reloadLibrary()
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
