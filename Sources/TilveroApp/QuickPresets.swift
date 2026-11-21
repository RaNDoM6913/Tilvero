// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Observation

/// The quick menu's preset pills (IA §5). Durations are minutes in ascending order, levels percent in descending order.
/// The defaults are exactly the lists the quick menu showed before presets became editable.
struct QuickPresets: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = QuickPresets.currentVersion
    var sleepTimer: [Int]
    var keepAwake: [Int]
    var overviewAwake: [Int]
    var sleepAtCharge: [Int]
    var awakeUntilCharge: [Int]

    static let defaults = QuickPresets(sleepTimer: [15, 30, 60], keepAwake: [15, 30, 60, 120, 240, 480],
                                       overviewAwake: [15, 30, 60, 240], sleepAtCharge: [50, 30, 20, 10, 5],
                                       awakeUntilCharge: [50, 30, 20, 10, 5])

    init(sleepTimer: [Int], keepAwake: [Int], overviewAwake: [Int], sleepAtCharge: [Int], awakeUntilCharge: [Int]) {
        self.sleepTimer = sleepTimer; self.keepAwake = keepAwake; self.overviewAwake = overviewAwake
        self.sleepAtCharge = sleepAtCharge; self.awakeUntilCharge = awakeUntilCharge
    }

    /// A missing row takes its default; a row of the wrong type makes the whole payload damaged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        version = try container.decode(Int.self, forKey: .version)
        sleepTimer = try container.decodeIfPresent([Int].self, forKey: .sleepTimer) ?? fallback.sleepTimer
        keepAwake = try container.decodeIfPresent([Int].self, forKey: .keepAwake) ?? fallback.keepAwake
        overviewAwake = try container.decodeIfPresent([Int].self, forKey: .overviewAwake) ?? fallback.overviewAwake
        sleepAtCharge = try container.decodeIfPresent([Int].self, forKey: .sleepAtCharge) ?? fallback.sleepAtCharge
        awakeUntilCharge = try container.decodeIfPresent([Int].self, forKey: .awakeUntilCharge) ?? fallback.awakeUntilCharge
    }

    /// The five editable rows, in the editor's (and the IA table's) order.
    enum Row: String, CaseIterable, Identifiable, Sendable {
        case sleepTimer, keepAwake, sleepAtCharge, awakeUntilCharge, overviewAwake
        var id: String { rawValue }
        enum Kind: Sendable { case duration, level }
        var kind: Kind { self == .sleepAtCharge || self == .awakeUntilCharge ? .level : .duration }
        /// Most presets a row holds (its fixed tail pills come on top).
        var maximum: Int {
            switch self {
            case .sleepTimer: 7
            case .keepAwake, .sleepAtCharge, .awakeUntilCharge: 6
            case .overviewAwake: 4
            }
        }
        var keyPath: WritableKeyPath<QuickPresets, [Int]> {
            switch self {
            case .sleepTimer: \.sleepTimer
            case .keepAwake: \.keepAwake
            case .overviewAwake: \.overviewAwake
            case .sleepAtCharge: \.sleepAtCharge
            case .awakeUntilCharge: \.awakeUntilCharge
            }
        }
        /// Durations 1 min–24 h (the services' own bounds); levels 5–95 % in steps of 5.
        func accepts(_ value: Int) -> Bool {
            switch kind {
            case .duration: (1...1440).contains(value)
            case .level: (5...95).contains(value) && value % 5 == 0
            }
        }
        /// Every value the row may hold, in display order (levels only; durations are typed).
        var legalLevels: [Int] { kind == .level ? Array(stride(from: 95, through: 5, by: -5)) : [] }
    }

    subscript(row: Row) -> [Int] {
        get { self[keyPath: row.keyPath] }
        set { self[keyPath: row.keyPath] = newValue }
    }

    /// Drops values out of range and duplicates, sorts (durations ascending, levels descending), cuts to the maximum;
    /// an emptied row returns to its default. Pure.
    static func normalize(_ values: [Int], row: Row) -> [Int] {
        var unique = Array(Set(values.filter(row.accepts)))
        unique.sort(by: row.kind == .duration ? (<) : (>))
        let result = Array(unique.prefix(row.maximum))
        return result.isEmpty ? defaults[row] : result
    }

    func normalized() -> QuickPresets {
        var copy = self
        copy.version = Self.currentVersion
        for row in Row.allCases { copy[row] = Self.normalize(self[row], row: row) }
        return copy
    }

    /// What a stored payload means: nothing stored, a damaged payload or one from a newer build show the defaults.
    static func load(_ data: Data?) -> QuickPresets {
        guard let data, let decoded = try? JSONDecoder().decode(QuickPresets.self, from: data),
              decoded.version == currentVersion else { return defaults }
        return decoded.normalized()
    }
}

/// Owns the presets for the whole app (one per model), persisted as JSON under `quickPresets.v1`. Its own key, so
/// resetting presets and resetting Overview blocks stay independent. Nothing is written until the user edits: a
/// payload from a newer build stays untouched while this build shows the defaults.
@MainActor @Observable final class QuickPresetStore {
    static let key = "quickPresets.v1"
    private(set) var presets: QuickPresets
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        presets = QuickPresets.load(defaults.data(forKey: Self.key))
    }

    subscript(row: QuickPresets.Row) -> [Int] { presets[row] }

    /// Replaces one row (normalised) and saves.
    func set(_ row: QuickPresets.Row, _ values: [Int]) {
        var next = presets
        next[row] = QuickPresets.normalize(values, row: row)
        save(next)
    }

    func replace(_ value: QuickPresets) { save(value.normalized()) }

    /// «Вернуть по умолчанию»: the five rows only.
    func resetToDefaults() {
        defaults.removeObject(forKey: Self.key)
        if presets != .defaults { presets = .defaults }
    }

    var isDefault: Bool { presets == .defaults }

    private func save(_ value: QuickPresets) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        if presets != value { presets = value }
    }
}
