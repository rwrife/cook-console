#if canImport(UserNotifications)
import Foundation
import UserNotifications

final class LocalNotificationService: NSObject, TimerNotificationScheduling, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var storedAuthorization: NotificationAuthorization = .unknown
    private var storedAuthorizationHandler: (@MainActor @Sendable (NotificationAuthorization) -> Void)?
    private var storedActionHandler: (@MainActor @Sendable (String, UUID) -> Void)?
    private var storedForegroundHandler: (@MainActor @Sendable (UUID) -> Void)?
    private var pendingAction: (identifier: String, timerID: UUID)?

    var onAuthorizationChange: (@MainActor @Sendable (NotificationAuthorization) -> Void)? {
        get { lock.withLock { storedAuthorizationHandler } }
        set { lock.withLock { storedAuthorizationHandler = newValue } }
    }
    var onAction: (@MainActor @Sendable (String, UUID) -> Void)? {
        get { lock.withLock { storedActionHandler } }
        set {
            let pending: (identifier: String, timerID: UUID)? = lock.withLock {
                storedActionHandler = newValue
                guard newValue != nil else { return nil }
                defer { pendingAction = nil }
                return pendingAction
            }
            if let newValue, let pending {
                Task { @MainActor in newValue(pending.identifier, pending.timerID) }
            }
        }
    }
    var onForegroundDelivery: (@MainActor @Sendable (UUID) -> Void)? {
        get { lock.withLock { storedForegroundHandler } }
        set { lock.withLock { storedForegroundHandler = newValue } }
    }

    var authorization: NotificationAuthorization {
        lock.withLock { storedAuthorization }
    }

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        registerCategory()
        refreshAuthorization()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.setAuthorization(granted ? .allowed : .denied)
        }
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            let state: NotificationAuthorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .allowed
            case .denied:
                state = .denied
            case .notDetermined:
                state = .unknown
            @unknown default:
                state = .denied
            }
            self?.setAuthorization(state)
        }
    }

    func schedule(
        _ notification: TimerNotification,
        completion: @escaping @Sendable (TimerNotificationScheduleResult) -> Void
    ) {
        guard authorization == .allowed else {
            completion(.failure("Notification permission is not available."))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notification.stepName
        content.body = "Timer finished."
        content.sound = .default
        content.categoryIdentifier = TimerNotification.categoryIdentifier
        content.userInfo = ["timerID": notification.timerID.uuidString]
        let interval = max(1, notification.deadline.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: notification.timerID.uuidString,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                completion(.failure(error.localizedDescription))
            } else {
                completion(.success)
            }
        }
    }

    func removePending(timerID: UUID) {
        let identifier = timerID.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func removeAll(timerID: UUID) {
        let identifier = timerID.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let timerID = timerID(from: notification.request.content.userInfo) {
            let callback = onForegroundDelivery
            await MainActor.run { callback?(timerID) }
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let timerID = timerID(from: response.notification.request.content.userInfo) else { return }
        let identifier = response.actionIdentifier
        let callback: (@MainActor @Sendable (String, UUID) -> Void)? = lock.withLock {
            guard let storedActionHandler else {
                pendingAction = (identifier, timerID)
                return nil
            }
            return storedActionHandler
        }
        if let callback {
            await MainActor.run { callback(identifier, timerID) }
        }
    }

    private func registerCategory() {
        let extendTwo = UNNotificationAction(
            identifier: TimerNotification.extendTwoActionIdentifier,
            title: "+2 minutes",
            options: []
        )
        let extendFive = UNNotificationAction(
            identifier: TimerNotification.extendFiveActionIdentifier,
            title: "+5 minutes",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: TimerNotification.categoryIdentifier,
                actions: [extendTwo, extendFive],
                intentIdentifiers: []
            ),
        ])
    }

    private func setAuthorization(_ state: NotificationAuthorization) {
        lock.withLock { storedAuthorization = state }
        let callback = lock.withLock { storedAuthorizationHandler }
        Task { @MainActor in callback?(state) }
    }

    private func timerID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["timerID"] as? String).flatMap(UUID.init(uuidString:))
    }
}
#endif
