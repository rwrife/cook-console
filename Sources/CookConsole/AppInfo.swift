import Foundation

/// Static app metadata. Kept free of any UI or framework imports beyond
/// Foundation so it is trivially unit-testable from the test target.
enum AppInfo {
    /// Bundle identifier registered in App Store Connect.
    static let bundleID = "com.infinityball.cookconsole"

    /// Minimum supported OS per PLAN.md — the iOS 26 SDK is a hard pin.
    static let minimumOSMajor = 26

    /// Local-first promise asserted by tests and the CI network gate.
    static let usesNetworking = false
}
