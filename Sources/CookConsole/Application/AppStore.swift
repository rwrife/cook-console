import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var allTags: [String] = []
    @Published private(set) var timers: [CookTimer] = []
    @Published private(set) var notificationAuthorization: NotificationAuthorization = .unknown
    @Published var completedTimerMessage: String?
    @Published var errorMessage: String?

    private let repository: RecipeRepository
    private let timerEngine: TimerEngine?
    private let notificationService: LocalNotificationService?
    private var librarySearchText = ""
    private var librarySelectedTag: String?
    private var visibleCookSessionID: UUID?
    private var presentedCompletionID: UUID?

    init(
        repository: RecipeRepository,
        timerEngine: TimerEngine? = nil,
        notificationService: LocalNotificationService? = nil
    ) {
        self.repository = repository
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
                if ProcessInfo.processInfo.arguments.contains("-ui-testing-short-timer-fixture") {
                    try recipeRepository.create(Recipe(
                        title: "Short Timer Fixture",
                        servings: 1,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 1, unit: .cup),
                        ],
                        steps: [
                            try RecipeStep(instruction: "Rest briefly.", timerDuration: 1),
                        ]
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
        if let timerEngine {
            _ = try timerEngine.endCookSession(sessionID: sessionID, as: status)
        } else {
            try repository.endCook(sessionID: sessionID, as: status)
        }
        if visibleCookSessionID == sessionID {
            visibleCookSessionID = nil
            timers = []
        }
        reloadLibrary()
    }

    func loadTimers(cookSessionID: UUID) {
        visibleCookSessionID = cookSessionID
        reloadTimers()
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
            notificationAuthorization = timerEngine.notificationAuthorization
            reloadTimers()
            presentNextCompletionIfNeeded()
        } catch {
            present(error)
        }
    }

    func acknowledgePresentedCompletion() {
        do {
            if let presentedCompletionID {
                try timerEngine?.acknowledgeCompletion(timerID: presentedCompletionID)
            }
            self.presentedCompletionID = nil
            completedTimerMessage = nil
            presentNextCompletionIfNeeded()
        } catch {
            present(error)
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
        } catch {
            present(error)
        }
    }

    private func reloadTimers() {
        do {
            guard let timerEngine, let visibleCookSessionID else { return }
            timers = try timerEngine.timers(cookSessionID: visibleCookSessionID)
        } catch {
            present(error)
        }
    }

    private func configureNotificationCallbacks() {
        timerEngine?.onNotificationSchedulingFailure = { [weak self] _, message in
            Task { @MainActor in
                self?.errorMessage = "The timer is still running, but its notification could not be scheduled: \(message) Keep Cook Console open for an on-screen alert."
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
                self.presentNextCompletionIfNeeded()
            } catch {
                self.present(error)
            }
        }
        notificationService?.onForegroundDelivery = { [weak self] timerID in
            guard let self, let timerEngine = self.timerEngine else { return }
            do {
                _ = try timerEngine.complete(timerID: timerID)
                self.reloadTimers()
                self.presentNextCompletionIfNeeded()
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
            presentNextCompletionIfNeeded()
        } catch {
            present(error)
        }
    }

    private func presentNextCompletionIfNeeded() {
        guard completedTimerMessage == nil, let timerEngine else { return }
        do {
            guard let timer = try timerEngine.pendingCompletions().first else { return }
            presentedCompletionID = timer.id
            completedTimerMessage = "\(timer.stepName) timer finished."
        } catch {
            present(error)
        }
    }
}
