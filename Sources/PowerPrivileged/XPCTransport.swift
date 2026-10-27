import Foundation
import PowerCore

@objc public protocol TilveroHelperXPC {
    func openSession(version: Int, reply: @escaping @Sendable (Data) -> Void)
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}

private func encodedFailure(_ error: any Error) -> Data {
    // Errors contain bounded symbolic reasons, no raw payloads, tokens or hardware identifiers.
    (try? JSONEncoder().encode(HelperReply(reason: String(String(describing: error).prefix(512))))) ?? Data()
}
private final class ExportedSession: NSObject, TilveroHelperXPC, @unchecked Sendable {
    let peer: PeerSession
    let controller: PrivilegedController
    init(peer: PeerSession, controller: PrivilegedController) { self.peer = peer; self.controller = controller }
    func openSession(version: Int, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            do {
                let response = try await controller.openSession(peer: peer, version: version, activeUserID: HelperClock.activeConsoleUserID())
                reply(try JSONEncoder().encode(response))
            } catch { reply(encodedFailure(error)) }
        }
    }
    func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard payload.count <= HelperEnvelope.maximumBytes else { reply(encodedFailure(PrivilegeError.malformed)); return }
        Task {
            do { reply(try JSONEncoder().encode(await controller.perform(payload, peer: peer, activeUserID: HelperClock.activeConsoleUserID()))) }
            catch {
                if var state = try? await controller.readState() {
                    state.accepted = false; state.configurationVerified = false; state.behaviorObserved = false
                    state.reason = String(String(describing: error).prefix(512))
                    reply((try? JSONEncoder().encode(state)) ?? encodedFailure(error))
                } else { reply(encodedFailure(error)) }
            }
        }
    }
}

public final class AuthenticatedHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let trust: HelperTrustConfiguration
    private let controller: PrivilegedController
    public init(trust: HelperTrustConfiguration, controller: PrivilegedController) throws {
        try trust.verifyCurrentProcess(helper: true)
        self.trust = trust; self.controller = controller; listener = NSXPCListener(machServiceName: trust.helperIdentifier)
        super.init(); listener.delegate = self
    }
    public func resume() { listener.resume() }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid >= 500, uid == HelperClock.activeConsoleUserID() else { return false }
        // Supported Foundation SDK API enforces the precise signed peer before any message is accepted.
        connection.setCodeSigningRequirement(trust.appRequirement)
        let peer = PeerSession(userID: uid, auditSessionID: UInt32(bitPattern: connection.auditSessionIdentifier), connectionID: UUID())
        let exported = ExportedSession(peer: peer, controller: controller)
        connection.exportedInterface = NSXPCInterface(with: TilveroHelperXPC.self)
        connection.exportedObject = exported
        connection.invalidationHandler = { [controller] in Task { await controller.disconnect(peer: peer) } }
        connection.interruptionHandler = { [controller] in Task { await controller.disconnect(peer: peer) } }
        connection.resume(); return true
    }
}

private final class DeadlineReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func resolve(_ result: Result<Data, any Error>) {
        lock.lock(); let next = continuation; continuation = nil; lock.unlock()
        next?.resume(with: result)
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    deinit { connection.invalidate() }
}
public actor HelperClient {
    private let transport: XPCConnectionBox
    private var connection: NSXPCConnection { transport.connection }
    private var sessionToken: UUID?
    private var generation: UInt64 = 0
    public init(trust: HelperTrustConfiguration) throws {
        try trust.verifyCurrentProcess(helper: false)
        let connection = NSXPCConnection(machServiceName: trust.helperIdentifier, options: .privileged)
        connection.setCodeSigningRequirement(trust.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: TilveroHelperXPC.self)
        connection.resume()
        transport = XPCConnectionBox(connection)
    }
    public func openSession() async throws -> HelperReply {
        let data = try await request(open: true, payload: Data())
        let reply = try JSONDecoder().decode(HelperReply.self, from: data)
        guard reply.accepted, let token = reply.sessionToken else { throw PrivilegeError.wrongSession }
        sessionToken = token; generation = reply.generation; return reply
    }
    public func submit(_ command: HelperCommand) async throws -> HelperReply {
        guard let sessionToken else { throw PrivilegeError.wrongSession }
        if command.isMutation { generation &+= 1 }
        let envelope = HelperEnvelope(sessionToken: sessionToken, generation: generation, command: command)
        let data = try await request(open: false, payload: JSONEncoder().encode(envelope))
        let reply = try JSONDecoder().decode(HelperReply.self, from: data)
        guard reply.generation == generation || !reply.accepted else { throw PrivilegeError.staleGeneration }
        return reply
    }
    public func invalidate() { sessionToken = nil; connection.invalidate() }
    private func request(open: Bool, payload: Data) async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            let pending = DeadlineReply(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { pending.resolve(.failure(PrivilegeError.timeout)) }
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in pending.resolve(.failure(error)) }) as? TilveroHelperXPC else {
                pending.resolve(.failure(PrivilegeError.wrongSession)); return
            }
            let reply: @Sendable (Data) -> Void = { data in
                guard data.count <= 65_536 else { pending.resolve(.failure(PrivilegeError.malformed)); return }
                pending.resolve(.success(data))
            }
            if open { remote.openSession(version: HelperEnvelope.protocolVersion, reply: reply) } else { remote.perform(payload, reply: reply) }
        }
    }
}
