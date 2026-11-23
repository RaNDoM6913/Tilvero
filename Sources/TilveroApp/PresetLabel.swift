// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// The one formatter for preset pills and chips (IA §5 "Label format"). Durations are minutes, levels percent.
/// - under 60 min: «45 мин» / "45 min"; whole hours: «2 ч» / "2 h" (the timer's «60 мин» is «1 ч»);
/// - mixed under 10 h: «1 ч 30 мин» / "1 h 30 min";
/// - mixed from 10 h, and any mixed value in the narrow form (the Overview strip): «12 ч 45» / "12 h 45";
/// - levels: «50 %».
/// VoiceOver always gets the full words (`spokenDuration`, `spokenLevel`).
enum PresetLabel {
    enum Form: Sendable { case standard, narrow }

    static func duration(_ minutes: Int, form: Form = .standard, language: String = L10n.language) -> String {
        let (min, hour) = units(language)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) \(min)" }
        if rest == 0 { return "\(hours) \(hour)" }
        if form == .narrow || hours >= 10 { return "\(hours) \(hour) \(rest)" }
        return "\(hours) \(hour) \(rest) \(min)"
    }

    static func level(_ percent: Int) -> String { "\(percent) %" }

    /// «1 час 30 минут», "1 hour 30 minutes".
    static func spokenDuration(_ minutes: Int, language: String = L10n.language) -> String {
        let hours = minutes / 60, rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) " + word(hours, language == "ru" ? ("час", "часа", "часов") : ("hour", "hours", "hours"), language)) }
        if rest > 0 || hours == 0 { parts.append("\(rest) " + word(rest, language == "ru" ? ("минута", "минуты", "минут") : ("minute", "minutes", "minutes"), language)) }
        return parts.joined(separator: " ")
    }

    /// «50 процентов», "50 percent".
    static func spokenLevel(_ percent: Int, language: String = L10n.language) -> String {
        "\(percent) " + (language == "ru" ? word(percent, ("процент", "процента", "процентов"), language) : "percent")
    }

    private static func units(_ language: String) -> (String, String) { language == "ru" ? ("мин", "ч") : ("min", "h") }

    /// Russian: one / few / many by the last digits; English: one / other.
    private static func word(_ value: Int, _ forms: (String, String, String), _ language: String) -> String {
        guard language == "ru" else { return value == 1 ? forms.0 : forms.1 }
        let tens = value % 100, last = value % 10
        if (11...14).contains(tens) { return forms.2 }
        if last == 1 { return forms.0 }
        if (2...4).contains(last) { return forms.1 }
        return forms.2
    }
}
