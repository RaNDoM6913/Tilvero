// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

/// Owner 2026-11-09: temperature follows the system by default (°F in the US and wherever macOS says Fahrenheit), with a
/// setting to force °C or °F.
@MainActor final class TemperatureUnitTests: XCTestCase {
    func testTheSystemDefaultFollowsMacOSThenTheRegion() {
        XCTAssertTrue(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: "Fahrenheit", measurementSystem: .metric),
                      "An explicit macOS temperature choice wins over the region.")
        XCTAssertFalse(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: "Celsius", measurementSystem: .us))
        XCTAssertTrue(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: nil, measurementSystem: .us))
        XCTAssertFalse(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: nil, measurementSystem: .metric))
        XCTAssertFalse(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: nil, measurementSystem: .uk), "The UK uses Celsius.")
        XCTAssertFalse(TemperatureUnitSetting.systemUsesFahrenheit(appleTemperatureUnit: "garbage", measurementSystem: .metric))
    }

    func testEachSettingResolvesToItsUnit() {
        XCTAssertFalse(TemperatureUnitSetting.celsius.usesFahrenheit(appleTemperatureUnit: "Fahrenheit", measurementSystem: .us))
        XCTAssertTrue(TemperatureUnitSetting.fahrenheit.usesFahrenheit(appleTemperatureUnit: "Celsius", measurementSystem: .metric))
        XCTAssertTrue(TemperatureUnitSetting.system.usesFahrenheit(appleTemperatureUnit: nil, measurementSystem: .us))
        XCTAssertFalse(TemperatureUnitSetting.system.usesFahrenheit(appleTemperatureUnit: nil, measurementSystem: .metric))
    }

    func testTheDefaultIsTheSystemAndALegacyChoiceIsKept() throws {
        func model(_ prefs: UserDefaults) -> TilveroModel { TilveroModel(isDemo: true, preferences: prefs) }
        let suite = "TempUnit-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertEqual(model(prefs).temperatureUnit, .system, "Nothing chosen: follow the system.")
        // A build before this setting stored a Bool only when the user picked a unit: that pick is explicit.
        prefs.set(true, forKey: "fahrenheit")
        XCTAssertEqual(model(prefs).temperatureUnit, .fahrenheit)
        prefs.set(false, forKey: "fahrenheit")
        XCTAssertEqual(model(prefs).temperatureUnit, .celsius)
        prefs.set("system", forKey: "temperatureUnit")
        XCTAssertEqual(model(prefs).temperatureUnit, .system, "The new setting wins over the legacy Bool.")
    }

    func testChoosingAUnitPersistsAndDrivesTheFahrenheitFlag() throws {
        let suite = "TempUnit2-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: prefs)
        model.temperatureUnit = .fahrenheit
        XCTAssertTrue(model.fahrenheit)
        XCTAssertEqual(prefs.string(forKey: "temperatureUnit"), "fahrenheit")
        model.temperatureUnit = .celsius
        XCTAssertFalse(model.fahrenheit)
        XCTAssertEqual(TilveroModel(isDemo: true, preferences: prefs).temperatureUnit, .celsius)
    }
}
