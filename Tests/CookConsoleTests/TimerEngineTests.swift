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
        // Expiry must not remove the still-pending notification: the OS may
        // not have delivered it yet, and removal would destroy its only
        // actionable +2/+5 presentation.
        XCTAssertTrue(firstReloadNotifications.pendingRemoved.isEmpty)
        XCTAssertTrue(firstReloadNotifications.allRemoved.isEmpty)
        XCTAssertEqual(try secondReload.pendingCompletions().map(\.id), [timer.id])
        try firstReload.acknowledgeCompletion(timerID: timer.id)
        XCTAssertEqual(firstReloadNotifications.allRemoved, [timer.id])
    }

    func testDelayedDeliveryAfterExpiryReconciliationCannotDoubleFire() throws {
        let fixture = try TimerFixture(now: 3_100)
        let timer = try fixture.start(stepName: "Bake", duration: 30)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_131)
        _ = try fixture.engine.reconcileExpiredTimers()

        // The OS delivers the original request slightly late, after
        // reconciliation already completed the timer.
        let late = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: timer.scheduleGeneration
        )

        XCTAssertNil(late)
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired]
        )
    }

    func testForegroundDeliveryCompletesOnlyTheCurrentSchedule() throws {
        let fixture = try TimerFixture(now: 3_200)
        let timer = try fixture.start(stepName: "Simmer", duration: 60)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_220)
        _ = try fixture.engine.extend(timerID: timer.id, by: 120)

        // An in-flight delivery scheduled for the pre-extension generation
        // must not complete the newly extended timer.
        let stale = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: timer.scheduleGeneration
        )
        XCTAssertNil(stale)
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .running)
        XCTAssertTrue(try fixture.engine.pendingCompletions().isEmpty)

        let extended = try XCTUnwrap(fixture.repository.fetchTimer(id: timer.id))
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_380)
        let current = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: extended.scheduleGeneration
        )
        XCTAssertEqual(current?.status, .completed)
        XCTAssertEqual(try fixture.engine.pendingCompletions().map(\.id), [timer.id])
    }

    func testNearCoincidentResumeDeadlineCannotBeCompletedByObsoleteDelivery() throws {
        let fixture = try TimerFixture(now: 3_250)
        let timer = try fixture.start(stepName: "Simmer", duration: 60)
        // Pause with roughly one second left, then resume 0.2s later: the new
        // deadline lands within a second of the original request's deadline,
        // which deadline comparison alone could not distinguish.
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_309.8)
        _ = try fixture.engine.pause(timerID: timer.id)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_310)
        let resumed = try fixture.engine.resume(timerID: timer.id)
        XCTAssertLessThan(
            abs(resumed.deadline!.timeIntervalSince(
                Date(timeIntervalSince1970: 3_310)
            )),
            1
        )

        // The obsolete generation-0 request firing "on time" must not
        // complete the freshly resumed timer.
        let stale = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: timer.scheduleGeneration
        )
        XCTAssertNil(stale)
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .running)
    }

    func testForegroundDeliveryCannotCompletePausedOrCancelledTimer() throws {
        let fixture = try TimerFixture(now: 3_300)
        let timer = try fixture.start(stepName: "Rest", duration: 60)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_320)
        _ = try fixture.engine.pause(timerID: timer.id)

        let pausedResult = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: timer.scheduleGeneration
        )
        XCTAssertNil(pausedResult)
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .paused)

        _ = try fixture.engine.resume(timerID: timer.id)
        _ = try fixture.engine.cancel(timerID: timer.id)
        let cancelledResult = try fixture.engine.completeIfDelivered(
            timerID: timer.id,
            scheduleGeneration: timer.scheduleGeneration
        )
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .cancelled)
        XCTAssertTrue(try fixture.engine.pendingCompletions().isEmpty)
    }

    func testNextExpiryDateTracksOnlyRunningDeadlines() throws {
        let fixture = try TimerFixture(now: 3_400)
        XCTAssertNil(try fixture.engine.nextExpiryDate())
        let first = try fixture.start(stepName: "Boil", duration: 90)
        let second = try fixture.start(stepName: "Rest", duration: 30)
        XCTAssertEqual(try fixture.engine.nextExpiryDate(), Date(timeIntervalSince1970: 3_430))
        _ = try fixture.engine.pause(timerID: second.id)
        XCTAssertEqual(try fixture.engine.nextExpiryDate(), first.deadline)
        _ = try fixture.engine.cancel(timerID: first.id)
        XCTAssertNil(try fixture.engine.nextExpiryDate())
    }

    func testWallClockChangesConvergeWithoutEarlyOrDuplicateCompletion() throws {
        let fixture = try TimerFixture(now: 3_500)
        let timer = try fixture.start(stepName: "Roast", duration: 60)

        // Persisted deadlines are absolute dates so they survive termination
        // and device restart. A wall-clock correction backwards must not fire
        // the timer before that durable deadline.
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_400)
        XCTAssertTrue(try fixture.engine.reconcileExpiredTimers().isEmpty)
        XCTAssertEqual(try fixture.repository.fetchTimer(id: timer.id)?.status, .running)

        // A correction forward beyond the deadline is treated as overdue.
        // Repeated foreground/launch reconciliation remains idempotent.
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_900)
        XCTAssertEqual(try fixture.engine.reconcileExpiredTimers().map(\.id), [timer.id])
        XCTAssertTrue(try fixture.engine.reconcileExpiredTimers().isEmpty)
        XCTAssertEqual(
            try fixture.repository.fetchEvents(timerID: timer.id).map(\.kind),
            [.started, .fired]
        )
        XCTAssertEqual(try fixture.engine.pendingCompletions().map(\.id), [timer.id])
    }

    func testLaunchSynchronizationRemovesStaleNotificationsForInactiveTimers() throws {
        let fixture = try TimerFixture(now: 3_700)
        let paused = try fixture.start(stepName: "Paused", duration: 60)
        let cancelled = try fixture.start(stepName: "Cancelled", duration: 90)
        let acknowledged = try fixture.start(stepName: "Acknowledged", duration: 10)

        _ = try fixture.engine.pause(timerID: paused.id)
        _ = try fixture.engine.cancel(timerID: cancelled.id)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_711)
        _ = try fixture.engine.reconcileExpiredTimers()
        try fixture.engine.acknowledgeCompletion(timerID: acknowledged.id)

        // Simulate the crash window where durable state was committed but the
        // process died before UserNotifications received the cleanup call.
        for timer in [paused, cancelled, acknowledged] {
            fixture.notifications.schedule(
                TimerNotification(
                    timerID: timer.id,
                    stepName: timer.stepName,
                    deadline: Date(timeIntervalSince1970: 9_999),
                    scheduleGeneration: timer.scheduleGeneration
                ),
                completion: { _ in }
            )
        }
        XCTAssertEqual(fixture.notifications.scheduled.count, 3)

        try fixture.engine.synchronizeNotifications()

        XCTAssertTrue(fixture.notifications.scheduled.isEmpty)
        XCTAssertTrue(fixture.notifications.pendingRemoved.isEmpty)
        XCTAssertEqual(
            Set(fixture.notifications.allRemoved.suffix(3)),
            Set([paused.id, cancelled.id, acknowledged.id])
        )
    }

    func testLaunchSynchronizationPreservesUnacknowledgedCompletionNotification() throws {
        let fixture = try TimerFixture(now: 3_800)
        let timer = try fixture.start(stepName: "Bread", duration: 10)
        fixture.nowBox.date = Date(timeIntervalSince1970: 3_811)
        _ = try fixture.engine.reconcileExpiredTimers()
        fixture.notifications.scheduled.removeAll()
        fixture.notifications.schedule(
            TimerNotification(
                timerID: timer.id,
                stepName: timer.stepName,
                deadline: timer.deadline!,
                scheduleGeneration: timer.scheduleGeneration
            ),
            completion: { _ in }
        )

        try fixture.engine.synchronizeNotifications()

        XCTAssertEqual(fixture.notifications.scheduled.map(\.timerID), [timer.id])
        XCTAssertEqual(try fixture.engine.pendingCompletions().map(\.id), [timer.id])
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
        // Completion never removes the pending request; only acknowledgment
        // does, preserving the actionable notification if the OS has not
        // delivered it yet.
        XCTAssertTrue(fixture.notifications.pendingRemoved.isEmpty)
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
