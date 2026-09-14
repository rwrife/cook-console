import XCTest

@testable import CookConsole

final class AppInfoTests: XCTestCase {
    func testBundleIDMatchesRegisteredAppID() {
        XCTAssertEqual(AppInfo.bundleID, "com.infinityball.cookconsole")
    }

    func testMinimumOSMatchesIOS26Pin() {
        XCTAssertEqual(AppInfo.minimumOSMajor, 26,
                       "PLAN.md pins the project to the iOS 26 SDK")
    }

    func testAppDeclaresNoNetworking() {
        XCTAssertFalse(AppInfo.usesNetworking,
                       "MVP is local-first: zero network surface")
    }
}
