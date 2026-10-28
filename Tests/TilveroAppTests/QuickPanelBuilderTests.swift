import XCTest
import AppKit
import SwiftUI
@testable import TilveroApp

@MainActor final class QuickPanelBuilderTests: XCTestCase {
    func testLegacyLayoutKeepsOrderAndHiddenWhileNewBlocksStayOptional() throws {
        let data = Data(#"{"order":["history","temperature","forecast","power"],"hidden":["forecast"]}"#.utf8)
        let value = OverviewPreferences.load(data)
        XCTAssertEqual(value.order.map(\.rawValue), ["history","temperature","forecast","power","chargeLimit","keepAwake","systemPower","adapter","batteryHealth","applications"])
        XCTAssertEqual(value.hidden, [.forecast,.chargeLimit,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications])
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(value)), value)
    }
    func testUnknownAndDuplicateIDsDoNotResetKnownComposition() {
        let value = OverviewPreferences.load(Data(#"{"order":["temperature","future","temperature","history","power","forecast"],"hidden":["power","future"]}"#.utf8))
        XCTAssertEqual(value.order.map(\.rawValue), ["temperature","history","power","forecast","chargeLimit","keepAwake","systemPower","adapter","batteryHealth","applications"])
        XCTAssertEqual(value.hidden, [.power,.chargeLimit,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications])
    }
    func testAcceptedLocalDropMovesHiddenRowsBothDirectionsAndRejectsForeignPayload() {
        var value = OverviewPreferences()
        value.hidden.insert(.power)
        let first = OverviewDragSession(source: .forecast)
        XCTAssertFalse(value.acceptDrop("forecast", session: first, onto: .history))
        XCTAssertEqual(value.order.first, .forecast)
        XCTAssertTrue(value.acceptDrop(first.payload, session: first, onto: .history))
        XCTAssertEqual(Array(value.order.prefix(4)), [.power,.temperature,.history,.forecast])
        let second = OverviewDragSession(source: .forecast)
        XCTAssertFalse(value.acceptDrop(first.payload, session: second, onto: .power))
        XCTAssertTrue(value.acceptDrop(second.payload, session: second, onto: .power))
        XCTAssertEqual(Array(value.order.prefix(4)), [.forecast,.power,.temperature,.history])
        XCTAssertFalse(value.acceptDrop(second.payload, session: second, onto: .forecast))
        XCTAssertTrue(value.hidden.contains(.power))
    }
    func testCancelledOrCompletedSourceCannotAuthorizeAReplayedExternalDrop() {
        var lifetime = OverviewDragState(), preferences = OverviewPreferences()
        let original = preferences
        let cancelled = lifetime.begin(.forecast)
        lifetime.end()
        XCTAssertNil(lifetime.prepareDrop())
        XCTAssertFalse(lifetime.completeDrop(cancelled.payload, session: cancelled, onto: .history, preferences: &preferences))
        XCTAssertEqual(preferences, original)
        let accepted = lifetime.begin(.forecast)
        XCTAssertEqual(lifetime.prepareDrop()?.payload, accepted.payload)
        lifetime.end() // Native source-end precedes asynchronous provider completion.
        XCTAssertTrue(lifetime.completeDrop(accepted.payload, session: accepted, onto: .history, preferences: &preferences))
        XCTAssertEqual(preferences.order.first, .power)
        XCTAssertFalse(lifetime.completeDrop(accepted.payload, session: accepted, onto: .power, preferences: &preferences))
        let stale = lifetime.begin(.power)
        _ = lifetime.prepareDrop()
        _ = lifetime.begin(.history) // A new source invalidates an old pending callback.
        XCTAssertFalse(lifetime.completeDrop(stale.payload, session: stale, onto: .forecast, preferences: &preferences))
        lifetime.end()
    }
    func testPassivePreviewAndBuilderPersistWithoutApplyingActions() async throws {
        let suite = "TilveroBuilder-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let original = model.control?.charge
        model.overviewPreferences.move(.history, by: -1)
        model.overviewPreferences.hidden.insert(.temperature)
        let host = NSHostingController(rootView: QuickPanelBuilder(model: model))
        _ = host.sizeThatFits(in: NSSize(width: 720, height: 1200))
        XCTAssertEqual(model.control?.charge, original)
        XCTAssertNil(model.nativeCharge.observed)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.overviewPreferences, model.overviewPreferences)
    }
}
