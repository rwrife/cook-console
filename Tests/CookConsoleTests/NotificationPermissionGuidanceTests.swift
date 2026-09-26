import XCTest
@testable import CookConsole

/// Issue #17: the app must explain notification permission status and offer
/// a Settings route when permission is denied, with a clear in-app fallback
/// otherwise. This pure domain function drives both the fallback banner text
/// and the visibility of the Settings link so the policy is Linux-testable
/// and the SwiftUI layer is a dumb projection of it.
final class NotificationPermissionGuidanceTests: XCTestCase {
    func testDeniedShowsFallbackMessageAndSettingsLink() {
        XCTAssertEqual(
            NotificationPermissionGuidance.message(for: .denied),
            "Notifications are off. Keep Cook Console open for on-screen timer alerts."
        )
        XCTAssertTrue(NotificationPermissionGuidance.showsSettingsLink(for: .denied))
    }

    func testUnknownAndAllowedShowNeitherMessageNorSettingsLink() {
        for state: NotificationAuthorization in [.unknown, .allowed] {
            XCTAssertNil(NotificationPermissionGuidance.message(for: state))
            XCTAssertFalse(NotificationPermissionGuidance.showsSettingsLink(for: state))
        }
    }

    func testSettingsLinkLabelIsStableForUITestIdentification() {
        XCTAssertEqual(NotificationPermissionGuidance.settingsLinkLabel, "Open Notification Settings")
    }
}
