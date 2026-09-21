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

    /// Marketing version shown in backup/CSV provenance headers. SPM test
    /// bundles carry no Info.plist version, hence the "dev" fallback.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Build number alongside the marketing version for exact provenance.
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// Provenance string embedded in export documents: "1.0 (build 1)".
    static var versionStamp: String {
        "\(version) (build \(buildNumber))"
    }
}
