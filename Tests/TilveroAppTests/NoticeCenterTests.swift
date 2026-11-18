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

    func testANewerControlResultReplacesAStaleRecoveryLine() {
        let center = NoticeCenter()
        center.post("Recovery required", from: .recovery)
        center.post("Export saved", from: .data)
        XCTAssertEqual(center.current()?.text, "Export saved", "The newest notice shows")
        center.clear(.data)
        XCTAssertEqual(center.current()?.text, "Recovery required", "An unrelated notice never erased it")
        center.post("Owned settings restored.", from: .control)
        XCTAssertNil(center.notices[.recovery], "A later control result replaces the recovery line, as the single line did")
        XCTAssertEqual(center.current()?.text, "Owned settings restored.")
    }

    func testAnExcludedNewestNoticeHidesTheLineInsteadOfShowingAnOlderOne() {
        let center = NoticeCenter()
        center.post("Export saved", from: .data)
        center.post("Waiting for natural discharge", from: .chargeStatus)
        XCTAssertNil(center.current(excluding: [.chargeStatus]), "A surface that leaves out the newest line shows nothing")
        XCTAssertEqual(center.current()?.text, "Waiting for natural discharge")
        center.clear(.chargeStatus)
        XCTAssertEqual(center.current(excluding: [.chargeStatus])?.text, "Export saved")
    }

    func testAControlResultReplacesTheEarlierControlLinesOnly() {
        let center = NoticeCenter()
        center.post("Keep Awake failed", from: .keepAwake)
        center.post("Waiting for natural discharge", from: .chargeStatus)
        center.post("The limit could not be applied", from: .control)
        XCTAssertNil(center.notices[.chargeStatus], "A newer apply outdates the pending line")
        center.post("Simulation only", from: .simulation)
        XCTAssertNil(center.notices[.control], "…and the previous failure")
        center.post("Recovery required", from: .recovery)
        XCTAssertNil(center.notices[.simulation], "Recovery belongs to the same control state")
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

    func testARecoveryNoticeGoesWithTheNextControlResultAndKeepAwakeSurvivesIt() {
        let model = TilveroModel(isDemo: true, preferences: makeTestDefaults("Notices").defaults)
        defer { model.stop() }
        model.notices.post("Keep Awake failed", from: .keepAwake)
        model.notices.post(L10n.text("Recovery required"), from: .recovery)
        model.draftText = "invalid"
        XCTAssertFalse(model.validateTypedDraft())
        XCTAssertEqual(model.notice, L10n.text("Unsupported percentage. Choose an available step."))
        XCTAssertNil(model.notices.notices[.recovery], "The newer charge result replaced the stale recovery line")
        model.dismissActionNotice()
        XCTAssertEqual(model.notice, "Keep Awake failed", "Only the Keep Awake failure waits for its source")
    }
}
