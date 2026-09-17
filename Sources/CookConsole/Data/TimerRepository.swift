import Foundation
import GRDB

final class TimerRepository {
    private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    func insertStarted(_ timer: CookTimer) throws {
        try database.write { db in
            let identitiesAreValid = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM cook_sessions AS session
                        JOIN recipe_steps AS step ON step.recipe_id = session.recipe_id
                        WHERE session.id = ? AND session.recipe_id = ?
                          AND session.status = 'active' AND step.id = ?
                    )
                    """,
                arguments: [
                    timer.cookSessionID.uuidString,
                    timer.recipeID.uuidString,
                    timer.stepID.uuidString,
                ]
            ) ?? false
            guard identitiesAreValid else { throw TimerEngineError.invalidIdentity }
            try db.execute(
                sql: """
                    INSERT INTO cook_timers
                        (id, recipe_id, step_id, cook_session_id, step_name,
                         original_duration, status, started_at, deadline,
                         remaining_when_paused, completed_at, schedule_generation)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: arguments(for: timer)
            )
            try insertEvent(
                TimerEvent(
                    id: UUID(),
                    timerID: timer.id,
                    kind: .started,
                    occurredAt: timer.startedAt,
                    seconds: nil
                ),
                into: db
            )
        }
    }

    func fetchTimers() throws -> [CookTimer] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, recipe_id, step_id, cook_session_id, step_name,
                           original_duration, status, started_at, deadline,
                           remaining_when_paused, completed_at, schedule_generation
                    FROM cook_timers ORDER BY started_at, id
                    """
            ).map(decodeTimer)
        }
    }

    func fetchTimers(cookSessionID: UUID) throws -> [CookTimer] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, recipe_id, step_id, cook_session_id, step_name,
                           original_duration, status, started_at, deadline,
                           remaining_when_paused, completed_at, schedule_generation
                    FROM cook_timers
                    WHERE cook_session_id = ? ORDER BY started_at, id
                    """,
                arguments: [cookSessionID.uuidString]
            ).map(decodeTimer)
        }
    }

    func fetchNextRunningDeadline() throws -> Date? {
        try database.read { db in
            try Date.fetchOne(
                db,
                sql: """
                    SELECT MIN(deadline) FROM cook_timers
                    WHERE status = 'running' AND deadline IS NOT NULL
                    """
            )
        }
    }

    func fetchTimer(id: UUID) throws -> CookTimer? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, recipe_id, step_id, cook_session_id, step_name,
                           original_duration, status, started_at, deadline,
                           remaining_when_paused, completed_at, schedule_generation
                    FROM cook_timers WHERE id = ?
                    """,
                arguments: [id.uuidString]
            ).map(decodeTimer)
        }
    }

    func fetchExpiredRunning(at date: Date) throws -> [CookTimer] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, recipe_id, step_id, cook_session_id, step_name,
                           original_duration, status, started_at, deadline,
                           remaining_when_paused, completed_at, schedule_generation
                    FROM cook_timers
                    WHERE status = 'running' AND deadline <= ?
                    ORDER BY deadline, id
                    """,
                arguments: [date]
            ).map(decodeTimer)
        }
    }

    func update(_ timer: CookTimer, event: TimerEvent? = nil) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_timers
                    SET status = ?, deadline = ?, remaining_when_paused = ?,
                        completed_at = ?, schedule_generation = ?
                    WHERE id = ?
                    """,
                arguments: [
                    timer.status.rawValue,
                    timer.deadline,
                    timer.remainingWhenPaused,
                    timer.completedAt,
                    timer.scheduleGeneration,
                    timer.id.uuidString,
                ]
            )
            guard db.changesCount == 1 else { throw TimerEngineError.notFound(timer.id) }
            if let event {
                try insertEvent(event, into: db)
                if event.kind == .fired {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO timer_completion_alerts (timer_id, completed_at)
                            VALUES (?, ?)
                            """,
                        arguments: [timer.id.uuidString, event.occurredAt]
                    )
                }
            }
        }
    }

    func fetchPendingCompletions() throws -> [CookTimer] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT timer.id, timer.recipe_id, timer.step_id, timer.cook_session_id,
                           timer.step_name, timer.original_duration, timer.status,
                           timer.started_at, timer.deadline, timer.remaining_when_paused,
                           timer.completed_at, timer.schedule_generation
                    FROM timer_completion_alerts AS alert
                    JOIN cook_timers AS timer ON timer.id = alert.timer_id
                    ORDER BY alert.completed_at, timer.id
                    """
            ).map(decodeTimer)
        }
    }

    func acknowledgeCompletion(timerID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM timer_completion_alerts WHERE timer_id = ?",
                arguments: [timerID.uuidString]
            )
        }
    }

    func restartCompleted(_ timer: CookTimer, event: TimerEvent) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE cook_timers
                    SET status = ?, deadline = ?, remaining_when_paused = NULL,
                        completed_at = NULL, schedule_generation = ?
                    WHERE id = ? AND status = 'completed'
                    """,
                arguments: [
                    timer.status.rawValue,
                    timer.deadline,
                    timer.scheduleGeneration,
                    timer.id.uuidString,
                ]
            )
            guard db.changesCount == 1 else { throw TimerEngineError.invalidTransition }
            try insertEvent(event, into: db)
            try db.execute(
                sql: "DELETE FROM timer_completion_alerts WHERE timer_id = ?",
                arguments: [timer.id.uuidString]
            )
        }
    }

    func endCookSession(
        sessionID: UUID,
        as status: CookSessionStatus,
        at date: Date
    ) throws -> [UUID] {
        guard status != .active else { throw CookSessionError.notActive }
        return try database.write { db in
            let identifiers = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM cook_timers
                    WHERE cook_session_id = ? AND status IN ('running', 'paused')
                    ORDER BY started_at, id
                    """,
                arguments: [sessionID.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE cook_timers
                    SET status = 'cancelled', deadline = NULL,
                        remaining_when_paused = NULL, completed_at = ?
                    WHERE cook_session_id = ? AND status IN ('running', 'paused')
                    """,
                arguments: [date, sessionID.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE cook_sessions SET status = ?, ended_at = ?
                    WHERE id = ? AND status = 'active'
                    """,
                arguments: [status.rawValue, date, sessionID.uuidString]
            )
            guard db.changesCount == 1 else { throw CookSessionError.notActive }
            return try identifiers.map { identifier in
                guard let id = UUID(uuidString: identifier) else {
                    throw RecipeRepositoryError.corruptData("Invalid timer identity.")
                }
                return id
            }
        }
    }

    func fetchEvents(timerID: UUID) throws -> [TimerEvent] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timer_id, event_kind, occurred_at, seconds
                    FROM timer_events WHERE timer_id = ? ORDER BY sequence
                    """,
                arguments: [timerID.uuidString]
            ).map(decodeEvent)
        }
    }

    func fetchEvents(cookSessionID: UUID) throws -> [TimerEvent] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT event.id, event.timer_id, event.event_kind,
                           event.occurred_at, event.seconds
                    FROM timer_events AS event
                    JOIN cook_timers AS timer ON timer.id = event.timer_id
                    WHERE timer.cook_session_id = ?
                    ORDER BY event.sequence
                    """,
                arguments: [cookSessionID.uuidString]
            ).map(decodeEvent)
        }
    }

    private func insertEvent(_ event: TimerEvent, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO timer_events (id, timer_id, event_kind, occurred_at, seconds)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                event.id.uuidString,
                event.timerID.uuidString,
                event.kind.rawValue,
                event.occurredAt,
                event.seconds,
            ]
        )
    }

    private func arguments(for timer: CookTimer) -> StatementArguments {
        [
            timer.id.uuidString,
            timer.recipeID.uuidString,
            timer.stepID.uuidString,
            timer.cookSessionID.uuidString,
            timer.stepName,
            timer.originalDuration,
            timer.status.rawValue,
            timer.startedAt,
            timer.deadline,
            timer.remainingWhenPaused,
            timer.completedAt,
            timer.scheduleGeneration,
        ]
    }

    private func decodeTimer(_ row: Row) throws -> CookTimer {
        let id: String = row["id"]
        let recipeID: String = row["recipe_id"]
        let stepID: String = row["step_id"]
        let sessionID: String = row["cook_session_id"]
        let status: String = row["status"]
        guard let timerID = UUID(uuidString: id),
              let recipeUUID = UUID(uuidString: recipeID),
              let stepUUID = UUID(uuidString: stepID),
              let sessionUUID = UUID(uuidString: sessionID),
              let timerStatus = CookTimerStatus(rawValue: status)
        else { throw RecipeRepositoryError.corruptData("Invalid timer identity or status.") }
        return CookTimer(
            id: timerID,
            recipeID: recipeUUID,
            stepID: stepUUID,
            cookSessionID: sessionUUID,
            stepName: row["step_name"],
            originalDuration: row["original_duration"],
            status: timerStatus,
            startedAt: row["started_at"],
            deadline: row["deadline"],
            remainingWhenPaused: row["remaining_when_paused"],
            completedAt: row["completed_at"],
            scheduleGeneration: row["schedule_generation"]
        )
    }

    private func decodeEvent(_ row: Row) throws -> TimerEvent {
        let id: String = row["id"]
        let timerID: String = row["timer_id"]
        let kind: String = row["event_kind"]
        guard let eventID = UUID(uuidString: id),
              let timerUUID = UUID(uuidString: timerID),
              let eventKind = TimerEventKind(rawValue: kind)
        else { throw RecipeRepositoryError.corruptData("Invalid timer event.") }
        return TimerEvent(
            id: eventID,
            timerID: timerUUID,
            kind: eventKind,
            occurredAt: row["occurred_at"],
            seconds: row["seconds"]
        )
    }
}
