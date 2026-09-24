import Foundation
import Testing

@testable import CookConsole

/// Issue #8 release-pipeline invariants that can be proven WITHOUT macOS:
/// the repo-root VERSION seed, the generated project's version + signing +
/// icon build settings, and the bundle id all agree with AppInfo. The
/// release workflow and docs/release.md depend on exactly these couplings.
@Suite("Release versioning invariants")
struct VersioningTests {
    /// Repo root as seen from this file (Tests/CookConsoleTests/).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VersioningTests.swift
            .deletingLastPathComponent() // CookConsoleTests
            .deletingLastPathComponent() // Tests
    }

    private func read(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    @Test("VERSION file holds a strict semver x.y.z")
    func versionFileIsSemver() throws {
        let version = try read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3, "VERSION must be x.y.z, got '\(version)'")
        for part in parts {
            #expect(!part.isEmpty && part.allSatisfy(\.isNumber), "VERSION component '\(part)' is not numeric")
        }
    }

    @Test("pbxproj MARKETING_VERSION matches the VERSION file")
    func marketingVersionMatches() throws {
        let version = try read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        let pbx = try read("CookConsole.xcodeproj/project.pbxproj")
        let lines = pbx.split(separator: "\n").filter { $0.contains("MARKETING_VERSION") }
        #expect(!lines.isEmpty, "project must define MARKETING_VERSION")
        for line in lines {
            #expect(line.contains("= \(version);"), "MARKETING_VERSION line '\(line)' != VERSION \(version)")
        }
    }

    @Test("pbxproj pins a baseline CURRENT_PROJECT_VERSION")
    func projectVersionSeeded() throws {
        let pbx = try read("CookConsole.xcodeproj/project.pbxproj")
        // The release workflow overrides this with the run number; the
        // project itself must still carry a valid numeric baseline.
        #expect(pbx.contains("CURRENT_PROJECT_VERSION = 1;"))
    }

    @Test("app target signs the registered bundle id and ships the icon")
    func bundleAndIconWired() throws {
        let pbx = try read("CookConsole.xcodeproj/project.pbxproj")
        #expect(pbx.contains("PRODUCT_BUNDLE_IDENTIFIER = \(AppInfo.bundleID);"))
        #expect(pbx.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        #expect(pbx.contains("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;"))
        #expect(pbx.contains("Assets.xcassets"))
    }

    @Test("asset catalog icon is the single 1024 universal master")
    func iconCatalogIsValid() throws {
        let contents = try read("Resources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        struct Catalog: Decodable {
            struct Image: Decodable {
                let filename: String
                let idiom: String
                let platform: String
                let size: String
            }
            let images: [Image]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contents.utf8))
        #expect(catalog.images.count == 1)
        let image = catalog.images[0]
        #expect(image.size == "1024x1024")
        #expect(image.idiom == "universal")
        #expect(image.platform == "ios")
        let png = repoRoot
            .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
            .appendingPathComponent(image.filename)
        let data = try Data(contentsOf: png)
        // PNG magic bytes + IHDR width (bytes 16..19 big-endian) == 1024.
        #expect(data.count > 24)
        #expect([UInt8](data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let width = data.subdata(in: 16..<20).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(width == 1024)
    }

    @Test("release runbook documents the tag flow")
    func releaseDocExists() throws {
        let doc = try read("docs/release.md")
        for required in ["VERSION", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "ASC_TEAM_ID", "TestFlight", "v1.0.0"] {
            #expect(doc.contains(required), "docs/release.md must document '\(required)'")
        }
    }
}
