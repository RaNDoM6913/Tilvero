// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import PowerCore

/// One test per row of the lid watchdog's decision table.
final class LidWatchdogPolicyTests: XCTestCase {
    private func decide(_ signal: LidWatchdogSignal, _ marker: LidWatchdogMarkerOwnership, _ sleepDisabled: Bool?, attempts: Int = 0) -> LidWatchdogDecision {
        LidWatchdogPolicy.decide(signal: signal, marker: marker, sleepDisabled: sleepDisabled, clearAttempts: attempts)
    }

    func testTheReleaseByteExitsWithoutDoingAnything() {
        for marker in [LidWatchdogMarkerOwnership.absent, .foreign, .own] {
            for reading in [true, false, nil] as [Bool?] {
                XCTAssertEqual(decide(.released, marker, reading), .exit)
            }
        }
    }

    func testAFailedPipeNeverActs() {
        XCTAssertEqual(decide(.pipeFailed, .own, true), .exit, "The app may still be alive: never fight a live session.")
        XCTAssertEqual(decide(.pipeFailed, .own, nil), .exit)
    }

    func testEndOfFileWithoutAMarkerExits() {
        XCTAssertEqual(decide(.endOfFile, .absent, true), .exit, "The app restored, or launch recovery already did.")
        XCTAssertEqual(decide(.endOfFile, .absent, nil), .exit)
    }

    func testEndOfFileWithAForeignTokenExits() {
        XCTAssertEqual(decide(.endOfFile, .foreign, true), .exit, "A newer session owns the override.")
        XCTAssertEqual(decide(.endOfFile, .foreign, false), .exit)
    }

    func testOwnTokenWithSleepAlreadyNormalOnlyFinishes() {
        XCTAssertEqual(decide(.endOfFile, .own, false), .finish)
    }

    func testOwnTokenWithSleepDisabledRestoresComfortThenClears() {
        XCTAssertEqual(decide(.endOfFile, .own, true), .clear(restoreComfortFirst: true))
    }

    func testOwnTokenWithAnUnreadableStateIsTreatedAsDisabled() {
        XCTAssertEqual(decide(.endOfFile, .own, nil), .clear(restoreComfortFirst: true))
    }

    func testAConfirmedZeroAfterTheWriteFinishes() {
        XCTAssertEqual(decide(.endOfFile, .own, false, attempts: 1), .finish)
        XCTAssertEqual(decide(.endOfFile, .own, false, attempts: 4), .finish)
    }

    func testRetriesClearAgainWithoutASecondComfortRestore() {
        for attempts in 1..<LidWatchdogPolicy.maximumClearAttempts {
            XCTAssertEqual(decide(.endOfFile, .own, true, attempts: attempts), .clear(restoreComfortFirst: false))
            XCTAssertEqual(decide(.endOfFile, .own, nil, attempts: attempts), .clear(restoreComfortFirst: false))
        }
    }

    func testStillDisabledAfterFiveAttemptsGivesUpAndKeepsTheMarker() {
        XCTAssertEqual(LidWatchdogPolicy.maximumClearAttempts, 5)
        XCTAssertEqual(decide(.endOfFile, .own, true, attempts: 5), .giveUp)
        XCTAssertEqual(decide(.endOfFile, .own, nil, attempts: 5), .giveUp)
        XCTAssertEqual(decide(.endOfFile, .own, true, attempts: 9), .giveUp)
    }

    // MARK: Marker codec

    func testTheMarkerRoundTripsWithTheDocumentedFields() throws {
        let marker = LidOverrideMarker(token: UUID().uuidString, pid: 4242, createdAt: Date(timeIntervalSince1970: 1_800_000_000), boot: "BOOT-UUID")
        let data = try marker.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "token", "pid", "createdAt", "boot"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(LidOverrideMarker.decode(data), marker)
    }

    func testAnythingButAVersionOneMarkerWithATokenIsRejected() throws {
        XCTAssertNil(LidOverrideMarker.decode(Data("garbage".utf8)))
        XCTAssertNil(LidOverrideMarker.decode(Data(#"{"v":2,"token":"x","pid":1,"createdAt":"2027-01-15T08:00:00Z"}"#.utf8)))
        XCTAssertNil(LidOverrideMarker.decode(Data(#"{"v":1,"token":"","pid":1,"createdAt":"2027-01-15T08:00:00Z"}"#.utf8)))
        XCTAssertNotNil(LidOverrideMarker.decode(Data(#"{"v":1,"token":"t","pid":1,"createdAt":"2027-01-15T08:00:00Z"}"#.utf8)),
                        "The boot id is diagnostic only and may be missing.")
    }
}
