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
    /// True while Cook Mode's fullScreenCover is mounted. The completion
    /// alert is attached at both the root and the cook surface, and exactly
    /// this flag decides which one may present: a root-level alert presented
    /// while the cook cover is up *replaces* the cover (SwiftUI displaces the
    /// modal instead of layering over it), dumping the user back on the
    /// detail page mid-cook. Gating the two copies on this flag keeps the
    /// alert on whichever surface is actually visible.
    @Published var isCookSurfaceActive = false
    /// Snapshot rendered by the persistent console surface (both layouts).
    /// Derived purely from recipes/sessions/timers already in this store.
    @Published private(set) var consoleSnapshot: ConsoleSnapshot = .idle
    /// Layout seam state: written ONLY from the SwiftUI layer's horizontal
    /// size class (ContentView's onAppear/onChange) — never from device
    /// model or any other topology assumption.
    @Published private(set) var consoleLayout: ConsoleLayout = .compactStrip

    private let repository: RecipeRepository
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
                    // Issue #7 narration fixture: a tagged recipe so the
                    // library row's spoken value (tags) and the detail
                    // servings readout can be asserted through AX labels
                    // and values.
                    try recipeRepository.create(Recipe(
                        title: "A11y Soup",
                        servings: 4,
                        ingredients: [
                            try Ingredient(name: "Water", amount: 2, unit: .cup),
                        ],
                        steps: [
                            try RecipeStep(instruction: "Simmer gently.", timerDuration: 600),
                        ],
                        tags: ["weeknight"]
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
        reloadLibrary()
        importSummary = outcome.summaryText
        return outcome
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
