// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

// Pure domain of the closed-lid "lifeline watchdog". While "With lid closed" holds the system-wide
// `pmset disablesleep 1`, a small child process of the app waits on a pipe. A confirmed restore sends it one
// "released" byte; any other end of the app (crash, force quit, kill) closes the pipe and the child acts: it puts
// normal sleep back only when the on-disk marker still carries its own session token. Nothing here touches the
// platform, and no decision can ever ask for sleep to be disabled.

/// Written next to the history store before `disablesleep 1` and removed only after a confirmed `0`.
/// `token` is the ownership proof; `pid` and `boot` are diagnostics only.
public struct LidOverrideMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var token: String
    public var pid: Int32
    public var createdAt: Date
    /// `kern.bootsessionuuid` at the time of writing (nil when it could not be read).
    public var boot: String?

    /// `createdAt` is kept to whole seconds, the precision of the ISO 8601 form on disk.
    public init(token: String, pid: Int32, createdAt: Date, boot: String?) {
        v = Self.currentVersion; self.token = token; self.pid = pid; self.boot = boot
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// nil for anything that is not a version-1 marker with a non-empty token (an unknown or damaged file is never
    /// treated as "ours": callers treat it as present with an unknown owner).
    public static func decode(_ data: Data) -> LidOverrideMarker? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(LidOverrideMarker.self, from: data),
              marker.v == currentVersion, !marker.token.isEmpty else { return nil }
        return marker
    }
}

/// What the watchdog learnt from its pipe.
public enum LidWatchdogSignal: Equatable, Sendable {
    /// The app confirmed `SleepDisabled 0` and sent the release byte.
    case released
    /// The pipe closed without a release: the app ended without confirming a restore.
    case endOfFile
    /// The pipe failed without a clean end. The app may still be alive, so the watchdog never acts on it.
    case pipeFailed
}

/// Who the marker on disk belongs to, from the watchdog's point of view.
public enum LidWatchdogMarkerOwnership: Equatable, Sendable {
    /// No marker: the app restored, or launch recovery already handled it.
    case absent
    /// Another token, or a file that cannot be read as a marker: a newer session owns the override.
    case foreign
    /// The marker still carries this watchdog's token.
    case own
}

public enum LidWatchdogDecision: Equatable, Sendable {
    /// Leave everything as it is and exit.
    case exit
    /// Normal sleep is confirmed: delete the marker, then ask for the sleep a closed lid would have caused.
    case finish
    /// Put normal sleep back with `disablesleep 0` and read it again. The lid-close comfort restore (brightness,
    /// volume) runs first, once, so the Mac never goes to sleep with its screen still turned down.
    case clear(restoreComfortFirst: Bool)
    /// Still disabled after the bounded attempts: exit and keep the marker (launch recovery and the in-app warning
    /// take over).
    case giveUp
}

public enum LidWatchdogPolicy {
    /// `disablesleep 0` attempts before the watchdog gives up and leaves the marker.
    public static let maximumClearAttempts = 5

    /// One step of the watchdog. `sleepDisabled` is the latest `pmset -g` reading (nil: unreadable), `clearAttempts`
    /// how many `disablesleep 0` writes this watchdog has already made.
    public static func decide(signal: LidWatchdogSignal, marker: LidWatchdogMarkerOwnership,
                              sleepDisabled: Bool?, clearAttempts: Int) -> LidWatchdogDecision {
        guard signal == .endOfFile else { return .exit }
        guard marker == .own else { return .exit }
        if sleepDisabled == false { return .finish }
        guard clearAttempts < maximumClearAttempts else { return .giveUp }
        return .clear(restoreComfortFirst: clearAttempts == 0)
    }
}
