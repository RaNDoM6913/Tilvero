// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

public enum SleepTimerPhase: String, Equatable, Sendable {
    case idle, armed, warning, preparing, requesting, accepted
    case completed, cancelled, expired, failed, unconfirmed

    public var isActive: Bool {
        switch self {
        case .armed, .warning, .preparing, .requesting, .accepted: true
        default: false
        }
    }
    public var isEditable: Bool { self == .armed || self == .warning }
}

public enum SleepTimerError: Error, LocalizedError, Equatable {
    case invalidDuration, unavailable, notEditable, extensionLimit

    public var errorDescription: String? {
        switch self {
        case .invalidDuration: "Enter 1–1440 minutes."
        case .unavailable: "Sleep timer is unavailable in this build or simulation."
        case .notEditable: "This sleep timer can no longer be changed."
        case .extensionLimit: "A sleep timer cannot have more than 24 hours remaining."
        }
    }
}

/// Pure one-shot state machine. `now` is monotonic seconds, never wall-clock time.
/// The caller binds callbacks to both sessionID and generation before dispatch.
public struct SleepTimer: Equatable, Sendable {
    public private(set) var phase: SleepTimerPhase = .idle
    public private(set) var sessionID: UUID?
    public private(set) var generation: UInt64 = 0
    public private(set) var deadline: Double?
    public private(set) var acceptedAt: Double?
    public private(set) var requestSubmitted = false
    public static let warningSeconds = 60.0
    public static let dispatchGraceSeconds = 5.0
    public static let confirmationSeconds = 60.0
    public static let maximumSeconds = 86_400.0

    public init() {}

    /// Repeated Start while active preserves the existing authorized session.
    public mutating func start(minutes: Int, now: Double, id: UUID = UUID()) throws {
        guard !phase.isActive else { return }
        guard (1...1440).contains(minutes), now.isFinite else { throw SleepTimerError.invalidDuration }
        generation &+= 1
        sessionID = id
        deadline = now + Double(minutes * 60)
        acceptedAt = nil
        requestSubmitted = false
        phase = minutes == 1 ? .warning : .armed
    }

    public func remainingSeconds(at now: Double) -> Int {
        guard phase.isActive, let deadline, now.isFinite else { return 0 }
        let remaining = max(0, deadline - now)
        return Int(min(Self.maximumSeconds, remaining.rounded(.up)))
    }

    public func canExtend(at now: Double) -> Bool {
        guard phase.isEditable, let deadline, now.isFinite else { return false }
        let remaining = deadline - now
        return remaining > 0 && remaining + 900 <= Self.maximumSeconds
    }

    /// A new explicit duration replaces the remaining time, keeping session identity.
    public mutating func replaceDuration(minutes: Int, now: Double) throws {
        guard phase.isEditable else { throw SleepTimerError.notEditable }
        guard (1...1440).contains(minutes), now.isFinite else { throw SleepTimerError.invalidDuration }
        generation &+= 1
        deadline = now + Double(minutes * 60)
        phase = minutes == 1 ? .warning : .armed
    }

    public mutating func extend(now: Double) throws {
        guard phase.isEditable, let deadline, now.isFinite, deadline > now else { throw SleepTimerError.notEditable }
        guard canExtend(at: now) else { throw SleepTimerError.extensionLimit }
        generation &+= 1
        self.deadline = deadline + 900
        phase = .armed
    }

    public mutating func advance(now: Double) {
        guard now.isFinite else { finish(.expired); return }
        if phase.isEditable, let deadline {
            if now > deadline + Self.dispatchGraceSeconds { finish(.expired) }
            else if now >= deadline - Self.warningSeconds { phase = .warning }
        } else if phase == .accepted, let acceptedAt, now >= acceptedAt + Self.confirmationSeconds {
            finish(.unconfirmed)
        }
    }

    public mutating func beginPreparation(now: Double) -> Bool {
        advance(now: now)
        guard phase.isEditable, let deadline, now >= deadline else { return false }
        phase = .preparing
        return true
    }

    public mutating func beginRequest(now: Double) -> Bool {
        guard phase == .preparing, let deadline else { return false }
        guard now.isFinite, now >= deadline, now <= deadline + Self.dispatchGraceSeconds else {
            finish(.expired)
            return false
        }
        phase = .requesting
        return true
    }

    /// The transport submission is synchronous: mark immediately before calling it.
    public mutating func markSubmitted() -> Bool {
        guard phase == .requesting, !requestSubmitted else { return false }
        requestSubmitted = true
        return true
    }

    public mutating func acceptRequest(now: Double) {
        guard phase == .requesting, requestSubmitted else { return }
        acceptedAt = now
        phase = .accepted
    }

    public mutating func failRequest() {
        guard phase == .requesting else { return }
        finish(.failed)
    }

    /// User cancellation cannot revoke an OS request already being submitted.
    public mutating func cancel() {
        guard phase.isEditable || phase == .preparing else { return }
        finish(.cancelled)
    }

    public mutating func systemWillSleep() {
        guard phase.isActive else { return }
        finish(requestSubmitted ? .completed : .cancelled)
    }

    /// Wake, session loss and shutdown consume executable intent even if willSleep was missed.
    public mutating func invalidate() {
        guard phase.isActive else { return }
        finish(requestSubmitted ? .unconfirmed : .cancelled)
    }

    public func nextTransition(at now: Double) -> Double? {
        switch phase {
        case .armed: deadline.map { max(0, $0 - Self.warningSeconds - now) }
        case .warning: deadline.map { max(0, $0 - now) }
        case .accepted: acceptedAt.map { max(0, $0 + Self.confirmationSeconds - now) }
        default: nil
        }
    }

    private mutating func finish(_ phase: SleepTimerPhase) {
        generation &+= 1
        self.phase = phase
        deadline = nil
        acceptedAt = nil
    }
}
