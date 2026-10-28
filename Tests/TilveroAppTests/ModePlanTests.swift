import XCTest
import PowerCore
@testable import TilveroApp

@MainActor final class ModePlanTests: XCTestCase {
    // Catches accidentally coupling Save or relaunch to control application.
    func testSavePersistsDraftButNeverAppliesIt() async throws {
        let suite = "TilveroModes-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let before = model.control?.charge
        var draft = model.modeLibrary.plan(.economy)
        draft.chargeTarget = 90; draft.displayIdleMinutes = 7; draft.brightnessPercent = 55
        try model.saveMode(draft)
        XCTAssertEqual(model.control?.charge, before)
        XCTAssertNil(model.modeReport)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.modeLibrary.plan(.economy), draft)
        XCTAssertNil(reopened.modeReport, "Saved plans are never auto-applied on launch")
    }

    // Catches a partial native charge action falsely reporting a complete economy mode.
    func testPreviewExcludesUnsupportedActionsAndPreservesJobs() throws {
        var plan = ModeLibrary().plan(.maximum)
        plan.chargeTarget = 90; plan.brightnessPercent = 40
        let preview = plan.preview(chargeTargets: [80,90,100], chargeAvailable: true, restoreAvailable: false)
        XCTAssertEqual(preview.first { $0.action == .charge }?.status, .available)
        XCTAssertEqual(preview.first { $0.action == .energy }?.status, .excluded)
        XCTAssertEqual(preview.first { $0.action == .brightness }?.status, .excluded)
        XCTAssertEqual(preview.first { $0.action == .displayIdle }?.status, .excluded)
        XCTAssertEqual(preview.first { $0.action == .backgroundJobs }?.status, .preserved)
        XCTAssertEqual(plan.preview(chargeTargets: [80,100], chargeAvailable: true, restoreAvailable: false)
            .first { $0.action == .charge }?.status, .excluded)
    }

    func testNormalPreviewDoesNotClaimCoolingIsPreservedDuringOwnedRestoration() {
        let rows = ModeLibrary().plan(.normal).preview(chargeTargets: [], chargeAvailable: false, restoreAvailable: true)
        XCTAssertEqual(rows.first { $0.action == .restore }?.status, .available)
        XCTAssertNil(rows.first { $0.action == .cooling }, "Normal restoration includes all owned resources; cooling cannot be promised unchanged")
    }

    // Catches invalid saved values leaking into control requests.
    func testInvalidDraftIsRejectedWithoutReplacingSavedPlan() throws {
        let suite = "TilveroModes-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        let before = model.modeLibrary
        for (charge, idle, brightness) in [(79,5,50),(90,0,50),(90,5,101)] {
            var draft = before.plan(.economy)
            draft.chargeTarget = charge; draft.displayIdleMinutes = idle; draft.brightnessPercent = brightness
            XCTAssertThrowsError(try model.saveMode(draft))
            XCTAssertEqual(model.modeLibrary, before)
        }
    }

    // Uses the real simulator boundary: only an explicit Apply changes charge intent.
    func testExplicitApplyReportsPendingChargeAndExclusionsSeparately() async throws {
        let suite = "TilveroModes-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        model.demoPercent = 98
        await model.refresh()
        model.setDraft(90); model.applyDemoTarget()
        for _ in 0..<100 where model.isApplying { await Task.yield() }
        XCTAssertNotNil(model.notice)
        var draft = model.modeLibrary.plan(.economy); draft.chargeTarget = 80
        try model.saveMode(draft)
        await model.applyMode(.economy)
        XCTAssertNil(model.notice, "An old action notice must not contradict the new per-action report")
        XCTAssertEqual(model.control?.charge.pendingTarget, 80)
        XCTAssertEqual(model.control?.charge.appliedTarget, 100)
        XCTAssertEqual(model.modeReport?.rows.first { $0.action == .charge }?.status, .pending)
        XCTAssertEqual(model.modeReport?.rows.first { $0.action == .energy }?.status, .excluded)
        XCTAssertFalse(model.modeReport?.isComplete ?? true)
        await model.applyMode(.normal)
        XCTAssertNil(model.control?.charge.pendingTarget)
        XCTAssertNil(model.control?.charge.requested)
    }
}
