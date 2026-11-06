import XCTest
@testable import ClosedLidControl

final class ClosedLidTransportTests: XCTestCase {
    func testServerDerivesPeerAndChecksConsoleOnEachRequest() async throws {
        let service = WireService(), user = WireUser()
        let peer = ClosedLidPeer(userID: 501, auditSessionID: 77, connectionID: UUID())
        let session = ClosedLidWireSession(service: service, peer: peer, activeUserID: { user.uid })
        let opened = try decode(await session.open(version: 1))
        XCTAssertTrue(opened.accepted)
        let received = await service.lastPeer
        XCTAssertEqual(received, peer)
        user.uid = 502
        let refused = try decode(await session.perform(Data("{}".utf8)))
        XCTAssertEqual(refused.failure, .wrongUser)
        let performed = await service.performCount
        XCTAssertEqual(performed, 0)
    }
    func testBoundsMalformedAndVersionDeniedBeforeServing() async throws {
        let service = WireService()
        let session = makeSession(service)
        let version = try decode(await session.open(version: 2))
        XCTAssertEqual(version.failure, .malformed)
        for payload in [Data(repeating: 32, count: ClosedLidLimits.maximumPayloadBytes + 1), Data("{}".utf8)] {
            let result = try decode(await session.perform(payload))
            XCTAssertEqual(result.failure, .malformed)
        }
        let counts = await service.counts
        XCTAssertEqual(counts, [0,0])
    }
    func testOversizedReplyIsBoundedAndDisconnectIsIdempotent() async throws {
        let service = WireService(hugeReply: true)
        let session = makeSession(service)
        let data = await session.open(version: 1)
        XCTAssertLessThanOrEqual(data.count, ClosedLidLimits.maximumReplyBytes)
        XCTAssertEqual(try decode(data).failure, .malformed)
        await session.disconnect(); await session.disconnect()
        let invalidatedReply = try decode(await session.open(version: 1))
        XCTAssertEqual(invalidatedReply.failure, .wrongSession)
        let count = await service.disconnections
        XCTAssertEqual(count, 1)
    }
    func testClientBindsTokenAndGenerationAndInvalidation() async throws {
        let channel = WireChannel()
        let client = ClosedLidXPCClient(channel: channel)
        _ = try await client.openSession()
        _ = try await client.submit(.start(seconds: 30))
        _ = try await client.submit(.readState)
        let envelopes = await channel.envelopes
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes.first?.sessionToken, channel.token)
        XCTAssertEqual(envelopes.map(\.generation), [1, 2])
        await client.invalidate()
        do { _ = try await client.submit(.readState); XCTFail("Invalidated client submitted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
    }
    func testClientResynchronizesDeniedBeforeAndAfterDurableAdmission() async throws {
        let channel = WireChannel()
        let client = ClosedLidXPCClient(channel: channel)
        _ = try await client.openSession()
        await channel.denyNext(admitted: false)
        _ = try await client.submit(.start(seconds: 30))
        await channel.denyNext(admitted: true)
        _ = try await client.submit(.start(seconds: 30))
        _ = try await client.submit(.readState)
        let values = await channel.envelopes.map(\.generation)
        XCTAssertEqual(values, [1, 1, 2])
    }
    func testRefusedOpenPreservesAuthoritativeRecoveryStateAndRevokesSubmitAuthority() async throws {
        var state = ClosedLidState()
        state.phase = .restoreAcceptedAwaitingWitness
        state.restoreCommandAccepted = true
        state.recoveryRequired = true
        state.sessionID = UUID()
        state.reason = "Restore accepted; waiting for fresh native witness"
        let expected = ClosedLidReply(accepted: false, sessionToken: UUID(), generation: 7, state: state, failure: .recoveryRequired)
        let channel = FixedOpenWireChannel(response: expected)
        let client = ClosedLidXPCClient(channel: channel)
        let response = try await client.openSession()
        XCTAssertEqual(response, expected)
        let invalidated = await channel.invalidated
        XCTAssertTrue(invalidated)
        do { _ = try await client.submit(.start(seconds: 30)); XCTFail("Refused open acquired submit authority") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
        let calls = await channel.requests
        XCTAssertEqual(calls, 1)
    }
    func testAcceptedOpenMissingTokenOrExhaustedGenerationStillThrowsAndRevokes() async throws {
        for response in [ClosedLidReply(accepted: true), ClosedLidReply(accepted: true, sessionToken: UUID(), generation: .max)] {
            let channel = FixedOpenWireChannel(response: response)
            let client = ClosedLidXPCClient(channel: channel)
            do { _ = try await client.openSession(); XCTFail("Malformed accepted open returned") }
            catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
            let invalidated = await channel.invalidated
            XCTAssertTrue(invalidated)
            do { _ = try await client.submit(.readState); XCTFail("Malformed open retained authority") }
            catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
        }
    }
    func testClientRejectsOversizedAndWrongGenerationReplies() async throws {
        let channel = WireChannel()
        let client = ClosedLidXPCClient(channel: channel)
        _ = try await client.openSession()
        await channel.setWrongGeneration()
        do { _ = try await client.submit(.start(seconds: 30)); XCTFail("Wrong generation accepted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .staleGeneration) }
        do { _ = try await client.submit(.readState); XCTFail("Bad-generation channel stayed usable") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
        let huge = WireChannel(oversize: true)
        do { _ = try await ClosedLidXPCClient(channel: huge).openSession(); XCTFail("Oversized response accepted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .malformed) }
    }
    func testWrongReplyTokenStillThrowsAndRevokesClient() async throws {
        let channel = WireChannel()
        let client = ClosedLidXPCClient(channel: channel)
        _ = try await client.openSession()
        await channel.setWrongToken()
        do { _ = try await client.submit(.readState); XCTFail("Wrong reply token accepted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
        do { _ = try await client.submit(.readState); XCTFail("Wrong token channel stayed usable") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
    }
    func testDeadlineRevokesBeforeTimeoutReplyAndIgnoresLateSuccess() async throws {
        let result = DeadlineResults()
        let received = expectation(description: "one bounded timeout")
        let deadline = ClosedLidReplyDeadline(seconds: 0.02, completion: { data in
            result.append(data); received.fulfill()
        }, onTimeout: { result.revoke() })
        await fulfillment(of: [received], timeout: 1)
        deadline.resolve(try JSONEncoder().encode(ClosedLidReply(accepted: true)))
        XCTAssertTrue(result.revokedAtReply)
        XCTAssertEqual(result.data.count, 1)
        XCTAssertEqual(try decode(XCTUnwrap(result.data.first)).failure, .timeout)
    }
    func testInvalidationDuringOpenNeverRestoresLateSessionToken() async throws {
        let channel = HoldingWireChannel()
        let client = ClosedLidXPCClient(channel: channel)
        let opened = Task { try await client.openSession() }
        await channel.waitUntilStarted()
        do { _ = try await client.openSession(); XCTFail("Reentrant open accepted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .busy) }
        await client.invalidate()
        await channel.finish()
        do { _ = try await opened.value; XCTFail("Late session returned") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
        do { _ = try await client.submit(.readState); XCTFail("Late session token restored") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .wrongSession) }
    }
    private func decode(_ data: Data) throws -> ClosedLidReply { try JSONDecoder().decode(ClosedLidReply.self, from: data) }
    private func makeSession(_ service: WireService) -> ClosedLidWireSession {
        .init(service: service, peer: .init(userID: 501, auditSessionID: 77, connectionID: UUID()), activeUserID: { 501 })
    }
}
private final class WireUser: @unchecked Sendable { var uid: UInt32? = 501 }
private actor WireService: ClosedLidRequestServing {
    var lastPeer: ClosedLidPeer?; var openCount = 0; var performCount = 0; var disconnections = 0
    let hugeReply: Bool
    var counts: [Int] { [openCount, performCount] }
    init(hugeReply: Bool = false) { self.hugeReply = hugeReply }
    func openSession(peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply {
        lastPeer = peer; openCount += 1
        var state = ClosedLidState(); if hugeReply { state.reason = String(repeating: "x", count: 70_000) }
        return .init(accepted: true, sessionToken: UUID(), state: state)
    }
    func perform(_ envelope: ClosedLidEnvelope, peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply { performCount += 1; return .init(accepted: true, generation: envelope.generation) }
    func disconnect(peer: ClosedLidPeer) async { disconnections += 1 }
    func currentState() async throws -> ClosedLidState { .init() }
}
private actor WireChannel: ClosedLidWireTransport {
    nonisolated let token = UUID()
    var envelopes: [ClosedLidEnvelope] = []
    var wrongGeneration = false
    var wrongToken = false
    var denial: Bool?
    var authoritativeGeneration: UInt64 = 0
    let oversize: Bool
    init(oversize: Bool = false) { self.oversize = oversize }
    func setWrongGeneration() { wrongGeneration = true }
    func setWrongToken() { wrongToken = true }
    func denyNext(admitted: Bool) { denial = admitted }
    func request(open: Bool, payload: Data) async throws -> Data {
        if oversize { return Data(repeating: 32, count: ClosedLidLimits.maximumReplyBytes + 1) }
        if open { return try JSONEncoder().encode(ClosedLidReply(accepted: true, sessionToken: token)) }
        let envelope = try JSONDecoder().decode(ClosedLidEnvelope.self, from: payload)
        envelopes.append(envelope)
        if let admitted = denial {
            denial = nil
            if admitted { authoritativeGeneration = envelope.generation }
            return try JSONEncoder().encode(ClosedLidReply(sessionToken: token, generation: authoritativeGeneration, failure: .busy))
        }
        authoritativeGeneration = envelope.generation
        return try JSONEncoder().encode(ClosedLidReply(accepted: true, sessionToken: wrongToken ? UUID() : token, generation: wrongGeneration ? 999 : envelope.generation))
    }
    func invalidate() async {}
}

private final class DeadlineResults: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Data] = []
    private var revoked = false
    private var sawRevocation = false
    var data: [Data] { lock.withLock { replies } }
    var revokedAtReply: Bool { lock.withLock { sawRevocation } }
    func revoke() { lock.withLock { revoked = true } }
    func append(_ data: Data) { lock.withLock { sawRevocation = revoked; replies.append(data) } }
}
private actor HoldingWireChannel: ClosedLidWireTransport {
    var continuation: CheckedContinuation<Data, any Error>?
    func request(open: Bool, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func finish() {
        continuation?.resume(returning: (try? JSONEncoder().encode(ClosedLidReply(accepted: true, sessionToken: UUID()))) ?? Data())
        continuation = nil
    }
    func invalidate() async {}
}

private actor FixedOpenWireChannel: ClosedLidWireTransport {
    let response: ClosedLidReply
    var invalidated = false
    var requests = 0
    init(response: ClosedLidReply) { self.response = response }
    func request(open: Bool, payload: Data) async throws -> Data {
        requests += 1
        return try JSONEncoder().encode(response)
    }
    func invalidate() async { invalidated = true }
}
