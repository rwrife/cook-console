import Foundation

enum CookTimerStatus: String, Equatable, Sendable {
    case running
    case paused
    case cancelled
    case completed
}

struct CookTimer: Identifiable, Equatable, Sendable {
    let id: UUID
    let recipeID: UUID
    let stepID: UUID
    let cookSessionID: UUID
    let stepName: String
    let originalDuration: TimeInterval
    let status: CookTimerStatus
    let startedAt: Date
    let deadline: Date?
    let remainingWhenPaused: TimeInterval?
    let completedAt: Date?
    let scheduleGeneration: Int

    func remaining(at date: Date) -> TimeInterval {
        switch status {
        case .running:
            max(0, deadline?.timeIntervalSince(date) ?? 0)
        case .paused:
            max(0, remainingWhenPaused ?? 0)
        case .cancelled, .completed:
            0
        }
    }
}

enum TimerEventKind: String, Equatable, Sendable {
    case started
    case fired
    case extended
}

struct TimerEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timerID: UUID
    let kind: TimerEventKind
    let occurredAt: Date
    let seconds: TimeInterval?
}

enum TimerEngineError: Error, Equatable, LocalizedError, Sendable {
    case invalidDuration
    case invalidIdentity
    case invalidTransition
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "Timer duration must be finite and greater than zero."
        case .invalidIdentity: "The timer must belong to an active session and one of its recipe steps."
        case .invalidTransition: "That timer action is not available in its current state."
        case let .notFound(id): "No timer exists with ID \(id.uuidString)."
        }
    }
}
