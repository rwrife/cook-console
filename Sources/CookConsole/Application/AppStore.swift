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
    private var expiryWakeUp: Task<Void, Never>?
    private var expiryWakeUpRetryCount = 0
    private var alertDismissalGraceUntil = Date.distantPast

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
                            try RecipeStep(instruction: "Rest briefly.", timerDuration: 2),
                            try RecipeStep(instruction: "Serve promptly.", timerDuration: 6),
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
        scheduleExpiryWakeUp()
        reloadLibrary()
    }

    func loadTimers(cookSessionID: UUID) {
        visibleCookSessionID = cookSessionID
        reloadTimers()
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
            presentNextCompletionIfNeeded()
        } catch {
            present(error)
            // Keep the wake-up chain alive even when reconciliation failed;
            // retry on a short bounded cadence instead of strandling timers
            // until the next scene transition.
            scheduleExpiryWakeUp(delayOverride: 2)
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
            }
        } catch {
            present(error)
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
                self.presentNextCompletionIfNeeded()
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
            scheduleExpiryWakeUp()
            presentNextCompletionIfNeeded()
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
        } catch {
            present(error)
        }
    }
}
