import Foundation

final class TimerEngine {
    private let repository: TimerRepository
    private let notifications: TimerNotificationScheduling
    private let now: @Sendable () -> Date

    var onNotificationSchedulingFailure: (@Sendable (UUID, String) -> Void)?

    var notificationAuthorization: NotificationAuthorization {
        notifications.authorization
    }

    init(
        repository: TimerRepository,
        notifications: TimerNotificationScheduling,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.notifications = notifications
        self.now = now
    }

    func start(
        recipeID: UUID,
        stepID: UUID,
        cookSessionID: UUID,
        stepName: String,
        duration: TimeInterval
    ) throws -> CookTimer {
        guard duration.isFinite, duration > 0 else { throw TimerEngineError.invalidDuration }
        let startedAt = now()
        let timer = CookTimer(
            id: UUID(),
            recipeID: recipeID,
            stepID: stepID,
            cookSessionID: cookSessionID,
            stepName: stepName,
            originalDuration: duration,
            status: .running,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(duration),
            remainingWhenPaused: nil,
            completedAt: nil,
            scheduleGeneration: 0
        )
        try repository.insertStarted(timer)
        schedule(timer)
        return timer
    }

    func pause(timerID: UUID) throws -> CookTimer {
        let timer = try requiredTimer(timerID)
        guard timer.status == .running, let deadline = timer.deadline else {
            throw TimerEngineError.invalidTransition
        }
        let remaining = deadline.timeIntervalSince(now())
        if remaining <= 0 {
            return try complete(timerID: timerID)
        }
        let paused = copy(
            timer,
            status: .paused,
            deadline: nil,
            remaining: remaining
        )
        try repository.update(paused)
        notifications.removeAll(timerID: timerID)
        return paused
    }

    func resume(timerID: UUID) throws -> CookTimer {
        let timer = try requiredTimer(timerID)
        guard timer.status == .paused, let remaining = timer.remainingWhenPaused, remaining > 0 else {
            throw TimerEngineError.invalidTransition
        }
        let resumed = copy(
            timer,
            status: .running,
            deadline: now().addingTimeInterval(remaining),
            remaining: nil
        )
        try repository.update(resumed)
        schedule(resumed)
        return resumed
    }

    func extend(timerID: UUID, by seconds: TimeInterval) throws -> CookTimer {
        guard seconds.isFinite, seconds > 0 else { throw TimerEngineError.invalidDuration }
        return try extend(
            timerID: timerID,
            by: seconds,
            at: now(),
            canRestartCompleted: false
        )
    }

    private func extend(
        timerID: UUID,
        by seconds: TimeInterval,
        at actionDate: Date,
        canRestartCompleted: Bool
    ) throws -> CookTimer {
        let timer = try requiredTimer(timerID)
        let extended: CookTimer
        switch timer.status {
        case .running:
            guard let deadline = timer.deadline else { throw TimerEngineError.invalidTransition }
            if deadline <= actionDate {
                let completed = try complete(timerID: timerID)
                return try restart(completed, by: seconds, at: actionDate)
            }
            extended = copy(
                timer,
                status: .running,
                deadline: deadline.addingTimeInterval(seconds),
                remaining: nil
            )
        case .paused:
            guard let remaining = timer.remainingWhenPaused else {
                throw TimerEngineError.invalidTransition
            }
            extended = copy(
                timer,
                status: .paused,
                deadline: nil,
                remaining: remaining + seconds
            )
        case .completed where canRestartCompleted:
            return try restart(timer, by: seconds, at: actionDate)
        case .cancelled, .completed:
            throw TimerEngineError.invalidTransition
        }
        try repository.update(
            extended,
            event: TimerEvent(
                id: UUID(),
                timerID: timerID,
                kind: .extended,
                occurredAt: actionDate,
                seconds: seconds
            )
        )
        if extended.status == .running { schedule(extended) }
        return extended
    }

    func cancel(timerID: UUID) throws -> CookTimer {
        let timer = try requiredTimer(timerID)
        guard timer.status == .running || timer.status == .paused else {
            throw TimerEngineError.invalidTransition
        }
        let cancelled = copy(
            timer,
            status: .cancelled,
            deadline: nil,
            remaining: nil,
            completedAt: now()
        )
        try repository.update(cancelled)
        notifications.removeAll(timerID: timerID)
        return cancelled
    }

    @discardableResult
    func complete(timerID: UUID) throws -> CookTimer {
        let timer = try requiredTimer(timerID)
        if timer.status == .completed { return timer }
        guard timer.status == .running || timer.status == .paused else {
            throw TimerEngineError.invalidTransition
        }
        let completionDate = now()
        let completed = copy(
            timer,
            status: .completed,
            deadline: nil,
            remaining: nil,
            completedAt: completionDate
        )
        try repository.update(
            completed,
            event: TimerEvent(
                id: UUID(),
                timerID: timerID,
                kind: .fired,
                occurredAt: completionDate,
                seconds: nil
            )
        )
        // Expiry deliberately leaves the pending request in place. Polling can
        // reach the deadline slightly before the OS delivers, and removing a
        // still-pending request would destroy its only actionable +2/+5
        // delivery. Acknowledgment, pause, cancellation, restart, and session
        // end remove pending and delivered notifications instead.
        return completed
    }

    /// Completes a timer only when a delivered notification provably belongs
    /// to the timer's current schedule. Every persisted timer state change
    /// bumps `scheduleGeneration`, so a payload whose captured generation no
    /// longer matches was scheduled for an obsolete request — the timer was
    /// paused, resumed, extended, completed, cancelled, or restarted while
    /// delivery was in flight — and must not change state. Exact generation
    /// equality is required: two distinct schedules can share a near-identical
    /// deadline (pause-then-resume within a second), and deadline comparison
    /// alone cannot distinguish them.
    @discardableResult
    func completeIfDelivered(timerID: UUID, scheduleGeneration: Int) throws -> CookTimer? {
        guard let timer = try repository.fetchTimer(id: timerID) else { return nil }
        guard timer.status == .running, let deadline = timer.deadline else { return nil }
        guard timer.scheduleGeneration == scheduleGeneration else { return nil }
        // Never let a mis-delivery complete a timer before its own deadline.
        guard now() >= deadline else { return nil }
        return try complete(timerID: timerID)
    }

    @discardableResult
    func reconcileExpiredTimers() throws -> [CookTimer] {
        var newlyCompleted: [CookTimer] = []
        let currentDate = now()
        for timer in try repository.fetchExpiredRunning(at: currentDate) {
            newlyCompleted.append(try complete(timerID: timer.id))
        }
        return newlyCompleted
    }

    func synchronizeNotifications() throws {
        let currentDate = now()
        for timer in try repository.fetchTimers() {
            switch timer.status {
            case .running where timer.deadline.map({ $0 > currentDate }) == true:
                schedule(timer)
            case .paused:
                notifications.removePending(timerID: timer.id)
            case .running, .cancelled, .completed:
                break
            }
        }
    }

    func pendingCompletions() throws -> [CookTimer] {
        try repository.fetchPendingCompletions()
    }

    /// The earliest deadline among running timers, used by the app layer to
    /// schedule exactly one expiry wake-up instead of polling.
    func nextExpiryDate() throws -> Date? {
        try repository.fetchNextRunningDeadline()
    }

    func acknowledgeCompletion(timerID: UUID) throws {
        try repository.acknowledgeCompletion(timerID: timerID)
        notifications.removeAll(timerID: timerID)
    }

    func endCookSession(sessionID: UUID, as status: CookSessionStatus) throws -> [UUID] {
        let cancelled = try repository.endCookSession(sessionID: sessionID, as: status, at: now())
        for timerID in cancelled {
            notifications.removeAll(timerID: timerID)
        }
        return cancelled
    }

    func timers(cookSessionID: UUID) throws -> [CookTimer] {
        try repository.fetchTimers(cookSessionID: cookSessionID)
    }

    @discardableResult
    func handleNotificationAction(identifier: String, timerID: UUID) throws -> Bool {
        let seconds: TimeInterval
        switch identifier {
        case TimerNotification.extendTwoActionIdentifier:
            seconds = 120
        case TimerNotification.extendFiveActionIdentifier:
            seconds = 300
        default:
            return false
        }

        let timer = try requiredTimer(timerID)
        if timer.status == .cancelled { return false }
        let actionDate = now()
        _ = try extend(
            timerID: timerID,
            by: seconds,
            at: actionDate,
            canRestartCompleted: true
        )
        return true
    }

    private func restart(
        _ completed: CookTimer,
        by seconds: TimeInterval,
        at actionDate: Date
    ) throws -> CookTimer {
        let restarted = copy(
            completed,
            status: .running,
            deadline: actionDate.addingTimeInterval(seconds),
            remaining: nil
        )
        try repository.restartCompleted(
            restarted,
            event: TimerEvent(
                id: UUID(),
                timerID: completed.id,
                kind: .extended,
                occurredAt: actionDate,
                seconds: seconds
            )
        )
        notifications.removeAll(timerID: completed.id)
        schedule(restarted)
        return restarted
    }

    private func requiredTimer(_ id: UUID) throws -> CookTimer {
        guard let timer = try repository.fetchTimer(id: id) else {
            throw TimerEngineError.notFound(id)
        }
        return timer
    }

    private func schedule(_ timer: CookTimer) {
        guard notifications.authorization == .allowed, let deadline = timer.deadline else { return }
        let failureHandler = onNotificationSchedulingFailure
        notifications.schedule(
            TimerNotification(
                timerID: timer.id,
                stepName: timer.stepName,
                deadline: deadline,
                scheduleGeneration: timer.scheduleGeneration
            )
        ) { result in
            if case let .failure(message) = result {
                failureHandler?(timer.id, message)
            }
        }
    }

    private func copy(
        _ timer: CookTimer,
        status: CookTimerStatus,
        deadline: Date?,
        remaining: TimeInterval?,
        completedAt: Date? = nil
    ) -> CookTimer {
        CookTimer(
            id: timer.id,
            recipeID: timer.recipeID,
            stepID: timer.stepID,
            cookSessionID: timer.cookSessionID,
            stepName: timer.stepName,
            originalDuration: timer.originalDuration,
            status: status,
            startedAt: timer.startedAt,
            deadline: deadline,
            remainingWhenPaused: remaining,
            completedAt: completedAt,
            scheduleGeneration: timer.scheduleGeneration + 1
        )
    }
}
