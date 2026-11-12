// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import PowerTelemetry

final class SMCSensorReaderTests: XCTestCase {
    func testDecodesFloatAndFixedPointTypes() {
        var f: Float = 7.5
        XCTAssertEqual(SMCSensorDecoding.number(type: "flt ", bytes: withUnsafeBytes(of: &f) { Array($0) }), 7.5)
        XCTAssertEqual(SMCSensorDecoding.number(type: "sp78", bytes: [0x21, 0x80]), 33.5)      // 0x2180 / 256
        XCTAssertEqual(SMCSensorDecoding.number(type: "ui8 ", bytes: [3]), 3)
        XCTAssertNil(SMCSensorDecoding.number(type: "flt ", bytes: [1, 2]), "A short buffer is not a float.")
        XCTAssertNil(SMCSensorDecoding.number(type: "ch8*", bytes: [1]))
    }
    func testImplausibleValuesAreUnavailableNotClamped() {
        XCTAssertEqual(SMCSensorDecoding.watts(7.3), 7.3)
        XCTAssertNil(SMCSensorDecoding.watts(.nan)); XCTAssertNil(SMCSensorDecoding.watts(900)); XCTAssertNil(SMCSensorDecoding.watts(-50))
        XCTAssertNil(SMCSensorDecoding.watts(nil))
        XCTAssertEqual(SMCSensorDecoding.celsius(33.2), 33.2)
        XCTAssertNil(SMCSensorDecoding.celsius(-273)); XCTAssertNil(SMCSensorDecoding.celsius(.infinity))
    }
    func testBatteryPowerIsAdapterMinusSystemAndNeedsBoth() {
        let now = Date()
        XCTAssertEqual(LivePowerSample(collectedAt: now, systemWatts: 7.3, adapterWatts: 6.7, temperatureCelsius: nil).batteryWatts ?? 0, -0.6, accuracy: 1e-9)
        XCTAssertEqual(LivePowerSample(collectedAt: now, systemWatts: 5, adapterWatts: 20, temperatureCelsius: nil).batteryWatts ?? 0, 15, accuracy: 1e-9)
        XCTAssertNil(LivePowerSample(collectedAt: now, systemWatts: 5, adapterWatts: nil, temperatureCelsius: nil).batteryWatts)
    }
    func testMetricMapping() {
        let s = LivePowerSample(collectedAt: Date(), systemWatts: 8, adapterWatts: 10, temperatureCelsius: 33)
        XCTAssertEqual(s.value(metricID: "043"), 8); XCTAssertEqual(s.value(metricID: "054"), 10)
        XCTAssertEqual(s.value(metricID: "039"), 33); XCTAssertEqual(s.value(metricID: "038") ?? 0, 2, accuracy: 1e-9)
        XCTAssertNil(s.value(metricID: "001"))
    }
    func testOnlyTheAllowListedSensorKeysExist() {
        XCTAssertEqual(SMCSensorReader.allowedKeys, ["PSTR", "PDTR", "TB0T", "TB1T", "TB2T"])
        XCTAssertFalse(SMCSensorReader.allowedKeys.contains { $0.hasPrefix("F") || $0.hasPrefix("B") && $0 != "TB0T" }, "No fan or arbitrary key.")
    }
    func testReadingIsHarmlessWhereverTheSMCExists() {
        // Read-only: a real SMC returns a plausible sample or nil; either way nothing is written.
        if let reader = SMCSensorReader(), let sample = reader.read() {
            if let w = sample.systemWatts { XCTAssertTrue((-5...400).contains(w)) }
        }
    }
}
