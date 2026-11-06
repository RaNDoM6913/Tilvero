// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerPrivileged
@testable import ClosedLidControl

final class ClosedLidTrustTests: XCTestCase {
    func testExactRoleRequirementPassedToVerifierAndWrongRoleDenied() throws {
        let configuration = try HelperTrustConfiguration(teamID: "ABCDEFGHIJ", appIdentifier: "local.tilvero.lid.lab", helperIdentifier: "local.tilvero.lid.helper")
        let trust = ClosedLidTrust(configuration: configuration, verifyRequirement: { requirement in
            guard requirement == configuration.helperRequirement else { throw ClosedLidFailure.missingTrust }
        })
        XCTAssertNoThrow(try trust.verify(helper: true))
        XCTAssertThrowsError(try trust.verify(helper: false))
        XCTAssertTrue(trust.appRequirement.contains("anchor apple generic"))
    }
    func testMissingLidMetadataDoesNotFallBackToProductionKeys() throws {
        XCTAssertThrowsError(try ClosedLidTrust.fromMetadata(["TilveroTeamIdentifier": "ABCDEFGHIJ", "TilveroAppIdentifier": "local.tilvero.app", "TilveroHelperIdentifier": "local.tilvero.helper"]))
        XCTAssertThrowsError(try ClosedLidTrust(teamID: "ABCDEFGHIJ", appIdentifier: "local.tilvero.app\" or true", helperIdentifier: "local.tilvero.helper"))
        XCTAssertThrowsError(try ClosedLidTrust(teamID: "ABCDEFGHIJ", appIdentifier: "local.tilvero.app", helperIdentifier: "local.tilvero.app"))
    }
    func testConsoleBindingDeniesUnknownSystemAndSwitchedUser() throws {
        XCTAssertNoThrow(try ClosedLidTrust.validateConsolePeer(userID: 501, activeUserID: 501))
        for (uid, active) in [(UInt32(0), UInt32(0)), (501,502)] {
            XCTAssertThrowsError(try ClosedLidTrust.validateConsolePeer(userID: uid, activeUserID: active))
        }
        XCTAssertThrowsError(try ClosedLidTrust.validateConsolePeer(userID: 501, activeUserID: nil))
    }
}
