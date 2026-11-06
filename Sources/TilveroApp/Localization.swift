// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// One shipped String Catalog feeds both the SwiftPM and Xcode bundles.
enum L10n {
    #if TILVERO_LAB_STUDIO
    private static let studioLanguage = StudioLanguagePreference()
    /// The sandbox owns its preference suite; never write the app/production
    /// domain merely to preview the actual product's language setting.
    @discardableResult static func useStudioLanguage(_ value: String?) -> Bool { studioLanguage.set(value) }
    #endif
    static var language: String {
        #if TILVERO_LAB_STUDIO
        let preference = studioLanguage.get() ?? UserDefaults.standard.string(forKey: "language") ?? "system"
        #else
        let preference = UserDefaults.standard.string(forKey: "language") ?? "system"
        #endif
        if preference == "en" || preference == "ru" { return preference }
        return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
    }
    static var locale: Locale { Locale(identifier: language == "ru" ? "ru_RU" : "en_US") }
    private static let strings: [String: [String: String]] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["strings"] as? [String: [String: Any]] else { return [:] }
        var result: [String: [String: String]] = [:]
        for (key, entry) in entries {
            guard let localizations = entry["localizations"] as? [String: [String: Any]] else { continue }
            for (locale, localization) in localizations {
                if let unit = localization["stringUnit"] as? [String: String], let value = unit["value"] {
                    result[key, default: [:]][locale] = value
                }
            }
        }
        return result
    }()
    static func text(_ key: String) -> String { strings[key]?[language] ?? key }
}

#if TILVERO_LAB_STUDIO
private final class StudioLanguagePreference: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func get() -> String? { lock.withLock { value } }
    func set(_ replacement: String?) -> Bool {
        lock.withLock {
            guard value != replacement else { return false }
            value = replacement
            return true
        }
    }
}
#endif
