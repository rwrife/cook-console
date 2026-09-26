import Foundation

/// Pure policy for notification-permission messaging.
///
/// Centralizing this keeps permission behavior deterministic and testable on
/// Linux while SwiftUI remains a projection layer.
enum NotificationPermissionGuidance {
    static let deniedFallbackMessage =
        "Notifications are off. Keep Cook Console open for on-screen timer alerts."

    static let settingsLinkLabel = "Open Notification Settings"

    static func message(for authorization: NotificationAuthorization) -> String? {
        authorization == .denied ? deniedFallbackMessage : nil
    }

    static func showsSettingsLink(for authorization: NotificationAuthorization) -> Bool {
        authorization == .denied
    }
}
