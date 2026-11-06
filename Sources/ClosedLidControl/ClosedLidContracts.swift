import Foundation

public enum ClosedLidLimits {
    public static let protocolVersion = 1
    public static let maximumPayloadBytes = 32_768
    public static let maximumReplyBytes = 65_536
    public static let witnessMaximumAge: Double = 5
    public static let leaseSeconds: Double = 15
    public static let guardianMaximumAge: Double = 6
    public static let maximumSessionSeconds = 86_400
    public static let mechanism = "iopm-root-userclient-selector12-powerd-bit-v1"
}

public enum ClosedLidFailure: String, Error, Codable, Sendable {
    case unsupported, unavailable, malformed, missingTrust, wrongUser, wrongSession
    case staleGeneration, replay, busy, insecureStorage, locked, corruptJournal
    case baselineWitnessRequired, contextConflict, guardianUnavailable, expired
    case recoveryRequired, commandRejected, timeout
}

/// Only a native recomputed message can witness the original Powerd bit clear.
/// The aggregate registry property alone is insufficient and may be stale.
public struct ClamshellBaselineWitness: Codable, Equatable, Sendable {
    public let bootID: String
    public let receivedAt: Double
    public let sequence: UInt64
    /// Sequence counters belong to one observer process, not to the entire boot.
    public let observerID: UUID
    public let contextID: UUID
    public let notificationBits: UInt32
    public let sleepAllowed: Bool
    public let source: String
    public init(bootID: String, receivedAt: Double, sequence: UInt64, contextID: UUID,
                notificationBits: UInt32, sleepAllowed: Bool,
                source: String = "IOPM native clamshell-state notification", observerID: UUID = UUID()) {
        self.bootID = bootID; self.receivedAt = receivedAt; self.sequence = sequence
        self.contextID = contextID; self.notificationBits = notificationBits
        self.sleepAllowed = sleepAllowed; self.source = source; self.observerID = observerID
    }
}

public struct ClamshellObservation: Codable, Equatable, Sendable {
    public var bootID: String
    public var sampledAt: Double
    public var contextID: UUID
    public var activeUserID: UInt32?
    public var lidClosed: Bool?
    public var externalDisplayPresent: Bool?
    public var aggregateSleepAllowed: Bool?
    public var witness: ClamshellBaselineWitness?
    public init(bootID: String, sampledAt: Double, contextID: UUID, activeUserID: UInt32?,
                lidClosed: Bool? = nil, externalDisplayPresent: Bool? = nil,
                aggregateSleepAllowed: Bool? = nil, witness: ClamshellBaselineWitness? = nil) {
        self.bootID = bootID; self.sampledAt = sampledAt; self.contextID = contextID
        self.activeUserID = activeUserID; self.lidClosed = lidClosed
        self.externalDisplayPresent = externalDisplayPresent
        self.aggregateSleepAllowed = aggregateSleepAllowed; self.witness = witness
    }
}

/// A synchronous kernel-call receipt, never independent configuration/physical proof.
public struct ClamshellCommandReceipt: Codable, Equatable, Sendable {
    public let disabled: Bool
    public let acceptedAt: Double
    public init(disabled: Bool, acceptedAt: Double) { self.disabled = disabled; self.acceptedAt = acceptedAt }
}

public protocol ClamshellBackend: Sendable {
    func observe() async throws -> ClamshellObservation
    func setLidSleepDisabled(_ disabled: Bool) async throws -> ClamshellCommandReceipt
    /// Normal system Sleep, only after journaled restoration and a closed-lid observation.
    func requestNormalSleep() async throws -> Bool
}
public extension ClamshellBackend {
    func requestNormalSleep() async throws -> Bool { throw ClosedLidFailure.unsupported }
}

public enum ClosedLidPhase: String, Codable, Sendable {
    case idle, prepared, commandAccepted, restorationRequired
    case restoreAcceptedAwaitingWitness, restored, conflict, retiredAfterBoot
}

public struct ClosedLidState: Codable, Equatable, Sendable {
    public var phase: ClosedLidPhase = .idle
    public var sessionID: UUID?
    public var ownerUserID: UInt32?
    public var generation: UInt64 = 0
    public var sessionDeadline: Double?
    public var leaseDeadline: Double?
    public var applicationAccepted = false
    public var restoreCommandAccepted = false
    public var configurationVerified = false
    public var behaviorObserved = false
    public var normalSleepRequestAttempted: Bool?
    public var normalSleepRequestAccepted: Bool?
    public var recoveryRequired = false
    public var observation: ClamshellObservation?
    public var reason: String?
    public var mechanism = ClosedLidLimits.mechanism
    public init() {}
}

public struct ClosedLidPeer: Codable, Equatable, Sendable {
    public let userID: UInt32
    public let auditSessionID: UInt32
    public let connectionID: UUID
    public init(userID: UInt32, auditSessionID: UInt32, connectionID: UUID) {
        self.userID = userID; self.auditSessionID = auditSessionID; self.connectionID = connectionID
    }
}

public enum ClosedLidCommand: Codable, Equatable, Sendable {
    case readState
    case start(seconds: Int)
    case heartbeat(sessionID: UUID)
    case stop(sessionID: UUID)
    case recover(sessionID: UUID)
    public var isMutation: Bool { if case .readState = self { false } else { true } }
}

public struct ClosedLidEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let sessionToken: UUID
    public let generation: UInt64
    public let command: ClosedLidCommand
    public init(version: Int = ClosedLidLimits.protocolVersion, requestID: UUID = UUID(),
                sessionToken: UUID, generation: UInt64, command: ClosedLidCommand) {
        self.version = version; self.requestID = requestID; self.sessionToken = sessionToken
        self.generation = generation; self.command = command
    }
}

public struct ClosedLidReply: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var sessionToken: UUID?
    public var generation: UInt64
    public var state: ClosedLidState
    public var failure: ClosedLidFailure?
    public init(accepted: Bool = false, sessionToken: UUID? = nil, generation: UInt64 = 0,
                state: ClosedLidState = .init(), failure: ClosedLidFailure? = nil) {
        self.accepted = accepted; self.sessionToken = sessionToken; self.generation = generation
        self.state = state; self.failure = failure
    }
}

public protocol ClosedLidRequestServing: Sendable {
    func openSession(peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply
    func perform(_ envelope: ClosedLidEnvelope, peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply
    func disconnect(peer: ClosedLidPeer) async
    func currentState() async throws -> ClosedLidState
}

public protocol ClosedLidClientTransport: Sendable {
    func openSession() async throws -> ClosedLidReply
    func submit(_ command: ClosedLidCommand) async throws -> ClosedLidReply
    func invalidate() async
}
