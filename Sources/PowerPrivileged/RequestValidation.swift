import Foundation
import PowerCore

public enum PrivilegeError: Error, Sendable, Equatable {
    case malformed, incompatibleProtocol, wrongSession, wrongUser, staleGeneration, replay, busy, insecureStorage, locked, corruptJournal, missingTrust, timeout, recoveryRequired
}
public struct PeerSession: Sendable, Equatable {
    public let userID: UInt32
    public let auditSessionID: UInt32
    public let connectionID: UUID
    public init(userID: UInt32, auditSessionID: UInt32, connectionID: UUID) { self.userID = userID; self.auditSessionID = auditSessionID; self.connectionID = connectionID }
}
public struct RequestValidator: Sendable {
    public let sessionToken: UUID
    public let peer: PeerSession
    public private(set) var generation: UInt64 = 0
    private var requestIDs: Set<UUID> = []
    public init(sessionToken: UUID, peer: PeerSession) { self.sessionToken = sessionToken; self.peer = peer }
    @discardableResult public mutating func validate(_ data: Data, peer: PeerSession, activeUserID: UInt32?) throws -> HelperEnvelope {
        guard data.count <= HelperEnvelope.maximumBytes else { throw PrivilegeError.malformed }
        let envelope: HelperEnvelope
        do { envelope = try JSONDecoder().decode(HelperEnvelope.self, from: data) } catch { throw PrivilegeError.malformed }
        guard envelope.version == HelperEnvelope.protocolVersion else { throw PrivilegeError.incompatibleProtocol }
        guard self.peer == peer, envelope.sessionToken == sessionToken else { throw PrivilegeError.wrongSession }
        guard peer.userID >= 500, peer.userID == activeUserID else { throw PrivilegeError.wrongUser }
        guard envelope.generation >= generation, envelope.generation < UInt64.max else { throw PrivilegeError.staleGeneration }
        if envelope.command.isMutation, envelope.generation <= generation { throw PrivilegeError.staleGeneration }
        guard !requestIDs.contains(envelope.requestID) else { throw PrivilegeError.replay }
        switch envelope.command {
        case let .applyCharge(target): guard (80...100).contains(target) else { throw PrivilegeError.malformed }
        case let .setFanRPM(values):
            guard (1...10).contains(values.count), values.allSatisfy({ key, value in Int(key).map({ (0..<10).contains($0) && String($0) == key }) == true && (1...20_000).contains(value) }) else { throw PrivilegeError.malformed }
        case let .setFanPolicy(policy):
            switch policy {
            case .systemAuto: break
            case let .manual(values):
                guard (1...10).contains(values.count), values.allSatisfy({ key, value in Int(key).map({ (0..<10).contains($0) && String($0) == key }) == true && (1...20_000).contains(value) }) else { throw PrivilegeError.malformed }
            case let .boost(rpm, seconds): guard (1...20_000).contains(rpm), seconds.isFinite, (1...300).contains(seconds) else { throw PrivilegeError.malformed }
            case let .curve(curve): _ = try FanCurve(points: curve.points)
            }
        case let .setEnergyMode(_, mode): guard mode != .high else { throw PrivilegeError.malformed }
        default: break
        }
        generation = envelope.generation; requestIDs.insert(envelope.requestID)
        // Bounded session: rotate rather than forgetting old request IDs and permitting replay.
        guard requestIDs.count <= 4096 else { throw PrivilegeError.wrongSession }
        return envelope
    }
}
