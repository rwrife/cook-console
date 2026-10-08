import XCTest
@testable import CookConsole

final class IdleTimerPolicyTests: XCTestCase {
    func testIdleOverrideRequiresAllThreeConditions() {
        for preference in [false, true] {
            for cook in [false, true] {
                for foreground in [false, true] {
                    XCTAssertEqual(
                        IdleTimerPolicy.shouldDisableIdleTimer(
                            keepAwakeEnabled: preference,
                            cookSurfaceActive: cook,
                            sceneActive: foreground
                        ),
                        preference && cook && foreground,
                        "preference=\(preference), cook=\(cook), foreground=\(foreground)"
                    )
                }
            }
        }
    }
}
