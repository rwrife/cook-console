import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var allTags: [String] = []
    @Published private(set) var pantryOnHand: [PantryItem] = []
    @Published private(set) var pantryStaples: [PantryItem] = []
    @Published private(set) var pantrySuggestions: [RecipePantrySuggestion] = []
    @Published private(set) var timers: [CookTimer] = []
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .unknown
    @Published var completedTimerMessage: String?
    @Published var errorMessage: String?
    /// True while Cook Mode's fullScreenCover is mounted. The completion
    /// alert is attached at both the root and the cook surface, and exactly
    /// this flag decides which one may present: a root-level alert presented
    /// while the cook cover is up *replaces* the cover (SwiftUI displaces the
    /// modal instead of layering over it), dumping the user back on the
    /// detail page mid-cook. Gating the two copies on this flag keeps the
    /// alert on whichever surface is actually visible.
    @Published var isCookSurfaceActive = false
    /// Off by default. A setting, not a durable cooking state; ContentView
    /// separately scopes the actual UIKit idle override to foreground cooking.
    @Published private(set) var keepScreenAwakeWhileCooking: Bool
    @Published private(set) var idleTimerDisabled = false
    func applyIdleTimerPolicy(sceneIsActive: Bool) {
        let disabled = IdleTimerPolicy.shouldDisableIdleTimer(
            keepAwakeEnabled: keepScreenAwakeWhileCooking,
            cookSurfaceActive: isCookSurfaceActive,
            sceneActive: sceneIsActive
        )
        UIApplication.shared.isIdleTimerDisabled = disabled
        if idleTimerDisabled != disabled { idleTimerDisabled = disabled }
    }

    func setKeepScreenAwakeWhileCooking(_ enabled: Bool) {
        keepScreenAwakeWhileCooking = enabled
        UserDefaults.standard.set(enabled, forKey: "keepScreenAwakeWhileCooking")
    }

    /// Snapshot rendered by the persistent console surface (both layouts).
    /// Derived purely from recipes/sessions/timers already in this store.
    @Published private(set) var consoleSnapshot: ConsoleSnapshot = .idle
    /// Layout seam state: written ONLY from the SwiftUI layer's horizontal
    /// size class (ContentView's onAppear/onChange) — never from device
    /// model or any other topology assumption.
    @Published private(set) var consoleLayout: ConsoleLayout = .compactStrip

    private let repository: RecipeRepository
    private lazy var pantryRepository = PantryRepository(database: repository.database)
    /// The cook session the console surface currently mirrors, plus the
    /// recipe it belongs to. Set when a cook surface (re)loads its timers.
    private var consoleSession: CookSession?
    private var consoleRecipeID: UUID?
    private let timerEngine: TimerEngine?
    private let notificationService: LocalNotificationService?
    private var librarySearchText = ""
    private var librarySelectedTag: String?
    private var visibleCookSessionID: UUID?
    private var presentedCompletionID: UUID?
    private var expiryWakeUp: Task<Void, Never>?
    private var expiryWakeUpRetryCount = 0
    private var alertDismissalGraceUntil = Date.distantPast

    init(
        repository: RecipeRepository,
        timerEngine: TimerEngine? = nil,
        notificationService: LocalNotificationService? = nil
    ) {
        self.repository = repository
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            UserDefaults.standard.removeObject(forKey: "keepScreenAwakeWhileCooking")
        }
        keepScreenAwakeWhileCooking = UserDefaults.standard.bool(forKey: "keepScreenAwakeWhileCooking")
        self.timerEngine = timerEngine
        self.notificationService = notificationService
        notificationAuthorization = timerEngine?.notificationAuthorization ?? .unknown
        configureNotificationCallbacks()
        activateTimers()
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
            let database = try RecipeDatabase.make(at: databaseURL.path)
            let recipeRepository = RecipeRepository(database: database)
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-recovery-fixture") {
                    let fixture = try Recipe(
                        id: UUID(uuidString: "22000000-0000-0000-0000-000000000001")!,
                        title: "Recovery Fixture", servings: 1,
                        ingredients: [Ingredient(name: "Water", amount: 1, unit: .cup)],
                        steps: [RecipeStep(instruction: "Boil water.", timerDuration: 300)]
                    )
                    try recipeRepository.create(fixture)
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-short-timer-fixture") {
                    try recipeRepository.create(Recipe(
                        title: "Short Timer Fixture",
                        servings: 1,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 1, unit: .cup),
                        ],
                        steps: [
                            try RecipeStep(instruction: "Rest briefly.", timerDuration: 2),
                            try RecipeStep(instruction: "Serve promptly.", timerDuration: 6),
                        ]
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-staggered-timer-fixture") {
                    // Step 1 expires 20s after its start (comfortably after
                    // the UI has navigated to step 2). Step 2 expires 120s
                    // after its own start: run 35619636791 showed the hosted
                    // runner can need ~30s to even discover step 1's alert
                    // and up to ~45s more if OK taps are dropped, so the
                    // former 40s step let step 2's alert land INSIDE step
                    // 1's dismissal/retry windows. 120s puts step 2's
                    // expiry beyond any realistic step 1 acknowledgment
                    // path, keeping queue order deterministic.
                    try recipeRepository.create(Recipe(
                        title: "Staggered Timer Fixture",
                        servings: 1,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 1, unit: .cup),
                        ],
                        steps: [
                            try RecipeStep(instruction: "Boil first.", timerDuration: 20),
                            try RecipeStep(instruction: "Rest second.", timerDuration: 120),
                        ]
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-a11y-recipe-fixture") {
                    // Issue #7 and #23 accessibility fixture: a tagged recipe so the
                    // library row's spoken value (tags) and the detail
                    // servings readout can be asserted through AX labels
                    // and values, with long instructions and ingredients for
                    // accessibility size tests.
                    try recipeRepository.create(Recipe(
                        title: "A11y Soup",
                        servings: 4,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 2, unit: .cup),
                            try Ingredient(name: "Salt", amount: 1, unit: .teaspoon),
                        ],
                        steps: [
                            try RecipeStep(
                                instruction: "Bring soup to a simmer and continue simmering until the vegetables are tender.",
                                timerDuration: 600
                            ),
                            try RecipeStep(instruction: "Serve warm with fresh herbs and crusty bread."),
                        ],
                        tags: ["weeknight"]
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-pantry-fixture") {
                    try recipeRepository.create(Recipe(
                        title: "Simple Omelet",
                        servings: 2,
                        ingredients: [
                            try Ingredient(name: "Eggs", amount: 3, unit: .each),
                            try Ingredient(name: "Salt", amount: 0.25, unit: .teaspoon),
                        ],
                        steps: [try RecipeStep(instruction: "Whisk and cook.")]
                    ))
                    try recipeRepository.create(Recipe(
                        title: "Bean Salad",
                        servings: 2,
                        ingredients: [
                            try Ingredient(name: "Chickpeas", amount: 2, unit: .cup),
                            try Ingredient(name: "Fresh basil", amount: 1, unit: .cup),
                        ],
                        steps: [try RecipeStep(instruction: "Mix and serve.")]
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-review-fixture") {
                    // Issue #21: a LOCAL recipe that is deliberately NOT
                    // in the review pack — the board must show it as
                    // notInReviewPack and it accepts a kitchen-test
                    // observation (FK to recipes).
                    try recipeRepository.create(Recipe(
                        title: "Review Board Roast",
                        servings: 2,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 2, unit: .cup),
                        ],
                        steps: [
                            try RecipeStep(instruction: "Simmer the water until reduced by half.", timerDuration: 600),
                        ]
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-scaling-fixture") {
                    try recipeRepository.create(Recipe(
                        title: "Scaling Cake",
                        servings: 2,
                        ingredients: [
                            try Ingredient(name: "Flour", amount: 1.13, unit: .cup),
                            try Ingredient(name: "Eggs", amount: 3, unit: .each),
                        ],
                        steps: [
                            try RecipeStep(
                                instruction: "Bake until a tester comes out clean.",
                                timerDuration: 1_800
                            ),
                        ],
                        tags: ["baking"],
                        panSizeGuidance: "Use two prepared 8-inch pans.",
                        batchSizeGuidance: "Mix in two batches if the bowl is crowded.",
                        cookingTimeGuidance: "Keep the original bake time and test both pans."
                    ))
                }
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-grocery-fixture") {
                    // Issue #20: two recipes engineered to demonstrate every
                    // merge rule at once — shared cup-level oil (merges),
                    // shared grams (merges), a small spoon dose (stays in
                    // its own bucket), a countable-by-weight item (each ->
                    // grams), and a taste dose (never summed).
                    try recipeRepository.create(Recipe(
                        title: "Pasta Dinner",
                        servings: 2,
                        ingredients: [
                            try Ingredient(name: "Olive oil", amount: 0.5, unit: .cup),
                            try Ingredient(name: "Spinach", amount: 100, unit: .gram),
                            try Ingredient(name: "Soy sauce", amount: 2, unit: .tablespoon),
                            try Ingredient(name: "Cheese", amount: 2, unit: .each),
                            try Ingredient(name: "Salt", amount: 0.5, unit: .teaspoon),
                        ],
                        steps: [try RecipeStep(instruction: "Cook and serve.")]
                    ))
                    try recipeRepository.create(Recipe(
                        title: "Big Salad",
                        servings: 4,
                        ingredients: [
                            try Ingredient(name: "Olive oil", amount: 0.25, unit: .cup),
                            try Ingredient(name: "Spinach", amount: 200, unit: .gram),
                            try Ingredient(name: "Cheese", amount: 1, unit: .each),
                            try Ingredient(name: "Lemon juice to taste", amount: 1, unit: .teaspoon),
                        ],
                        steps: [try RecipeStep(instruction: "Toss and serve.")]
                    ))
                }
                let scheduler = NoopTimerNotificationScheduler()
                return AppStore(
                    repository: recipeRepository,
                    timerEngine: TimerEngine(
                        repository: TimerRepository(database: database),
                        notifications: scheduler
                    )
                )
            }
            let notifications = LocalNotificationService()
            return AppStore(
                repository: recipeRepository,
                timerEngine: TimerEngine(
                    repository: TimerRepository(database: database),
                    notifications: notifications
                ),
                notificationService: notifications
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

    func loadPantrySuggestions() {
        refreshPantrySuggestions()
    }

    func addPantryItem(name: String, kind: PantryItemKind) {
        do {
            _ = try pantryRepository.add(name: name, kind: kind)
            refreshPantrySuggestions()
        } catch {
            present(error)
        }
    }

    func removePantryItem(id: UUID) {
        do {
            _ = try pantryRepository.remove(id: id)
            refreshPantrySuggestions()
        } catch {
            present(error)
        }
    }

    // MARK: - Grocery list (issue #20)

    private lazy var groceryRepository = GroceryRepository(database: repository.database)

    @Published private(set) var grocerySelections: [GrocerySelection] = []
    @Published private(set) var groceryManualItems: [GroceryManualItem] = []
    /// The merged shopping sheet, recomputed from durable state after every
    /// grocery/library mutation and at launch. The view renders it directly,
    /// so the UI can never disagree with the pure engine.
    @Published private(set) var grocerySnapshot = GroceryListSnapshot(
        manualLines: [],
        recipeLines: []
    )

    func loadGroceryList() {
        reloadGrocery()
    }

    // MARK: - Recipe review board (issue #21)

    private lazy var reviewRepository = RecipeReviewRepository(database: repository.database)

    /// Desk-review status + exceptions render live from the curated pack
    /// bundled with the app source, so they can never drift from the
    /// content being reviewed. The database stores ONLY physical kitchen
    /// observations (the durable user-visible evidence); desk fields in
    /// the DB would duplicate pack truth and go stale.
    @Published private(set) var reviewPack: RecipeReviewPack?
    @Published private(set) var reviewRecords: [RecipeReviewRecord] = []
    @Published private(set) var reviewBoardRows: [RecipeReviewBoardRow] = []
    private var reviewMetadataAdopted = false

    /// One-time (and refresh-safe) adoption of curated pack metadata.
    func loadRecipeReviews() {
        do {
            if !reviewMetadataAdopted {
                reviewPack = try Self.loadBundledReviewPack()
                let packRecords = try reviewPack.map { pack in
                    try pack.recipes.map { try $0.makeReviewRecord() }
                } ?? []
                try reviewRepository.adoptPackMetadata(packRecords)
                reviewMetadataAdopted = true
            }
            reviewRecords = try reviewRepository.fetchAll()
            if reviewPack == nil {
                reviewPack = try? Self.loadBundledReviewPack()
            }
            refreshReviewBoardRows()
        } catch {
            present(error)
        }
    }

    func recordKitchenTestObservation(_ observation: KitchenTestObservation, recipeID: UUID) {
        do {
            try reviewRepository.addObservation(observation, recipeID: recipeID)
            reviewRecords = try reviewRepository.fetchAll()
            refreshReviewBoardRows()
        } catch {
            present(error)
        }
    }

    /// Live board rows. The FULL library, never the search-filtered
    /// `recipes` view — coverage gaps must survive search state (#20
    /// lesson).
    private func refreshReviewBoardRows() {
        do {
            reviewBoardRows = RecipeReviewBoardRow.build(
                pack: reviewPack,
                records: reviewRecords,
                recipes: try repository.fetchAll()
            )
        } catch {
            present(error)
        }
    }

    /// Gap report merged across the pack (desk truth, priorities) and the
    /// database (durable physical evidence) — never pack-only, so a
    /// recorded kitchen test immediately leaves the queue.
    var reviewGapSummary: KitchenTestGapSummary? {
        guard let reviewPack else { return nil }
        return KitchenTestGapSummary(packVersion: reviewPack.packVersion, rows: reviewBoardRows)
    }

    private static func loadBundledReviewPack() throws -> RecipeReviewPack {
        let filename = "RecipeReviewPack.starter-seed-v1"
        guard let url = Bundle.main.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "ReviewPack"
        ) ?? Bundle.main.url(forResource: filename, withExtension: "json") else {
            throw RecipeReviewRepositoryError.invalidData("Review pack '\(filename).json' is missing from the bundle")
        }
        return try RecipeReviewPack.load(from: url)
    }

    func addGrocerySelection(recipeID: UUID) {
        do {
            // Default servings = the recipe's own yield (or 1 when the
            // recipe vanished mid-race; the FK would reject it anyway).
            let servings = recipe(id: recipeID)?.servings ?? 1
            _ = try groceryRepository.addSelection(recipeID: recipeID, servings: servings)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    func updateGrocerySelectionServings(id: UUID, servings: Double) {
        do {
            try groceryRepository.updateServings(selectionID: id, servings: servings)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    /// Check/uncheck a whole selection: the flag lands on every merge-key
    /// the recipe contributes (per-key storage — see GroceryRepository).
    func setGrocerySelectionChecked(id: UUID, isChecked: Bool) {
        do {
            guard let selection = grocerySelections.first(where: { $0.id == id }),
                  let recipe = recipe(id: selection.recipeID) else { return }
            for key in GroceryAggregationEngine.contributedKeys(for: recipe) {
                try groceryRepository.setChecked(selectionID: id, ingredientKey: key, isChecked: isChecked)
            }
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    /// Check/uncheck a merged recipe line: the flag fans out to exactly the
    /// selections contributing to that name key.
    func setGroceryRecipeLineChecked(key: String, isChecked: Bool) {
        do {
            let contributing = GroceryAggregationEngine.checkedSelectionIDs(
                forLineKey: key,
                selections: grocerySelections,
                recipes: try repository.fetchAll()
            )
            try groceryRepository.setChecked(selectionIDs: contributing, ingredientKey: key, isChecked: isChecked)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    func removeGrocerySelection(id: UUID) {
        do {
            _ = try groceryRepository.removeSelection(id: id)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    func addGroceryManualItem(name: String) {
        do {
            // Free-text smart parse ("2 cans tomatoes", "salt to taste")
            // keeps the manual entry forgiving while storage stays simple:
            // the parsed quantity renders into the durable name.
            let parsed = GroceryAggregationEngine.parseManualEntry(name)
            var durableName = parsed?.name ?? name
            if let parsed, let amount = parsed.amount, let unit = parsed.unit {
                durableName = "\(KitchenQuantityFormatter.string(amount)) \(unit.symbol) \(parsed.name)"
            } else if parsed?.isTasteDosed == true, !durableName.lowercased().contains("to taste") {
                durableName += " (to taste)"
            }
            _ = try groceryRepository.addManualItem(name: durableName)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    func setGroceryManualItemChecked(id: UUID, isChecked: Bool) {
        do {
            try groceryRepository.setManualItemChecked(id: id, isChecked: isChecked)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    func removeGroceryManualItem(id: UUID) {
        do {
            _ = try groceryRepository.removeManualItem(id: id)
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    /// "Done shopping": checked manual items are bought and leave the list;
    /// every selection unchecks for the next trip.
    func doneShopping() {
        do {
            try groceryRepository.removeCheckedManualItems()
            try groceryRepository.uncheckAllManualItems()
            try groceryRepository.uncheckAllSelections()
            reloadGrocery()
        } catch {
            present(error)
        }
    }

    /// Grocery list as shareable plain text (provenance + qualifiers kept).
    func exportedGroceryListURL() throws -> URL {
        let directory = try Self.exportDirectory()
        let url = directory.appendingPathComponent(
            "grocery-list-\(Self.exportStampFormatter.string(from: Date())).txt"
        )
        try GroceryListFormatter.plainText(grocerySnapshot).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func reloadGrocery() {
        do {
            grocerySelections = try groceryRepository.fetchSelections()
            groceryManualItems = try groceryRepository.fetchManualItems()
            // The FULL library, never `recipes` — that published list is the
            // search/tag-filtered view, and a filtered subset would make
            // shopping lines vanish just because the user typed in Search.
            grocerySnapshot = GroceryAggregationEngine.aggregate(
                selections: grocerySelections,
                manualItems: groceryManualItems,
                recipes: try repository.fetchAll()
            )
        } catch {
            present(error)
        }
    }

    // MARK: - Data ownership (issue #6)

    private lazy var dataTransfer = DataTransferService(database: repository.database)

    /// Writes a versioned JSON backup into the app's temporary Exports
    /// directory and returns it for the share sheet. Local file write only.
    func exportedJSONBackupURL() throws -> URL {
        let directory = try Self.exportDirectory()
        let stamp = Self.exportStampFormatter.string(from: Date())
        let url = directory.appendingPathComponent("CookConsole-backup-\(stamp).json")
        try dataTransfer.writeJSONBackup(to: url)
        return url
    }

    /// Writes a cook-history CSV into the app's temporary Exports directory
    /// and returns it for the share sheet. Local file write only.
    func exportedHistoryCSVURL() throws -> URL {
        let directory = try Self.exportDirectory()
        let stamp = Self.exportStampFormatter.string(from: Date())
        let url = directory.appendingPathComponent("CookConsole-history-\(stamp).csv")
        try dataTransfer.writeHistoryCSV(to: url)
        return url
    }

    /// Validates and merges one JSON backup file (all-or-nothing) and shows
    /// the user-visible conflict summary. Throws the per-item validation
    /// error to the caller without touching the store on failure.
    @discardableResult
    func importJSONBackup(from url: URL) throws -> JSONImportOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let document = try dataTransfer.validateDocument(at: url)
        let outcome = try dataTransfer.applyValidated(document)
        refreshAfterRecovery()
        importSummary = outcome.summaryText
        return outcome
    }

    /// Local deterministic UI fixture exercises the production preview/apply path.
    func recoveryFixturePreview() throws -> JSONImportPreview {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-reset"),
              ProcessInfo.processInfo.arguments.contains("-ui-testing-recovery-fixture") else {
            throw DataTransferError.malformed("Recovery fixture is unavailable.")
        }
        var document = try dataTransfer.exportDocument()
        guard let index = document.recipes.firstIndex(where: { $0.id.uuidString == "22000000-0000-0000-0000-000000000001" }) else {
            throw DataTransferError.malformed("Recovery fixture is missing.")
        }
        document.recipes[index].title = "Recovered Fixture"
        // Serialize and validate like a picked file: preview is bound to that document.
        let url = try Self.exportDirectory().appendingPathComponent("recovery-fixture.json")
        try dataTransfer.encodedData(for: document).write(to: url, options: .atomic)
        return try previewJSONBackup(from: url)
    }

    func previewJSONBackup(from url: URL) throws -> JSONImportPreview {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try dataTransfer.preview(dataTransfer.validateDocument(at: url))
    }

    func applyJSONPreview(_ preview: JSONImportPreview) throws {
        let outcome = try dataTransfer.apply(preview)
        refreshAfterRecovery()
        importSummary = outcome.summaryText
    }

    var lastConfirmedBackup: Date? { try? dataTransfer.lastConfirmedBackup() }
    func confirmBackupSaved() throws { try dataTransfer.confirmBackupSaved() }
    func archivedRecipes() throws -> [Recipe] { try repository.fetchArchived() }
    func restoreRecipe(id: UUID) throws {
        try repository.restore(id: id)
        reloadLibrary()
    }
    func purgeRecipe(id: UUID) throws { try repository.purge(id: id) }
    func archiveRecipe(id: UUID) throws {
        _ = try repository.delete(id: id)
        refreshAfterRecovery()
    }

    private func refreshAfterRecovery() {
        reloadLibrary()
        reloadGrocery()
        do { try timerEngine?.synchronizeNotifications() }
        catch { errorMessage = "Data updated, but timer notification refresh failed: \(error.localizedDescription)" }
        if let session = consoleSession {
            do {
                let persisted = try repository.fetchCookSession(id: session.id)
                if let persisted, persisted.status == .active,
                   try repository.fetch(id: persisted.recipeID) != nil {
                    // Import may clamp the durable position without ending the cook.
                    // The console must render the persisted session, not its old mirror.
                    consoleSession = persisted
                } else {
                    consoleSession = nil
                    consoleRecipeID = nil
                    visibleCookSessionID = nil
                    timers = []
                }
            } catch {
                errorMessage = "Data updated, but cook session refresh failed: \(error.localizedDescription)"
            }
        }
        if let presentedCompletionID,
           let pending = try? timerEngine?.pendingCompletions(),
           !pending.contains(where: { $0.id == presentedCompletionID }) {
            self.presentedCompletionID = nil
            completedTimerMessage = nil
        }
        reloadTimers()
        refreshConsoleSnapshot()
        scheduleExpiryWakeUp()
    }

    /// Last applied import summary, shown on the "Your data" screen.
    @Published var importSummary: String?

    private static func exportDirectory() throws -> URL {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("CookConsole-Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let exportStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

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
            refreshPantrySuggestions()
        } catch {
            present(error)
        }
    }

    private func refreshPantrySuggestions() {
        do {
            try pantryRepository.seedDefaultStaplesIfNeeded()
            let onHand = try pantryRepository.fetch(kind: .onHand)
            let staples = try pantryRepository.fetch(kind: .staple)
            pantryOnHand = onHand
            pantryStaples = staples
            let allRecipes = try repository.fetchAll()
            pantrySuggestions = PantrySuggestionEngine.rank(
                recipes: allRecipes,
                pantryNames: onHand.map(\.name),
                stapleNames: staples.map(\.name)
            )
        } catch {
            present(error)
        }
    }

    func personalNotes(for recipeID: UUID) -> PersonalRecipeNotes? {
        do { return try repository.personalNotes(for: recipeID) }
        catch { present(error); return nil }
    }

    func savePersonalNotes(_ notes: PersonalRecipeNotes) throws {
        try repository.savePersonalNotes(notes)
    }

    func cookingSummary(for recipeID: UUID) -> RecipeCookingSummary? {
        do { return RecipeCookingSummary(sessions: try repository.fetchCookSessions(for: recipeID)) }
        catch { present(error); return nil }
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
        let session = try repository.beginCook(for: recipeID)
        // A cook surface is about to mount for this session; adopt it as the
        // console mirror immediately so the strip can appear without waiting
        // for the surface's onAppear.
        consoleSession = session
        consoleRecipeID = recipeID
        refreshConsoleSnapshot()
        return session
    }

    func updateCookPosition(sessionID: UUID, to stepIndex: Int) throws {
        try repository.updateCookPosition(sessionID: sessionID, to: stepIndex)
        if let consoleSession, consoleSession.id == sessionID {
            // CookSession is a validated immutable value; replace it whole.
            self.consoleSession = CookSession(
                id: consoleSession.id,
                recipeID: consoleSession.recipeID,
                startedAt: consoleSession.startedAt,
                endedAt: consoleSession.endedAt,
                status: consoleSession.status,
                currentStepIndex: stepIndex
            )
            refreshConsoleSnapshot()
        }
    }

    /// Applies the horizontal-size-class-derived layout input. This is the
    /// only writer of `consoleLayout`; keeping it a total function of
    /// `ConsoleLayoutInput` is what makes the Duo migration a pure
    /// source-of-input swap (docs/dual-screen-migration.md).
    func applyConsoleLayout(input: ConsoleLayoutInput) {
        let next = ConsoleLayout(input: input)
        if next != consoleLayout {
            consoleLayout = next
        }
    }

    func endCook(sessionID: UUID, as status: CookSessionStatus) throws {
        if let timerEngine {
            _ = try timerEngine.endCookSession(sessionID: sessionID, as: status)
        } else {
            try repository.endCook(sessionID: sessionID, as: status)
        }
        if visibleCookSessionID == sessionID {
            visibleCookSessionID = nil
            timers = []
        }
        if consoleSession?.id == sessionID {
            consoleSession = nil
            consoleRecipeID = nil
        }
        refreshConsoleSnapshot()
        scheduleExpiryWakeUp()
        reloadLibrary()
    }

    func loadTimers(cookSessionID: UUID) {
        visibleCookSessionID = cookSessionID
        reloadTimers()
        // (Re)adopt the console mirror from the durable session row, then
        // refresh the wall. This is also the fold/unfold re-sync path: a new
        // cook surface instance calling loadTimers re-reads the persisted
        // step position, so console state survives view-tree replacement.
        consoleSession = try? repository.fetchCookSession(id: cookSessionID)
        consoleRecipeID = consoleSession?.recipeID
        refreshConsoleSnapshot()
        scheduleExpiryWakeUp()
    }

    func startTimer(
        recipeID: UUID,
        step: RecipeStep,
        stepNumber: Int,
        cookSessionID: UUID
    ) throws {
        guard let duration = step.timerDuration else { throw TimerEngineError.invalidDuration }
        notificationService?.requestAuthorization()
        guard let timerEngine else { throw TimerEngineError.invalidTransition }
        _ = try timerEngine.start(
            recipeID: recipeID,
            stepID: step.id,
            cookSessionID: cookSessionID,
            stepName: "Step \(stepNumber): \(step.instruction)",
            duration: duration
        )
        visibleCookSessionID = cookSessionID
        notificationAuthorization = timerEngine.notificationAuthorization
        reloadTimers()
        scheduleExpiryWakeUp()
    }

    func pauseTimer(id: UUID) { performTimerAction { try $0.pause(timerID: id) } }
    func resumeTimer(id: UUID) { performTimerAction { try $0.resume(timerID: id) } }
    func cancelTimer(id: UUID) { performTimerAction { try $0.cancel(timerID: id) } }
    func extendTimer(id: UUID, seconds: TimeInterval) {
        performTimerAction { try $0.extend(timerID: id, by: seconds) }
    }

    func reconcileTimers() {
        do {
            guard let timerEngine else { return }
            _ = try timerEngine.reconcileExpiredTimers()
            applyAuthorization(from: timerEngine)
            reloadTimers()
            scheduleExpiryWakeUp()
            // Present completion alerts on a following main-actor turn.
            // Reconciliation mutates `timers` in the same frame the alert
            // would appear (active tile vanishes as the status flips), and
            // SwiftUI drops alert presentations that race a presenting
            // view's own update transaction — the binding stays true while
            // the alert never shows. A one-turn delay lets the data update
            // commit first; the durable queue makes late presentation safe.
            presentNextCompletionSoon()
        } catch {
            present(error)
            // Keep the wake-up chain alive even when reconciliation failed;
            // retry on a short bounded cadence instead of strandling timers
            // until the next scene transition.
            scheduleExpiryWakeUp(delayOverride: 2)
        }
    }

    /// All queue presentation goes through a following main-actor turn so a
    /// message change never shares an update transaction with timer/library
    /// mutations (or the presenting view's own render). SwiftUI can drop an
    /// alert presentation that races such a transaction, leaving the binding
    /// stuck true with no visible alert; the durable queue makes delayed
    /// presentation safe.
    private func presentNextCompletionSoon() {
        Task { @MainActor [weak self] in
            self?.presentNextCompletionIfNeeded()
        }
    }

    /// Acknowledges exactly one presented completion through the alert's OK
    /// action. Guarded by `presentedCompletionID` and cleared up front, so
    /// repeated invocations from any alert dismissal path acknowledge at most
    /// one timer. Advancing to the next queued completion deliberately does
    /// not happen here: SwiftUI's dismissal signal arrives via
    /// `completionAlertDismissed()` after the alert is gone, and presenting
    /// there (deferred past the dismissal animation) prevents both the old
    /// double-acknowledgment race and a new alert being swallowed by the
    /// still-in-flight dismissal window.
    func acknowledgePresentedCompletion() {
        guard let presentedCompletionID else { return }
        self.presentedCompletionID = nil
        completedTimerMessage = nil
        do {
            try timerEngine?.acknowledgeCompletion(timerID: presentedCompletionID)
        } catch {
            present(error)
        }
    }

    /// Called when SwiftUI writes `false` to the completion alert binding —
    /// i.e. the alert has actually gone away, whether via OK or a swipe.
    /// A swipe-away without OK keeps the durable queue row and only clears
    /// the presentation; a later pass re-presents it. The queue is advanced
    /// after a short delay, and presentations are suppressed during that
    /// grace window, so a new alert never competes with the dismissal
    /// animation of the current one — neither from this path nor from a
    /// concurrent reconciliation pass.
    func completionAlertDismissed() {
        if completedTimerMessage != nil {
            presentedCompletionID = nil
            completedTimerMessage = nil
        }
        alertDismissalGraceUntil = Date().addingTimeInterval(0.4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.presentNextCompletionIfNeeded(force: true)
        }
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func performTimerAction(_ action: (TimerEngine) throws -> CookTimer) {
        do {
            guard let timerEngine else { throw TimerEngineError.invalidTransition }
            _ = try action(timerEngine)
            reloadTimers()
            scheduleExpiryWakeUp()
        } catch {
            present(error)
        }
    }

    private func reloadTimers() {
        do {
            guard let timerEngine, let visibleCookSessionID else { return }
            let next = try timerEngine.timers(cookSessionID: visibleCookSessionID)
            if next != timers {
                timers = next
                refreshConsoleSnapshot()
            }
        } catch {
            present(error)
        }
    }

    /// Recomputes the console wall snapshot from state already held by this
    /// store. Conditional write: the compact strip is mounted via
    /// safeAreaInset on views that observe AppStore, so an unconditional
    /// publish would re-render the library list on every timer tick.
    private func refreshConsoleSnapshot() {
        let recipe = consoleRecipeID.flatMap { id in try? repository.fetch(id: id) }
        let snapshot = ConsoleSnapshot.snapshot(
            recipe: recipe,
            session: consoleSession,
            timers: timers
        )
        if snapshot != consoleSnapshot {
            consoleSnapshot = snapshot
        }
    }

    /// Wakes the app exactly once at the earliest running deadline instead of
    /// polling every second. A periodic root timer kept the app permanently
    /// non-idle for XCTest waits and invalidated the view tree every second,
    /// which dismissed in-flight alerts and broke menu presentation in
    /// simulator UI runs. Countdown text is rendered by each tile's own
    /// TimelineView, so nothing needs a root-level tick. The chain is
    /// self-healing: a reconcile failure re-arms a short bounded retry so a
    /// transient database error can never permanently strand the only wake-up.
    private func scheduleExpiryWakeUp(delayOverride: TimeInterval? = nil) {
        expiryWakeUp?.cancel()
        expiryWakeUp = nil
        do {
            guard let timerEngine else { return }
            let deadline = try timerEngine.nextExpiryDate()
            // A successful lookup proves the chain is healthy again, so the
            // bounded retry budget resets on every success, not only when no
            // deadlines remain.
            expiryWakeUpRetryCount = 0
            guard let deadline else { return }
            let delay = delayOverride ?? max(0.2, deadline.timeIntervalSinceNow + 0.2)
            expiryWakeUp = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.reconcileTimers()
            }
        } catch {
            present(error)
            guard expiryWakeUpRetryCount < 5 else { return }
            expiryWakeUpRetryCount += 1
            expiryWakeUp = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.scheduleExpiryWakeUp()
            }
        }
    }

    private func applyAuthorization(from timerEngine: TimerEngine) {
        let state = timerEngine.notificationAuthorization
        if state != notificationAuthorization {
            notificationAuthorization = state
        }
    }

    private func configureNotificationCallbacks() {
        timerEngine?.onNotificationSchedulingFailure = { [weak self] _, message in
            Task { @MainActor in
                guard let self, let timerEngine = self.timerEngine else { return }
                // A denied permission state explains itself through the
                // persistent fallback banner. Only surface a modal error when
                // permission was granted and the OS still rejected the
                // request; otherwise this alert collides with the completion
                // alert during the same presentation window.
                guard timerEngine.notificationAuthorization == .allowed else { return }
                self.errorMessage = "The timer is still running, but its notification could not be scheduled: \(message) Keep Cook Console open for an on-screen alert."
            }
        }
        notificationService?.onAuthorizationChange = { [weak self] state in
            self?.notificationAuthorization = state
            self?.activateTimers()
        }
        notificationService?.onAction = { [weak self] identifier, timerID in
            guard let self, let timerEngine = self.timerEngine else { return }
            do {
                _ = try timerEngine.handleNotificationAction(identifier: identifier, timerID: timerID)
                if self.presentedCompletionID == timerID {
                    self.presentedCompletionID = nil
                    self.completedTimerMessage = nil
                }
                self.reloadTimers()
                self.scheduleExpiryWakeUp()
                self.presentNextCompletionSoon()
            } catch {
                self.present(error)
            }
        }
        notificationService?.onForegroundDelivery = { [weak self] timerID, scheduleGeneration in
            guard let self, let timerEngine = self.timerEngine else { return }
            do {
                _ = try timerEngine.completeIfDelivered(timerID: timerID, scheduleGeneration: scheduleGeneration)
                self.reloadTimers()
                self.scheduleExpiryWakeUp()
                self.presentNextCompletionSoon()
            } catch {
                self.present(error)
            }
        }
        notificationService?.refreshAuthorization()
    }

    private func activateTimers() {
        do {
            guard let timerEngine else { return }
            _ = try timerEngine.reconcileExpiredTimers()
            try timerEngine.synchronizeNotifications()
            notificationAuthorization = timerEngine.notificationAuthorization
            reloadTimers()
            scheduleExpiryWakeUp()
            presentNextCompletionSoon()
        } catch {
            present(error)
            // A synchronize failure must not leave the app with no wake-up
            // chain at all — re-arm a short retry so expiry handling is
            // restored without waiting for a scene transition.
            scheduleExpiryWakeUp(delayOverride: 2)
        }
    }

    private func presentNextCompletionIfNeeded(force: Bool = false) {
        guard completedTimerMessage == nil, let timerEngine else { return }
        // While an alert dismissal animation may still be in flight, only
        // the dismissal-driven advance may present. Reconciliation passes
        // that fire during the window would otherwise publish the next
        // message while UIKit is still tearing the old alert down, and the
        // resulting presentation can be silently swallowed.
        guard force || Date() >= alertDismissalGraceUntil else { return }
        do {
            guard let timer = try timerEngine.pendingCompletions().first else { return }
            presentedCompletionID = timer.id
            completedTimerMessage = "\(timer.stepName) timer finished."
            // Issue #7: tactile confirmation the moment the completion
            // alert's message becomes live (both alert surfaces present
            // from here, so this is the single choke point). UIKit's
            // feedback generators honor the system "System Haptics"
            // toggle — no app-side setting needed.
            CookHaptics.timerFinished()
        } catch {
            present(error)
        }
    }
}
