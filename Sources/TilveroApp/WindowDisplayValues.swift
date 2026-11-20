// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore

/// One reading as the window draws it. The single place that enforces "a missing number is «—», never zero": a valid
/// zero stays «0». Pure and locale-aware, so the rules are testable without a view tree.
struct ReadingDisplay: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case live
        /// The source did not say how old the value is (stated in the (i), no mark).
        case freshnessUnknown
        /// Last value retained; drawn secondary with a clock.
        case stale
        /// No value: «—».
        case unavailable
    }

    /// Digits with the locale's separators; nil means «—».
    let number: String?
    /// Localised unit (empty for unit-less values).
    let unit: String
    /// «≈» before the value (estimated or inferred provenance).
    let approximate: Bool
    let state: State
    /// Sensitive identifier hidden until "Reveal identifiers".
    let masked: Bool

    static let unavailable = ReadingDisplay(number: nil, unit: "", approximate: false, state: .unavailable, masked: false)

    var text: String {
        if masked { return "••••••" }
        guard let number else { return "—" }
        return (approximate ? "≈ " : "") + number + (unit.isEmpty ? "" : " " + unit)
    }

    /// - magnitude: draw the absolute value (the sign is carried by the title, e.g. «В батарею» / «Из батареи»).
    /// - fractionDigits: decimals of non-integer values.
    static func make(_ reading: CatalogReading?, fahrenheit: Bool, magnitude: Bool = false,
                     fractionDigits: ClosedRange<Int> = 1...1, locale: Locale = L10n.locale,
                     language: String = L10n.language) -> ReadingDisplay {
        guard let reading else { return .unavailable }
        let usable = reading.availability == .available || reading.freshness == .stale
        guard usable, let value = reading.value else { return .unavailable }
        let state: State = reading.freshness == .stale ? .stale : reading.freshness == .unknown ? .freshnessUnknown : .live
        if reading.privacy == .sensitive {
            return ReadingDisplay(number: nil, unit: "", approximate: false, state: state, masked: true)
        }
        let approximate = [.estimated, .inferred].contains(reading.provenance)
        var unit = reading.unit.map { CatalogDataPresentation.unit($0, language: language) } ?? ""
        let number: String
        switch value {
        case .integer(let integer) where reading.unit != "°C":
            if reading.unit == "cycles" { unit = "" }
            number = (magnitude ? abs(integer) : integer).formatted(.number.locale(locale))
        default:
            guard var double = value.doubleValue, double.isFinite else {
                // Text values (states, names) are shown as their own words.
                return ReadingDisplay(number: CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit),
                                      unit: "", approximate: false, state: state, masked: false)
            }
            if reading.unit == "°C", fahrenheit { double = double * 9 / 5 + 32; unit = "°F" }
            if magnitude { double = abs(double) }
            if double == 0 { double = 0 }   // never «-0»
            number = double.formatted(.number.locale(locale).precision(.fractionLength(fractionDigits)))
        }
        return ReadingDisplay(number: number, unit: unit, approximate: approximate, state: state, masked: false)
    }
}

/// Durations in the window's own words: «25 мин», «2 ч», «1 ч 30 мин» (owner decision 2026-11-20).
enum WindowDuration {
    static func text(minutes: Int, language: String = L10n.language) -> String {
        let ru = language == "ru"
        let h = ru ? "ч" : "h", m = ru ? "мин" : "min"
        let minutes = max(0, minutes)
        if minutes < 60 { return "\(minutes) \(m)" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(h)" }
        return "\(minutes / 60) \(h) \(minutes % 60) \(m)"
    }
    /// Rounded to five minutes, at least five (an estimate never claims minute precision).
    static func estimate(seconds: Double, language: String = L10n.language) -> String? {
        guard seconds.isFinite, seconds > 0, seconds <= 172_800 else { return nil }
        return text(minutes: max(5, Int((seconds / 300).rounded()) * 5), language: language)
    }
}

/// The big line at the top of a page: value, coloured status, one detail line. Composed by pure functions that drop
/// every unavailable fragment instead of printing a placeholder.
struct LeadDisplay: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case accent, input, battery, attention, neutral, secondary }
    let value: String
    let status: String
    let tone: Tone
    let detail: String
    /// Drawn secondary with a clock (the newest reading is old).
    var stale = false
}

/// Inputs of the Overview lead, read from the snapshot by the page.
struct OverviewLeadInputs: Equatable, Sendable {
    enum Power: Equatable, Sendable { case charging, onBattery, connectedNotCharging, unknown }
    var level: Int?
    var stale = false
    var lastRead: Date?
    var power: Power = .unknown
    /// Confirmed macOS limit (only when it is the active, fresh setting).
    var limit: Int?
    /// Time to the active target (070) or to full (069), seconds.
    var secondsToTarget: Double?
    /// Adapter capability (050), already formatted with its unit.
    var adapter: String?
    /// Discharge forecast to 20 %, lower bound in seconds (0 = already at or below 20 %).
    var forecastSeconds: Double?
}

enum OverviewLead {
    static func make(_ input: OverviewLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        let ru = language == "ru"
        func t(_ key: String) -> String { L10n.text(key) }
        guard let level = input.level else {
            return LeadDisplay(value: "—", status: t("No data"), tone: .secondary, detail: t("Battery not read yet"))
        }
        let value = ru ? "\(level) %" : "\(level)%"
        if input.stale {
            let time = input.lastRead.map { $0.formatted(.dateTime.hour().minute().locale(locale)) }
            return LeadDisplay(value: value, status: t("Stale"), tone: .attention,
                               detail: time.map { (ru ? "последнее чтение " : "last read ") + $0 } ?? "", stale: true)
        }
        var fragments: [String] = []
        let status: String, tone: LeadDisplay.Tone
        switch input.power {
        case .charging:
            status = t("Charging"); tone = .accent
            if let limit = input.limit, limit > level, limit < 100 { fragments.append((ru ? "до \(limit) %" : "to \(limit)%")) }
            if let seconds = input.secondsToTarget, let text = WindowDuration.estimate(seconds: seconds, language: language) {
                fragments.append("≈ " + text)
            }
            if let adapter = input.adapter { fragments.append((ru ? "адаптер " : "adapter ") + adapter) }
        case .onBattery:
            status = t("On battery (lead)"); tone = .battery
            if let seconds = input.forecastSeconds, seconds > 0, let text = WindowDuration.estimate(seconds: seconds, language: language) {
                fragments.append((ru ? "до 20 % ≈ " : "to 20% ≈ ") + text)
            }
        case .connectedNotCharging:
            status = t("Connected, not charging"); tone = .neutral
            if let limit = input.limit, limit < 100 { fragments.append(ru ? "лимит \(limit) %" : "limit \(limit)%") }
            if let adapter = input.adapter { fragments.append((ru ? "адаптер " : "adapter ") + adapter) }
        case .unknown:
            status = t("Power source unavailable"); tone = .secondary
        }
        return LeadDisplay(value: value, status: status, tone: tone, detail: fragments.joined(separator: " · "))
    }
}

extension NativeChargePresentation.Attention {
    /// Localisation key of the attention title (details banner, notice tile).
    var titleKey: String {
        switch self {
        case .sessionReview, .mutationUnresolved: "Charging session needs review"
        case .journalIntegrity: "Native journal needs review"
        case .operationPending: "Waiting for native operation"
        case .restorationPending: "Restoration pending"
        case .lowerTargetPending: "Pending charging target"
        case .policyUnconfirmed: "Waiting for policy confirmation"
        case .none: "Native charging"
        }
    }
}

/// The one notice a page shows under its lead, chosen by priority (IA §1): recovery / app-owned settings › charge
/// attention › store error › other notices (Keep Awake failure, action results).
struct NoticeDisplay: Equatable, Sendable {
    enum Action: Equatable, Sendable { case restore, diagnostics }
    let symbol: String
    let textKey: String
    /// Extra words shown after the localised key (a store error's own text, a notice's own text).
    var detail: String?
    var action: Action?

    struct Inputs: Equatable, Sendable {
        var recoveryRequired = false
        var ownsSettings = false
        var attentionKey: String?
        var storeError: String?
        var notice: String?
    }

    static func choose(_ input: Inputs) -> NoticeDisplay? {
        if input.recoveryRequired || input.ownsSettings {
            return NoticeDisplay(symbol: "exclamationmark.triangle", textKey: "App-owned settings require restoration", action: .restore)
        }
        if let key = input.attentionKey {
            return NoticeDisplay(symbol: "exclamationmark.triangle", textKey: key, action: .diagnostics)
        }
        if let error = input.storeError {
            return NoticeDisplay(symbol: "externaldrive.badge.exclamationmark", textKey: "Data store error", detail: error)
        }
        if let notice = input.notice {
            return NoticeDisplay(symbol: "info.circle", textKey: "", detail: notice)
        }
        return nil
    }

    var text: String {
        let head = textKey.isEmpty ? "" : L10n.text(textKey)
        guard let detail, !detail.isEmpty else { return head }
        return head.isEmpty ? detail : head + ": " + detail
    }
}
