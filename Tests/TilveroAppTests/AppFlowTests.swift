import XCTest
import Foundation
@testable import TilveroApp
import PowerCore

@MainActor
final class AppFlowTests: XCTestCase {
    func testDraftChangesNeverApplyUntilExplicitActionAndDismissDiscards() async throws {
        let suite = "TilveroTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let before = model.control!.charge
        for target in 0..<300 { model.setDraft(80 + target % 21) }
        XCTAssertEqual(model.control?.charge, before)
        XCTAssertTrue(model.canApply)
        model.discardDraft()
        XCTAssertEqual(model.draftTarget, before.appliedTarget ?? 80)
        model.demoPercent = 98
        await model.refresh()
        model.setDraft(80)
        model.applyDemoTarget()
        // Await the app's bounded asynchronous action, not a physical backend.
        for _ in 0..<100 where model.isApplying { await Task.yield() }
        XCTAssertEqual(model.control?.charge.pendingTarget, 80)
        XCTAssertEqual(model.control?.charge.appliedTarget, 100)
        XCTAssertEqual(model.snapshot.chargePercent.value, 98)
    }

    func testLiveRefreshPersistsReadingsAcrossStoreReopenWithoutSimulatorOrControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("History.sqlite")
        let suite = "TilveroTests.\(UUID().uuidString)"; let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let first = TilveroModel(isDemo: false, preferences: preferences, historyURL: url, snapshotProvider: {
            BatterySnapshot(chargePercent: .init(value: 73, source: "fixture", freshness: .fresh), isExternalPower: .init(value: false, source: "fixture"))
        })
        await first.refresh()
        XCTAssertNil(first.control)
        XCTAssertFalse(first.canEdit)
        XCTAssertEqual(first.history.last?.chargePercent, 73)
        first.stop()
        let second = TilveroModel(isDemo: false, preferences: preferences, historyURL: url)
        XCTAssertEqual(second.history.last?.chargePercent, 73)
        XCTAssertNil(second.control)
        second.stop()
    }
}

@MainActor
final class QuickPanelDraftLifecycleTests: XCTestCase {
    func testDismissDiscardsDraftUnlessAnotherVisibleChargingEditorOwnsIt() async throws {
        let suite = "TilveroTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let original = model.control!.charge
        for (detailVisible, section, expected) in [(false, InfoSection.overview, 100), (true, .overview, 100), (true, .charging, 85)] {
            model.isDetailVisible = detailVisible
            model.selectedSection = section
            model.isPopoverVisible = true
            model.setDraft(85)
            model.quickPanelDidClose()
            XCTAssertFalse(model.isPopoverVisible)
            XCTAssertEqual(model.draftTarget, expected)
            XCTAssertEqual(model.control?.charge, original, "Dismissing an editor cannot submit a control operation.")
        }
    }
}

@MainActor
final class MenuBarSizingPreferenceTests: XCTestCase {
    func testSizingPersistsAndInvalidScaleCannotMutateMeasurementsOrPolicy() async throws {
        let suite = "TilveroTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let reading = model.snapshot.chargePercent
        let policy = model.control!.charge
        model.menuBarTextSize = .larger
        model.setMenuBarIconScale(0.95)
        let restored = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(restored.menuBarTextSize, .larger)
        XCTAssertEqual(restored.menuBarIconScale, 0.95)
        model.setMenuBarIconScale(.nan)
        XCTAssertEqual(model.menuBarIconScale, 1)
        XCTAssertEqual(model.snapshot.chargePercent, reading)
        XCTAssertEqual(model.control?.charge, policy)
        model.resetMenuBarSizing()
        XCTAssertEqual(model.menuBarTextSize, .system)
        XCTAssertEqual(model.menuBarIconScale, 1)
    }
}
