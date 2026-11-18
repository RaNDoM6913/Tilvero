// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Combine
import Observation
import XCTest
@testable import TilveroApp

private final class Flag: @unchecked Sendable { var fired = false }

@MainActor final class ModelObservationTests: XCTestCase {
    private func fires(_ read: () -> Void, when change: () throws -> Void) rethrows -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        try change()
        return flag.fired
    }

    /// The change signal reads `trackedKeyPaths`; a tracked property missing from it would change without the popover
    /// host's safety net or Setup ever hearing of it.
    func testEveryTrackedPropertyIsInTheChangeSignal() {
        let model = TilveroModel(isDemo: true, preferences: makeTestDefaults("Observation").defaults)
        defer { model.stop() }
        let storage = Set(Mirror(reflecting: model).children.compactMap(\.label)
            .filter { $0.hasPrefix("_") && !$0.hasPrefix("_$") }.map { String($0.dropFirst()) })
        let listed = Set(TilveroModel.trackedKeyPaths.map { String(describing: $0).components(separatedBy: ".").last ?? "" })
        XCTAssertFalse(storage.isEmpty)
        XCTAssertEqual(storage.subtracting(listed), [], "Tracked properties missing from TilveroModel.trackedKeyPaths")
        XCTAssertEqual(listed.subtracting(storage), ["sleepAtChargeChoice", "keepAwakeUntilChargeChoice"],
                       "Only the two preference-backed choices are listed without storage of their own")
    }

    func testAServiceChangeReachesOnlyReadersOfThatService() throws {
        let model = TilveroModel(isDemo: false, preferences: makeTestDefaults("Observation").defaults,
                                 snapshotProvider: { .unavailable(reason: "fixture") }, keepAwakeService: KeepAwakeService(driver: AwakeFixture()))
        defer { model.stop() }
        XCTAssertTrue(try fires({ _ = model.keepAwake.hasOwnedAssertion }, when: { try model.keepAwake.start(seconds: 600) }),
                      "Reading the service through the model observes it")
        XCTAssertTrue(try fires({ _ = model.canStartKeepAwakeDraft }, when: { try model.keepAwake.stop() }),
                      "So does a derived property that reads it")
        XCTAssertFalse(try fires({ _ = model.processActivity; _ = model.history; _ = model.snapshot; _ = model.canEdit },
                                 when: { try model.keepAwake.start(seconds: 600) }),
                       "A Keep Awake change no longer re-renders views that never read Keep Awake")
        XCTAssertFalse(fires({ _ = model.keepAwake }, when: { model.notices.post("Export saved", from: .data) }))
        try model.keepAwake.stop()
    }

    func testSubscribingToTheChangeSignalInsideABodyDoesNotObserveTheWholeModel() {
        let model = TilveroModel(isDemo: true, preferences: makeTestDefaults("Observation").defaults)
        defer { model.stop() }
        var subscription: AnyCancellable?
        XCTAssertFalse(fires({ subscription = model.changes.sink { } }, when: { model.draftText = "85" }),
                       "A view that subscribes (Setup) must not re-render on every model change")
        subscription?.cancel()
    }

    func testTheChangeSignalCoversModelStateServicesNoticesAndNavigation() throws {
        let model = TilveroModel(isDemo: false, preferences: makeTestDefaults("Observation").defaults,
                                 snapshotProvider: { .unavailable(reason: "fixture") }, keepAwakeService: KeepAwakeService(driver: AwakeFixture()))
        defer { model.stop() }
        var count = 0
        let subscription = model.changes.sink { count += 1 }
        defer { subscription.cancel() }
        model.draftText = "85"
        XCTAssertEqual(count, 1, "Model state")
        try model.keepAwake.start(seconds: 600)
        XCTAssertGreaterThan(count, 1, "A bridged service")
        var before = count
        model.notices.post("Export saved", from: .data)
        XCTAssertGreaterThan(count, before, "A notice")
        before = count
        model.navigation.navigate(to: .section(.history))
        XCTAssertGreaterThan(count, before, "The navigation")
        before = count
        model.notifyExternalChange()
        XCTAssertEqual(count, before + 1, "An external change")
        model.draftText = "85"
        XCTAssertEqual(count, before + 1, "Assigning an equal value is not a change")
        try model.keepAwake.stop()
    }
}
