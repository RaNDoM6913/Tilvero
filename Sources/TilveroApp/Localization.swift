import Foundation

/// One shipped String Catalog feeds both the SwiftPM and Xcode bundles.
enum L10n {
    static var language: String {
        let preference = UserDefaults.standard.string(forKey: "language") ?? "system"
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
