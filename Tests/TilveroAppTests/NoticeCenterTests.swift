// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class NoticeCenterTests: XCTestCase {
    func testTheNewestNoticeShowsAndAnOlderOneReturnsWhenItGoes() {
        let center = NoticeCenter()
        XCTAssertNil(center.current())
        center.post("Keep Awake failed", from: .keepAwake)
        center.post("Export saved", from: .data)
        XCTAssertEqual(center.current()?.text, "Export saved", "The newest notice is the one shown")
        center.clear(.data)
        XCTAssertEqual(center.current()?.text, "Keep Awake failed", "Another feature's notice was kept, not erased")
        center.clear(.control)
        XCTAssertEqual(center.current()?.text, "Keep Awake failed", "Clearing one source never touches another")
    }

    func testRecoveryIsShownBeforeNewerNotices() {
        let center = NoticeCenter()
        center.post("Recovery required", from: .recovery)
        center.post("Simulation only", from: .simulation)
        center.post("Operation failed", from: .control)
        XCTAssertEqual(center.current()?.text, "Recovery required", "A later profile or charge result cannot hide it")
        XCTAssertEqual(center.current(excluding: [.recovery])?.text, "Operation failed")
    }

    func testAControlResultReplacesTheEarlierControlLinesOnly() {
        let center = NoticeCenter()
        center.post("Keep Awake failed", from: .keepAwake)
        center.post("Waiting for natural discharge", from: .chargeStatus)
        center.post("The limit could not be applied", from: .control)
        XCTAssertNil(center.notices[.chargeStatus], "A newer apply outdates the pending line")
        center.post("Simulation only", from: .simulation)
        XCTAssertNil(center.notices[.control], "…and the previous failure")
        XCTAssertEqual(center.notices[.keepAwake]?.text, "Keep Awake failed")
    }

    func testLeavingThePageKeepsOnlyNoticesThatWaitForTheirSource() {
        let center = NoticeCenter()
        center.post("Keep Awake failed", from: .keepAwake)
        center.post("Recovery required", from: .recovery)
        center.post("Export saved", from: .data)
        center.clearPageNotices()
        XCTAssertEqual(Set(center.notices.keys), [.keepAwake], "A Keep Awake failure stays on every tab until it is resolved")
    }

    func testAnExpiringNoticeRemovesOnlyItselfAndCancelledExpiriesNeverFire() async throws {
        let center = NoticeCenter()
        center.post("Refused", from: .control, expiresAfter: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(center.current(), "A one-off refusal goes away on its own")

        center.post("Refused", from: .control, expiresAfter: .milliseconds(80))
        center.post("Refused", from: .control)   // the same text again, without an expiry
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(center.current()?.text, "Refused", "An expiry never removes the notice that replaced its own")

        center.post("Refused", from: .control, expiresAfter: .milliseconds(50))
        center.cancelExpiries()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(center.current()?.text, "Refused", "A stopped model leaves its last notice untouched")
    }

    func testARecoveryNoticeSurvivesALaterTypedDraftError() {
        let model = TilveroModel(isDemo: true, preferences: makeTestDefaults("Notices").defaults)
        defer { model.stop() }
        model.notices.post(L10n.text("Recovery required"), from: .recovery)
        model.draftText = "invalid"
        XCTAssertFalse(model.validateTypedDraft())
        XCTAssertEqual(model.notice, L10n.text("Recovery required"), "The single notice line used to lose it to the later message")
        model.dismissActionNotice()
        XCTAssertNil(model.notice)
    }
}
