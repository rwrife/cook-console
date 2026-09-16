import Foundation

enum NotificationAuthorization: Equatable, Sendable {
    case unknown
    case allowed
    case denied
}

struct TimerNotification: Equatable, Sendable {
    static let categoryIdentifier = "COOK_TIMER"
    static let extendTwoActionIdentifier = "COOK_TIMER_EXTEND_2"
    static let extendFiveActionIdentifier = "COOK_TIMER_EXTEND_5"

    let timerID: UUID
    let stepName: String
    let deadline: Date

    var actionIdentifiers: [String] {
        [Self.extendTwoActionIdentifier, Self.extendFiveActionIdentifier]
    }
}

enum TimerNotificationScheduleResult: Equatable, Sendable {
    case success
    case failure(String)
}

protocol TimerNotificationScheduling: AnyObject {
    var authorization: NotificationAuthorization { get }
    func schedule(
        _ notification: TimerNotification,
        completion: @escaping @Sendable (TimerNotificationScheduleResult) -> Void
    )
    func removePending(timerID: UUID)
    func removeAll(timerID: UUID)
}

final class NoopTimerNotificationScheduler: TimerNotificationScheduling {
    var authorization: NotificationAuthorization { .denied }
    func schedule(
        _ notification: TimerNotification,
        completion: @escaping @Sendable (TimerNotificationScheduleResult) -> Void
    ) {
        completion(.failure("Timer notifications are unavailable."))
    }
    func removePending(timerID: UUID) {}
    func removeAll(timerID: UUID) {}
}
