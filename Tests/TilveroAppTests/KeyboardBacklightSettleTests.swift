// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import KeyboardBackends
@testable import TilveroApp

@MainActor private final class SettleMemory: KeyboardBacklightPreferenceStorage { var lastNonzeroBrightness: Double? }

/// A keyboard that fades: after a write the readback shows `fadeReads` intermediate steps before the target.
@MainActor private final class FadingKeyboard: KeyboardBacklightTransport {
    var level = 0.10
    var fadeReads = 0
    private var target: Double?
    private var remainingFade = 0
    private var start = 0.0
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?
    private(set) var writes: [Double] = []
    func read() async throws -> KeyboardBacklightObservation {
        onRead?()
        if let target, remainingFade > 0 {
            remainingFade -= 1
            level = remainingFade == 0 ? target : start + (target - start) * 0.5   // half way until the fade is over
        }
        return try KeyboardBacklightObservation(keyboardID: 1, brightness: min(1, max(0, level)), automaticBrightness: false, suppressed: false, dimmed: false, observedAt: Date())
    }
    func setBrightness(_ value: Double, keyboardID: UInt64) async throws {
        onWrite?()
        writes.append(value); target = value; remainingFade = fadeReads; start = level
        if fadeReads == 0 { level = value }
    }
}

@MainActor final class KeyboardBacklightSettleTests: XCTestCase {
    func testTheRequestedLevelIsShownThroughoutPreReadWriteAndReadbackThenCleared() async {
        let driver = FadingKeyboard()
        let service = KeyboardBacklightService(driver: driver, storage: SettleMemory(), settleDelay: .milliseconds(1))
        await service.refresh()
        var seen: [Double?] = []
        driver.onRead = { seen.append(service.pendingBrightness) }
        driver.onWrite = { seen.append(service.pendingBrightness) }
        await service.setBrightness(0.6)
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0 == 0.6 }, "Every step of the operation exposes the requested level, never the old reading: \(seen)")
        XCTAssertNil(service.pendingBrightness, "Cleared once the readback is in.")
        XCTAssertEqual(service.brightness ?? 0, 0.6, accuracy: 0.005)
    }
    func testTheSwitchShowsTheRequestedStateWhileTheWriteSettles() async {
        let driver = FadingKeyboard()
        let service = KeyboardBacklightService(driver: driver, storage: SettleMemory(), settleDelay: .milliseconds(1))
        await service.refresh()
        var seen: [Bool?] = []
        driver.onRead = { seen.append(service.pendingEnabled) }
        await service.setEnabled(false)
        XCTAssertTrue(seen.allSatisfy { $0 == false }, "The switch never snaps back to the old state mid-operation: \(seen)")
        XCTAssertNil(service.pendingEnabled)
        XCTAssertEqual(service.isEnabled, false)
    }
    func testAFadeInProgressIsReadAgainInsteadOfBeingReportedAsUnconfirmed() async {
        let driver = FadingKeyboard(); driver.fadeReads = 3
        let service = KeyboardBacklightService(driver: driver, storage: SettleMemory(), settleDelay: .milliseconds(1))
        await service.refresh()
        await service.setBrightness(0.8)
        XCTAssertNil(service.error, "A level still on its way is not a failed write.")
        XCTAssertEqual(service.brightness ?? 0, 0.8, accuracy: 0.005)
        XCTAssertEqual(driver.writes, [0.8], "Read again, never written again.")
    }
    func testALevelThatNeverArrivesIsStillReportedUnconfirmed() async {
        let driver = FadingKeyboard(); driver.fadeReads = 100
        let service = KeyboardBacklightService(driver: driver, storage: SettleMemory(), settleDelay: .milliseconds(1))
        await service.refresh()
        await service.setBrightness(0.9)
        XCTAssertEqual(service.error, .unconfirmedWrite)
        XCTAssertNil(service.pendingBrightness)
    }
}
