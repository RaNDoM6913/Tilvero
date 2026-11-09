// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Which temperature unit the app shows. The default follows the system: macOS's own temperature choice when it has one
/// (System Settings > Language & Region), otherwise Fahrenheit where the region measures in US units and Celsius elsewhere.
enum TemperatureUnitSetting: String, CaseIterable, Sendable {
    case system, celsius, fahrenheit

    /// `appleTemperatureUnit` is the global `AppleTemperatureUnit` default ("Celsius"/"Fahrenheit"), nil until the user picks.
    static func systemUsesFahrenheit(
        appleTemperatureUnit: String? = UserDefaults.standard.string(forKey: "AppleTemperatureUnit"),
        measurementSystem: Locale.MeasurementSystem = Locale.autoupdatingCurrent.measurementSystem
    ) -> Bool {
        switch appleTemperatureUnit?.lowercased().first {
        case "f": return true
        case "c": return false
        default: return measurementSystem == .us
        }
    }

    func usesFahrenheit(
        appleTemperatureUnit: String? = UserDefaults.standard.string(forKey: "AppleTemperatureUnit"),
        measurementSystem: Locale.MeasurementSystem = Locale.autoupdatingCurrent.measurementSystem
    ) -> Bool {
        switch self {
        case .celsius: false
        case .fahrenheit: true
        case .system: Self.systemUsesFahrenheit(appleTemperatureUnit: appleTemperatureUnit, measurementSystem: measurementSystem)
        }
    }

    /// The stored choice: the new key, else a legacy Bool (written only when the user picked a unit), else the system.
    static func load(from preferences: UserDefaults) -> TemperatureUnitSetting {
        if let raw = preferences.string(forKey: "temperatureUnit"), let value = TemperatureUnitSetting(rawValue: raw) { return value }
        if let legacy = preferences.object(forKey: "fahrenheit") as? Bool { return legacy ? .fahrenheit : .celsius }
        return .system
    }
}
// tlv-origin:5c19e7a3b08d42f6
