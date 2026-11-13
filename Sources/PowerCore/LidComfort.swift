// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

// Pure domain of "lid-close comfort": while the Mac is kept awake with the lid closed, the built-in display is
// turned down and the output volume is capped; both return when the lid opens or the lid override ends.
// Nothing here touches the platform. A value is only ever lowered ("cap"), never raised, and only what Tilvero
// itself wrote is restored.

/// Which lid-closed session the settings belong to. Mirrors the two lid switches (Keep Awake; sleep timer and
/// Sleep at charge).
public enum LidComfortMode: String, Codable, Sendable, CaseIterable { case keepAwake, scheduledSleep }

/// The user's choice for one mode. Levels are 0...1 and mean "no brighter / no louder than".
public struct LidComfortSettings: Equatable, Codable, Sendable {
    public var dimDisplay: Bool
    public var displayLevel: Double
    public var limitVolume: Bool
    public var volumeLevel: Double
    public init(dimDisplay: Bool, displayLevel: Double, limitVolume: Bool, volumeLevel: Double) {
        self.dimDisplay = dimDisplay; self.displayLevel = displayLevel
        self.limitVolume = limitVolume; self.volumeLevel = volumeLevel
    }
    /// Owner decision 2026-11-12: the screen goes to 0, the sound to at most 25 %.
    public static let `default` = LidComfortSettings(dimDisplay: true, displayLevel: 0, limitVolume: true, volumeLevel: 0.25)
    /// Something would be done at lid close.
    public var isActive: Bool { dimDisplay || limitVolume }
    /// Non-finite levels fall back to the default, others are clamped to 0...1.
    public var sanitized: LidComfortSettings {
        func level(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
        return LidComfortSettings(dimDisplay: dimDisplay, displayLevel: level(displayLevel, fallback: Self.default.displayLevel),
                                  limitVolume: limitVolume, volumeLevel: level(volumeLevel, fallback: Self.default.volumeLevel))
    }
}

/// One thing Tilvero changed and must put back.
public struct LidComfortEntry: Codable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        case display(id: UInt32)
        case volume(deviceUID: String)
    }
    /// `intent`: written down before the setter ran (the write may or may not have landed);
    /// `applied`: the setter ran and the readback was recorded as `written`.
    public enum Phase: String, Codable, Sendable { case intent, applied }
    public var target: Target
    public var original: Double
    public var written: Double
    public var phase: Phase
    public var createdAt: Date
    public init(target: Target, original: Double, written: Double, phase: Phase, createdAt: Date) {
        self.target = target; self.original = original; self.written = written; self.phase = phase; self.createdAt = createdAt
    }
}

/// Persisted before the first write so a crash or a kill can still be recovered.
public struct LidComfortJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var mode: LidComfortMode
    public var entries: [LidComfortEntry]
    public var createdAt: Date
    public init(mode: LidComfortMode, entries: [LidComfortEntry], createdAt: Date) {
        version = Self.currentVersion; self.mode = mode; self.entries = entries; self.createdAt = createdAt
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
    public func encoded() throws -> Data { try Self.encoder().encode(self) }
    /// Unknown versions, garbage and non-finite values are rejected: a journal that cannot be trusted is not replayed.
    public static func decode(_ data: Data) -> LidComfortJournal? {
        guard let journal = try? decoder().decode(LidComfortJournal.self, from: data),
              journal.version == currentVersion,
              journal.entries.allSatisfy({ $0.original.isFinite && $0.written.isFinite }) else { return nil }
        return journal
    }
}

public enum LidComfortPolicy {
    /// Brightness and volume readbacks are quantized by panel and device (CoreAudio reports 0.50000006 for 50 %).
    public static let tolerance = 0.01
    /// Entries whose target never reappears are dropped after a day.
    public static let maximumEntryAge: TimeInterval = 24 * 3600

    /// The value to write for "no louder / no brighter than `level`", or nil when nothing should be written
    /// (already at or below the level, or an unusable input). A lower value is never raised.
    public static func capTarget(current: Double, level: Double) -> Double? {
        guard current.isFinite, level.isFinite else { return nil }
        let capped = min(1, max(0, level))
        return current > capped + tolerance ? capped : nil
    }

    public enum RestoreDecision: Equatable, Sendable {
        case write(Double)   // still our value: put the original back
        case clear           // nothing to do (already original, the user changed it, or too old to matter)
        case keep            // target unreadable right now: try again later
    }

    /// Idempotent and conservative: restores only what the app owns. `current` is nil when the target cannot be read.
    public static func restoreDecision(for entry: LidComfortEntry, current: Double?, now: Date) -> RestoreDecision {
        guard let current, current.isFinite else {
            return now.timeIntervalSince(entry.createdAt) > maximumEntryAge ? .clear : .keep
        }
        if abs(current - entry.written) <= tolerance { return .write(entry.original) }
        return .clear   // already original, or changed meanwhile by the user or the system
    }
}
