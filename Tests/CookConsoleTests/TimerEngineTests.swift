import XCTest
import GRDB

@testable import CookConsole

final class TimerEngineTests: XCTestCase {
    func testStartPersistsIdentitiesDeadlineAndStartedLogAndSchedulesNotification() throws {
        let fixture = try TimerFixture(now: 1_000)

        let timer = try fixture.engine.start(
            recipeID: fixture.recipe.id,
            stepID: fixture.recipe.steps[0].id,
            cookSessionID: fixture.session.id,
            stepName: "Simmer gently",
            duration: 120
        )

        XCTAssertEqual(timer.recipeID, fixture.recipe.id)
        XCTAssertEqual(timer.stepID, fixture.recipe.steps[0].id)
        XCTAssertEqual(timer.cookSessionID, fixture.session.id)
        XCTAssertEqual(timer.deadline, Date(timeIntervalSince1970: 1_120))
        XCTAssertEqual(try fixture.repository.fetchTimers(), [timer])
        XCTAssertEqual(try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind), [.started])
        XCTAssertEqual(fixture.notifications.scheduled.map(\.timerID), [timer.id])
    }

    func testStartRejectsMismatchedRecipeStepAndSessionIdentities() throws {
        let fixture = try TimerFixture(now: 1_500)

        XCTAssertThrowsError(
            try fixture.engine.start(
                recipeID: fixture.recipe.id,
                stepID: UUID(),
                cookSessionID: fixture.session.id,
                stepName: "Not this recipe step",
                duration: 60
            )
        ) { error in
            XCTAssertEqual(error as? TimerEngineError, .invalidIdentity)
        }
        XCTAssertTrue(try fixture.repository.fetchTimers().isEmpty)
    }

    func testActiveTimerRetainsHistoricalStepIdentityAndTextAfterRecipeEdit() throws {
        let fixture = try TimerFixture(now: 1_600)
        let timer = try fixture.start(stepName: "Step 1: Simmer gently", duration: 60)
        let replacementStep = try RecipeStep(instruction: "Serve immediately")
        let edited = try Recipe(
            id: fixture.recipe.id,
            title: fixture.recipe.title,
            servings: fixture.recipe.servings,
            ingredients: fixture.recipe.ingredients,
            steps: [replacementStep],
            tags: fixture.recipe.tags,
            isFavorite: fixture.recipe.isFavorite
        )

        try RecipeRepository(database: fixture.database).update(edited)

        let retained = try XCTUnwrap(fixture.repository.fetchTimer(id: timer.id))
        XCTAssertEqual(retained.stepID, fixture.recipe.steps[0].id)
        XCTAssertNotEqual(retained.stepID, replacementStep.id)
        XCTAssertEqual(retained.stepName, "Step 1: Simmer gently")
        XCTAssertEqual(retained.status, .running)
    }

    func testDatabaseRejectsPausedTimerWithZeroRemainder() throws {
        let fixture = try TimerFixture(now: 1_700)
        let timer = try fixture.start(stepName: "Simmer", duration: 60)

        XCTAssertThrowsError(try fixture.database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_timers
                    SET status = 'paused', deadline = NULL, remaining_when_paused = 0
                    WHERE id = ?
                    """,
                arguments: [timer.id.uuidString]
            )
        })
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .running)
    }

    func testConcurrentTimersPauseResumeExtendAndCancelIndependently() throws {
        let fixture = try TimerFixture(now: 2_000)
        let first = try fixture.start(stepName: "First", duration: 60)
        let second = try fixture.start(stepName: "Second", duration: 90)
        fixture.nowBox.date = Date(timeIntervalSince1970: 2_010)

        let paused = try fixture.engine.pause(timerID: first.id)
        let extended = try fixture.engine.extend(timerID: second.id, by: 300)
        fixture.nowBox.date = Date(timeIntervalSince1970: 2_030)
        let resumed = try fixture.engine.resume(timerID: first.id)
        let cancelled = try fixture.engine.cancel(timerID: second.id)

        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.remainingWhenPaused, 50)
        XCTAssertEqual(resumed.deadline, Date(timeIntervalSince1970: 2_080))
        XCTAssertEqual(extended.deadline, Date(timeIntervalSince1970: 2_390))
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(fixture.notifications.scheduled.map(\.timerID), [first.id])
        XCTAssertEqual(fixture.notifications.allRemoved, [first.id, second.id])
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: second.id).map(\.kind),
            [.started, .extended]
        )
        XCTAssertEqual(try fixture.repository.fetchEvents(timerID: second.id).last?.seconds, 300)
    }

    func testLaunchReconciliationCompletesOverdueTimerAndLogsFiredOnlyOnce() throws {
        let fixture = try TimerFixture(now: 3_000)
        let timer = try fixture.start(stepName: "Bake", duration: 30)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_031)
        let firstReloadNotifications = FakeNotificationScheduler()

        let firstReload = TimerEngine(
            repository: TimerRepository(database: fixture.database),
            notifications: firstReloadNotifications,
            now: { [nowBox = fixture.nowBox] in nowBox.date }
        )
        XCTAssertEqual(try firstReload.reconcileExpiredTimers().map(\.id), [timer.id])
        let secondReload = TimerEngine(
            repository: TimerRepository(database: fixture.database),
            notifications: FakeNotificationScheduler(),
            now: { [nowBox = fixture.nowBox] in nowBox.date }
        )
        XCTAssertTrue(try secondReload.reconcileExpiredTimers().isEmpty)

        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .completed)
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired]
        )
        XCTAssertEqual(firstReloadNotifications.pendingRemoved, [timer.id])
        XCTAssertTrue(firstReloadNotifications.allRemoved.isEmpty)
        XCTAssertEqual(try secondReload.pendingCompletions().map(\.id), [timer.id])
    }

    func testDatabaseReopenRestoresFutureDeadlineAndForegroundReconcileCompletesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cook-console-timer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recipes.sqlite").path
        let nowBox = NowBox(4_000)
        let identities: (timer: UUID, session: UUID) = try {
            let database = try RecipeDatabase.make(at: path)
            let recipe = try Recipe(
                title: "Rice",
                servings: 2,
                ingredients: [try Ingredient(name: "Rice", amount: 1, unit: .cup)],
                steps: [try RecipeStep(instruction: "Steam", timerDuration: 60)]
            )
            let recipes = RecipeRepository(database: database)
            try recipes.create(recipe)
            let session = try recipes.beginCook(for: recipe.id, at: nowBox.date)
            let engine = TimerEngine(
                repository: TimerRepository(database: database),
                notifications: FakeNotificationScheduler(),
                now: { [nowBox] in nowBox.date }
            )
            let timer = try engine.start(
                recipeID: recipe.id,
                stepID: recipe.steps[0].id,
                cookSessionID: session.id,
                stepName: "Steam",
                duration: 60
            )
            return (timer.id, session.id)
        }()

        let reopened = try RecipeDatabase.make(at: path)
        let notifications = FakeNotificationScheduler()
        let engine = TimerEngine(
            repository: TimerRepository(database: reopened),
            notifications: notifications,
            now: { [nowBox] in nowBox.date }
        )
        XCTAssertEqual(try engine.timers(cookSessionID: identities.session).map(\.id), [identities.timer])
        try engine.synchronizeNotifications()
        XCTAssertEqual(notifications.scheduled.first?.deadline, Date(timeIntervalSince1970: 4_060))

        nowBox.date = Date(timeIntervalSince1970: 4_061)
        XCTAssertEqual(try engine.reconcileExpiredTimers().map(\.id), [identities.timer])
        XCTAssertEqual(try engine.timers(cookSessionID: identities.session).first?.status, .completed)
    }

    func testExtendNotificationActionAfterTerminationRestartsCompletedTimer() throws {
        let fixture = try TimerFixture(now: 5_000)
        let timer = try fixture.start(stepName: "Rest", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_030)
        let afterTerminationNotifications = FakeNotificationScheduler()
        let relaunched = TimerEngine(
            repository: TimerRepository(database: fixture.database),
            notifications: afterTerminationNotifications,
            now: { [nowBox = fixture.nowBox] in nowBox.date }
        )

        let handled = try relaunched.handleNotificationAction(
            identifier: TimerNotification.extendTwoActionIdentifier,
            timerID: timer.id
        )

        XCTAssertTrue(handled)
        let restarted = try XCTUnwrap(fixture.repository.fetchTimer(id: timer.id))
        XCTAssertEqual(restarted.status, .running)
        XCTAssertEqual(restarted.deadline, Date(timeIntervalSince1970: 5_150))
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired, .extended]
        )
        XCTAssertEqual(afterTerminationNotifications.scheduled.last?.deadline, restarted.deadline)
    }

    func testNotificationActionReconcilesExpiredRunningTimerBeforeExtendingFromActionTime() throws {
        let fixture = try TimerFixture(now: 5_500)
        let timer = try fixture.start(stepName: "Rest", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_530)

        XCTAssertTrue(try fixture.engine.handleNotificationAction(
            identifier: TimerNotification.extendFiveActionIdentifier,
            timerID: timer.id
        ))

        let restarted = try XCTUnwrap(fixture.repository.fetchTimer(id: timer.id))
        XCTAssertEqual(restarted.status, .running)
        XCTAssertEqual(restarted.deadline, Date(timeIntervalSince1970: 5_830))
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired, .extended]
        )
        XCTAssertEqual(fixture.notifications.allRemoved, [timer.id])
    }

    func testExtendAtDeadlineFiresThenRestartsFromActionTime() throws {
        let fixture = try TimerFixture(now: 5_540)
        let timer = try fixture.start(stepName: "Rest", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_550)

        let restarted = try fixture.engine.extend(timerID: timer.id, by: 120)

        XCTAssertEqual(restarted.status, .running)
        XCTAssertEqual(restarted.deadline, Date(timeIntervalSince1970: 5_670))
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired, .extended]
        )
        XCTAssertEqual(fixture.notifications.pendingRemoved, [timer.id])
        XCTAssertEqual(fixture.notifications.allRemoved, [timer.id])
        XCTAssertEqual(fixture.notifications.scheduled.last?.deadline, restarted.deadline)
    }

    func testExtendAfterDeadlineFiresThenRestartsFullExtensionFromActionTime() throws {
        let fixture = try TimerFixture(now: 5_560)
        let timer = try fixture.start(stepName: "Rest", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_590)

        let restarted = try fixture.engine.extend(timerID: timer.id, by: 300)

        XCTAssertEqual(restarted.status, .running)
        XCTAssertEqual(restarted.deadline, Date(timeIntervalSince1970: 5_890))
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired, .extended]
        )
        XCTAssertEqual(fixture.notifications.pendingRemoved, [timer.id])
        XCTAssertEqual(fixture.notifications.allRemoved, [timer.id])
        XCTAssertEqual(fixture.notifications.scheduled.last?.deadline, restarted.deadline)
    }

    func testRestartedTimerCanFireAgainAndQueuesItsNewCompletion() throws {
        let fixture = try TimerFixture(now: 5_600)
        let timer = try fixture.start(stepName: "Rest", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_611)
        _ = try fixture.engine.reconcileExpiredTimers()
        _ = try fixture.engine.handleNotificationAction(
            identifier: TimerNotification.extendTwoActionIdentifier,
            timerID: timer.id
        )

        fixture.nowBox.date = Date(timeIntervalSince1970: 5_732)
        XCTAssertEqual(try fixture.engine.reconcileExpiredTimers().map(\.id), [timer.id])

        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired, .extended, .fired]
        )
        XCTAssertEqual(try fixture.engine.pendingCompletions().map(\.id), [timer.id])
    }

    func testCompletionQueuePersistsUntilAcknowledgedAndThenRemovesDeliveredNotification() throws {
        let fixture = try TimerFixture(now: 5_800)
        let timer = try fixture.start(stepName: "Bake", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 5_811)
        _ = try fixture.engine.reconcileExpiredTimers()

        let relaunched = TimerEngine(
            repository: TimerRepository(database: fixture.database),
            notifications: fixture.notifications,
            now: { [nowBox = fixture.nowBox] in nowBox.date }
        )
        XCTAssertEqual(try relaunched.pendingCompletions().map(\.id), [timer.id])
        XCTAssertTrue(fixture.notifications.allRemoved.isEmpty)

        try relaunched.acknowledgeCompletion(timerID: timer.id)

        XCTAssertTrue(try relaunched.pendingCompletions().isEmpty)
        XCTAssertEqual(fixture.notifications.allRemoved, [timer.id])
    }

    func testExpiryTickDoesNotRescheduleUnchangedRunningTimer() throws {
        let fixture = try TimerFixture(now: 5_900)
        _ = try fixture.start(stepName: "Simmer", duration: 60)
        fixture.notifications.scheduled.removeAll()

        XCTAssertTrue(try fixture.engine.reconcileExpiredTimers().isEmpty)
        XCTAssertTrue(try fixture.engine.reconcileExpiredTimers().isEmpty)

        XCTAssertTrue(fixture.notifications.scheduled.isEmpty)
    }

    func testSchedulingContractIncludesActionsOnlyWhenNotificationsAllowed() throws {
        let allowed = try TimerFixture(now: 6_000)
        _ = try allowed.start(stepName: "Broil", duration: 45)
        XCTAssertEqual(
            allowed.notifications.scheduled.first?.actionIdentifiers,
            [
                TimerNotification.extendTwoActionIdentifier,
                TimerNotification.extendFiveActionIdentifier,
            ]
        )

        let denied = try TimerFixture(now: 6_000)
        denied.notifications.authorization = .denied
        _ = try denied.start(stepName: "Broil", duration: 45)
        XCTAssertEqual(denied.engine.notificationAuthorization, .denied)
        XCTAssertTrue(denied.notifications.scheduled.isEmpty)
    }

    func testDelayedSchedulingFailureIsConsumedByVisibleFallbackHandler() throws {
        let fixture = try TimerFixture(now: 6_500)
        fixture.notifications.completeSchedulesImmediately = false
        let failure = ScheduleFailureBox()
        fixture.engine.onNotificationSchedulingFailure = { timerID, message in
            failure.value = (timerID, message)
        }

        let timer = try fixture.start(stepName: "Broil", duration: 45)
        XCTAssertNil(failure.value)

        fixture.notifications.completeNextSchedule(with: .failure("Center rejected request"))

        XCTAssertEqual(failure.value?.0, timer.id)
        XCTAssertEqual(failure.value?.1, "Center rejected request")
    }

    func testPauseAtOrAfterZeroCompletesInsteadOfCreatingUnresumablePause() throws {
        let fixture = try TimerFixture(now: 7_000)
        let timer = try fixture.start(stepName: "Toast", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 7_010)

        let result = try fixture.engine.pause(timerID: timer.id)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired]
        )
        XCTAssertEqual(fixture.notifications.pendingRemoved, [timer.id])
    }

    func testEndingSessionAtomicallyCancelsAllActiveTimers() throws {
        let fixture = try TimerFixture(now: 7_500)
        let running = try fixture.start(stepName: "Boil", duration: 60)
        let paused = try fixture.start(stepName: "Rest", duration: 90)
        _ = try fixture.engine.pause(timerID: paused.id)

        let cancelledIDs = try fixture.engine.endCookSession(
            sessionID: fixture.session.id,
            as: .completed
        )

        XCTAssertEqual(Set(cancelledIDs), Set([running.id, paused.id]))
        XCTAssertEqual(
            try fixture.repository.fetchTimers().map(\.status),
            [.cancelled, .cancelled]
        )
        XCTAssertEqual(Set(fixture.notifications.allRemoved), Set([running.id, paused.id]))
        XCTAssertEqual(
            try RecipeRepository(database: fixture.database)
                .fetchCookSessions(for: fixture.recipe.id).first?.status,
            .completed
        )
    }

    func testCookSessionLogCombinesConcurrentTimerEventsInInsertionOrder() throws {
        let fixture = try TimerFixture(now: 8_000)
        let first = try fixture.start(stepName: "Boil", duration: 60)
        _ = try fixture.start(stepName: "Bake", duration: 90)
        _ = try fixture.engine.extend(timerID: first.id, by: 120)
        fixture.nowBox.date = Date(timeIntervalSince1970: 8_181)
        _ = try fixture.engine.reconcileExpiredTimers()

        XCTAssertEqual(
            try fixture.repository.fetchEvents(cookSessionID: fixture.session.id).map(\.kind),
            [.started, .started, .extended, .fired, .fired]
        )
    }
}

private final class FakeNotificationScheduler: TimerNotificationScheduling, @unchecked Sendable {
    var scheduled: [TimerNotification] = []
    private(set) var pendingRemoved: [UUID] = []
    private(set) var allRemoved: [UUID] = []
    var authorization: NotificationAuthorization = .allowed
    var scheduleResult: TimerNotificationScheduleResult = .success
    var completeSchedulesImmediately = true
    private var scheduleCompletions: [@Sendable (TimerNotificationScheduleResult) -> Void] = []

    func schedule(
        _ notification: TimerNotification,
        completion: @escaping @Sendable (TimerNotificationScheduleResult) -> Void
    ) {
        scheduled.removeAll { $0.timerID == notification.timerID }
        scheduled.append(notification)
        if completeSchedulesImmediately {
            completion(scheduleResult)
        } else {
            scheduleCompletions.append(completion)
        }
    }

    func removePending(timerID: UUID) {
        pendingRemoved.append(timerID)
        scheduled.removeAll { $0.timerID == timerID }
    }

    func removeAll(timerID: UUID) {
        allRemoved.append(timerID)
        scheduled.removeAll { $0.timerID == timerID }
    }

    func completeNextSchedule(with result: TimerNotificationScheduleResult) {
        scheduleCompletions.removeFirst()(result)
    }
}

private final class ScheduleFailureBox: @unchecked Sendable {
    var value: (UUID, String)?
}

private struct TimerFixture {
    let nowBox: NowBox
    let database: GRDB.DatabaseQueue
    let recipe: Recipe
    let session: CookSession
    let repository: TimerRepository
    let notifications: FakeNotificationScheduler
    let engine: TimerEngine

    init(now: TimeInterval) throws {
        nowBox = NowBox(now)
        database = try RecipeDatabase.makeInMemory()
        recipe = try Recipe(
            title: "Soup",
            servings: 2,
            ingredients: [try Ingredient(name: "Stock", amount: 2, unit: .cup)],
            steps: [try RecipeStep(instruction: "Simmer gently", timerDuration: 120)]
        )
        let recipeRepository = RecipeRepository(database: database)
        try recipeRepository.create(recipe)
        session = try recipeRepository.beginCook(
            for: recipe.id,
            at: Date(timeIntervalSince1970: now)
        )
        repository = TimerRepository(database: database)
        notifications = FakeNotificationScheduler()
        engine = TimerEngine(
            repository: repository,
            notifications: notifications,
            now: { [nowBox] in nowBox.date }
        )
    }

    func start(stepName: String, duration: TimeInterval) throws -> CookTimer {
        try engine.start(
            recipeID: recipe.id,
            stepID: recipe.steps[0].id,
            cookSessionID: session.id,
            stepName: stepName,
            duration: duration
        )
    }
}

private final class NowBox: @unchecked Sendable {
    var date: Date

    init(_ interval: TimeInterval) {
        date = Date(timeIntervalSince1970: interval)
    }
}
