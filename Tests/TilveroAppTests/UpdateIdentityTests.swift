// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class UpdateIdentityTests: XCTestCase {
    func testIdentityReadsOnlyRunningBundleMetadataAndNeverPromotesKnownPrivateProfiles() {
        for (identifier, expected) in [
            ("local.tilvero.prototype", UpdateBuildProfile.development),
            ("local.tilvero.lab", .lab), ("local.tilvero.lidtrial", .trial),
            ("unknown.tilvero", .manual)
        ] {
            let identity = UpdateIdentity(info: ["CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "3",
                "TilveroReleaseMode": "monitoring", "TilveroDataScope": "production"])
            XCTAssertEqual(identity.profile, expected)
            XCTAssertEqual(identity.version, "0.1.0")
            XCTAssertEqual(identity.build, "3")
            XCTAssertFalse(identity.supportsInstallerProfile)
        }
    }

    func testProductionProfileRequiresExactIdentityModeAndScope() {
        let metadata = ["CFBundleIdentifier": "io.github.random6913.tilvero",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "3",
            "TilveroReleaseMode": "monitoring", "TilveroDataScope": "production"]
        XCTAssertTrue(UpdateIdentity(info: metadata).supportsInstallerProfile)
        for key in ["TilveroReleaseMode", "TilveroDataScope"] {
            var invalid = metadata; invalid[key] = "controller"
            XCTAssertFalse(UpdateIdentity(info: invalid).supportsInstallerProfile)
        }
        var missing = metadata; missing.removeValue(forKey: "CFBundleVersion")
        XCTAssertFalse(UpdateIdentity(info: missing).supportsInstallerProfile)
        XCTAssertNil(UpdateIdentity(info: [:]).build)
    }

    func testMonotonicBuildComparisonDoesNotOverflowOrLexicallyOrder() {
        XCTAssertEqual(UpdateIdentity.compareBuilds("10", "9"), .orderedDescending)
        XCTAssertEqual(UpdateIdentity.compareBuilds(String(repeating: "9", count: 80), "999"), .orderedDescending)
        XCTAssertEqual(UpdateIdentity.compareBuilds("3", "3"), .orderedSame)
        for invalid in ["", "0", "01", "-1", "1.1", " 3", "3beta"] {
            XCTAssertNil(UpdateIdentity.compareBuilds(invalid, "3"))
        }
    }

    func testChannelDefaultUsesImmutableMetadataAndPrivateBuildsCanDiscoverBetaSources() {
        XCTAssertEqual(UpdateIdentity(info: ["CFBundleIdentifier": "local.tilvero.prototype"]).defaultChannel, .beta)
        XCTAssertEqual(UpdateIdentity(info: ["CFBundleIdentifier": "io.github.random6913.tilvero"]).defaultChannel, .stable)
        XCTAssertEqual(UpdateIdentity(info: ["TilveroReleaseChannel": "beta"]).defaultChannel, .beta)
    }
}
