import Foundation
import PowerPrivileged

@objc public protocol TilveroClosedLidXPC {
    func openSession(version: Int, reply: @escaping @Sendable (Data) -> Void)
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}
private func lidFailure(_ error: any Error) -> Data {
    // The wire carries only a bounded symbolic reason, never underlying OS errors.
    let failure = error as? ClosedLidFailure ?? .unavailable
    return (try? JSONEncoder().encode(ClosedLidReply(failure: failure))) ?? Data()
}
private func lidEncode(_ response: ClosedLidReply) throws -> Data {
    let data = try JSONEncoder().encode(response)
    guard data.count <= ClosedLidLimits.maximumReplyBytes else { throw ClosedLidFailure.malformed }
    return data
}

/// Connection-scoped serving boundary. The peer comes exclusively from Foundation's
/// audited connection metadata; payloads carry no caller-selected UID or service.
final class ClosedLidWireSession: @unchecked Sendable {
    private let service: any ClosedLidRequestServing
    private let peer: ClosedLidPeer
    private let activeUserID: @Sendable () -> UInt32?
    private let lock = NSLock()
    private var valid = true
    init(service: any ClosedLidRequestServing, peer: ClosedLidPeer,
         activeUserID: @escaping @Sendable () -> UInt32?) {
        self.service = service; self.peer = peer; self.activeUserID = activeUserID
    }
    private func consoleUser() throws -> UInt32? {
        guard lock.withLock({ valid }) else { throw ClosedLidFailure.wrongSession }
        let uid = activeUserID()
        try ClosedLidTrust.validateConsolePeer(userID: peer.userID, activeUserID: uid)
        return uid
    }
    func open(version: Int) async -> Data {
        do {
            let uid = try consoleUser()
            guard version == ClosedLidLimits.protocolVersion else { throw ClosedLidFailure.malformed }
            let response = try await service.openSession(peer: peer, activeUserID: uid)
            _ = try consoleUser()
            return try lidEncode(response)
        } catch {
            if (error as? ClosedLidFailure) == .wrongUser { await disconnect() }
            return lidFailure(error)
        }
    }
    func perform(_ payload: Data) async -> Data {
        do {
            let uid = try consoleUser()
            guard payload.count <= ClosedLidLimits.maximumPayloadBytes else { throw ClosedLidFailure.malformed }
            let envelope: ClosedLidEnvelope
            do { envelope = try JSONDecoder().decode(ClosedLidEnvelope.self, from: payload) }
            catch { throw ClosedLidFailure.malformed }
            guard envelope.version == ClosedLidLimits.protocolVersion else { throw ClosedLidFailure.malformed }
            let response = try await service.perform(envelope, peer: peer, activeUserID: uid)
            _ = try consoleUser()
            return try lidEncode(response)
        } catch {
            if (error as? ClosedLidFailure) == .wrongUser { await disconnect() }
            return lidFailure(error)
        }
    }
    /// Revoke synchronously before scheduling recovery, so queued requests cannot
    /// regain authority while the async serving layer is handling disconnect.
    func revoke() -> Bool { lock.withLock { let wasValid = valid; valid = false; return wasValid } }
    func disconnect() async {
        if revoke() { await service.disconnect(peer: peer) }
    }
    func disconnectAfterRevocation() async { await service.disconnect(peer: peer) }
}

/// Exactly one reply wins. Timeout also revokes the connection's controller
/// authority; a delayed completion cannot publish success afterwards.
final class ClosedLidReplyDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Data) -> Void)?
    init(seconds: Double = 5, completion: @escaping @Sendable (Data) -> Void,
         onTimeout: @escaping @Sendable () -> Void) {
        self.completion = completion
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            if let callback = take() { onTimeout(); callback(lidFailure(ClosedLidFailure.timeout)) }
        }
    }
    private func take() -> (@Sendable (Data) -> Void)? { lock.withLock { let result = completion; completion = nil; return result } }
    func resolve(_ data: Data) { take()?(data.count <= ClosedLidLimits.maximumReplyBytes ? data : lidFailure(ClosedLidFailure.malformed)) }
}
private final class ExportedClosedLidSession: NSObject, TilveroClosedLidXPC, @unchecked Sendable {
    let session: ClosedLidWireSession
    init(_ session: ClosedLidWireSession) { self.session = session }
    private func bounded(_ reply: @escaping @Sendable (Data) -> Void) -> ClosedLidReplyDeadline {
        ClosedLidReplyDeadline(completion: reply, onTimeout: { [session] in
            if session.revoke() { Task { await session.disconnectAfterRevocation() } }
        })
    }
    func openSession(version: Int, reply: @escaping @Sendable (Data) -> Void) {
        let deadline = bounded(reply)
        Task { deadline.resolve(await session.open(version: version)) }
    }
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        // Reject oversized data before starting an unstructured service task.
        guard payload.count <= ClosedLidLimits.maximumPayloadBytes else { reply(lidFailure(ClosedLidFailure.malformed)); return }
        let deadline = bounded(reply)
        Task { deadline.resolve(await session.perform(payload)) }
    }
}

public final class ClosedLidXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let trust: ClosedLidTrust
    private let service: any ClosedLidRequestServing
    public init(trust: ClosedLidTrust, service: any ClosedLidRequestServing) throws {
        try trust.verify(helper: true)
        self.trust = trust; self.service = service
        listener = NSXPCListener(machServiceName: trust.helperIdentifier)
        super.init(); listener.delegate = self
    }
    public func resume() { listener.resume() }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard (try? ClosedLidTrust.validateConsolePeer(userID: uid, activeUserID: HelperClock.activeConsoleUserID())) != nil else { return false }
        connection.setCodeSigningRequirement(trust.appRequirement)
        let peer = ClosedLidPeer(userID: uid, auditSessionID: UInt32(bitPattern: connection.auditSessionIdentifier), connectionID: UUID())
        let session = ClosedLidWireSession(service: service, peer: peer, activeUserID: { HelperClock.activeConsoleUserID() })
        connection.exportedInterface = NSXPCInterface(with: TilveroClosedLidXPC.self)
        connection.exportedObject = ExportedClosedLidSession(session)
        let disconnect: @Sendable () -> Void = {
            if session.revoke() { Task { await session.disconnectAfterRevocation() } }
        }
        connection.invalidationHandler = disconnect
        connection.interruptionHandler = disconnect
        connection.resume(); return true
    }
}

protocol ClosedLidWireTransport: Sendable {
    func request(open: Bool, payload: Data) async throws -> Data
    func invalidate() async
}
private final class NativeClosedLidWireTransport: ClosedLidWireTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    init(trust: ClosedLidTrust) {
        connection = NSXPCConnection(machServiceName: trust.helperIdentifier, options: .privileged)
        connection.setCodeSigningRequirement(trust.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: TilveroClosedLidXPC.self)
        connection.resume()
    }
    deinit { connection.invalidate() }
    func invalidate() async { connection.invalidate() }
    func request(open: Bool, payload: Data) async throws -> Data {
        guard payload.count <= ClosedLidLimits.maximumPayloadBytes else { throw ClosedLidFailure.malformed }
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = ClosedLidReplyDeadline(completion: { data in continuation.resume(returning: data) }, onTimeout: { [self] in connection.invalidate() })
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in deadline.resolve(lidFailure(ClosedLidFailure.unavailable)) }) as? TilveroClosedLidXPC else {
                deadline.resolve(lidFailure(ClosedLidFailure.wrongSession)); return
            }
            if open { proxy.openSession(version: ClosedLidLimits.protocolVersion, reply: { deadline.resolve($0) }) }
            else { proxy.perform(payload, reply: { deadline.resolve($0) }) }
        }
    }
}

public actor ClosedLidXPCClient: ClosedLidClientTransport {
    private let channel: any ClosedLidWireTransport
    private var token: UUID?
    private var generation: UInt64 = 0
    private var busy = false
    private var invalidated = false
    private var epoch: UInt64 = 0
    public init(trust: ClosedLidTrust) throws {
        try trust.verify(helper: false)
        channel = NativeClosedLidWireTransport(trust: trust)
    }
    init(channel: any ClosedLidWireTransport) { self.channel = channel }
    public func openSession() async throws -> ClosedLidReply {
        guard !invalidated else { throw ClosedLidFailure.wrongSession }
        guard !busy else { throw ClosedLidFailure.busy }
        busy = true; defer { busy = false }
        let startEpoch = epoch
        let response = try await request(open: true, payload: Data())
        guard !invalidated, epoch == startEpoch else { throw ClosedLidFailure.wrongSession }
        if !response.accepted {
            // Refusal may contain the authoritative pending-recovery state needed
            // after reconnect. Preserve it without granting any submit authority.
            await invalidate()
            return response
        }
        guard let token = response.sessionToken, response.generation < .max else {
            await invalidate(); throw response.failure ?? .wrongSession
        }
        self.token = token; generation = response.generation
        return response
    }
    public func submit(_ command: ClosedLidCommand) async throws -> ClosedLidReply {
        guard !invalidated, let token else { throw ClosedLidFailure.wrongSession }
        guard !busy else { throw ClosedLidFailure.busy }
        busy = true; defer { busy = false }
        let startEpoch = epoch
        guard generation < .max else { throw ClosedLidFailure.staleGeneration }
        // Every command is sequenced. Only an authoritative controller reply can
        // consume a generation; rejection before durable admission leaves it reusable.
        let expected = generation + 1
        let envelope = ClosedLidEnvelope(sessionToken: token, generation: expected, command: command)
        let response = try await request(open: false, payload: JSONEncoder().encode(envelope))
        guard !invalidated, epoch == startEpoch else { throw ClosedLidFailure.wrongSession }
        guard let replyToken = response.sessionToken else {
            // Transport-level failures have no authoritative generation.
            guard !response.accepted else { await invalidate(); throw ClosedLidFailure.wrongSession }
            await invalidate()
            return response
        }
        guard replyToken == token else { await invalidate(); throw ClosedLidFailure.wrongSession }
        guard response.generation >= generation,
              !response.accepted || response.generation == expected else { await invalidate(); throw ClosedLidFailure.staleGeneration }
        generation = response.generation
        return response
    }
    public func invalidate() async {
        token = nil; invalidated = true; epoch &+= 1
        await channel.invalidate()
    }
    private func request(open: Bool, payload: Data) async throws -> ClosedLidReply {
        do {
            let data = try await channel.request(open: open, payload: payload)
            guard data.count <= ClosedLidLimits.maximumReplyBytes else { throw ClosedLidFailure.malformed }
            do { return try JSONDecoder().decode(ClosedLidReply.self, from: data) }
            catch { throw ClosedLidFailure.malformed }
        } catch {
            await invalidate()
            throw error
        }
    }
}
