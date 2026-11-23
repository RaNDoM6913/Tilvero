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
    func testDecodesLittleEndianIntegerTypes() {
        // Bytes as the SMC returned them on Mac17,3 (2026-11-20): B0AV 11642 mV, B0AC -242 mA, B0AP -2817 mW.
        XCTAssertEqual(SMCSensorDecoding.number(type: "ui16", bytes: [0x7A, 0x2D]), 11642)
        XCTAssertEqual(SMCSensorDecoding.number(type: "si16", bytes: [0x0E, 0xFF]), -242)
        XCTAssertEqual(SMCSensorDecoding.number(type: "si32", bytes: [0xFF, 0xF4, 0xFF, 0xFF]), -2817)
        XCTAssertEqual(SMCSensorDecoding.number(type: "si32", bytes: [0x10, 0x27, 0, 0]), 10000, "Positive while charging.")
        XCTAssertNil(SMCSensorDecoding.number(type: "si32", bytes: [1, 2]), "A short buffer is not an si32.")
        XCTAssertNil(SMCSensorDecoding.number(type: "ui16", bytes: [1, 2, 3]))
    }
    func testBatteryPowerNeedsAgreeingPlausibleReadings() {
        XCTAssertEqual(SMCSensorDecoding.batteryWatts(powerMilliwatts: -2817, currentMilliamps: -242, voltageMillivolts: 11642), -2.817)
        XCTAssertEqual(SMCSensorDecoding.batteryWatts(powerMilliwatts: 30000, currentMilliamps: 2400, voltageMillivolts: 12500), 30, "Charging is positive.")
        XCTAssertNil(SMCSensorDecoding.batteryWatts(powerMilliwatts: -2817, currentMilliamps: -400, voltageMillivolts: 11642), "Power and current×voltage disagree.")
        XCTAssertNil(SMCSensorDecoding.batteryWatts(powerMilliwatts: -2817, currentMilliamps: -242, voltageMillivolts: 0), "No plausible voltage.")
        XCTAssertNil(SMCSensorDecoding.batteryWatts(powerMilliwatts: 400_000, currentMilliamps: 20000, voltageMillivolts: 20000), "Beyond any laptop.")
        XCTAssertNil(SMCSensorDecoding.batteryWatts(powerMilliwatts: nil, currentMilliamps: -242, voltageMillivolts: 11642))
        XCTAssertNil(SMCSensorDecoding.batteryWatts(powerMilliwatts: .nan, currentMilliamps: -242, voltageMillivolts: 11642))
    }
    func testImplausibleValuesAreUnavailableNotClamped() {
        XCTAssertEqual(SMCSensorDecoding.watts(7.3), 7.3)
        XCTAssertNil(SMCSensorDecoding.watts(.nan)); XCTAssertNil(SMCSensorDecoding.watts(900)); XCTAssertNil(SMCSensorDecoding.watts(-50))
        XCTAssertNil(SMCSensorDecoding.watts(nil))
        XCTAssertEqual(SMCSensorDecoding.celsius(33.2), 33.2)
        XCTAssertNil(SMCSensorDecoding.celsius(-273)); XCTAssertNil(SMCSensorDecoding.celsius(.infinity))
    }
    func testMetricMapping() {
        let s = LivePowerSample(collectedAt: Date(), systemWatts: 8, adapterWatts: 10, temperatureCelsius: 33, batteryWatts: -2.8)
        XCTAssertEqual(s.value(metricID: "043"), 8); XCTAssertEqual(s.value(metricID: "054"), 10)
        XCTAssertEqual(s.value(metricID: "039"), 33); XCTAssertEqual(s.value(metricID: "038"), -2.8)
        XCTAssertNil(LivePowerSample(collectedAt: Date(), systemWatts: 8, adapterWatts: 10, temperatureCelsius: 33).value(metricID: "038"),
                     "No battery power unless B0AP was read: never derived from PDTR - PSTR.")
        XCTAssertEqual(LivePowerSample.metricIDs, ["038", "039", "043", "054"])
        XCTAssertNil(s.value(metricID: "001"))
    }
    func testOnlyTheAllowListedSensorKeysExist() {
        XCTAssertEqual(SMCSensorReader.allowedKeys, ["PSTR", "PDTR", "TB0T", "TB1T", "TB2T", "B0AP", "B0AC", "B0AV"])
        XCTAssertFalse(SMCSensorReader.allowedKeys.contains { $0.hasPrefix("F") || $0.hasPrefix("CH") }, "No fan or charge-control key.")
    }
    func testReadingIsHarmlessWhereverTheSMCExists() {
        // Read-only: a real SMC returns a plausible sample or nil; either way nothing is written.
        if let reader = SMCSensorReader(), let sample = reader.read() {
            if let w = sample.systemWatts { XCTAssertTrue((-5...400).contains(w)) }
            if let w = sample.batteryWatts { XCTAssertTrue((-300...300).contains(w)) }
        }
    }
}
