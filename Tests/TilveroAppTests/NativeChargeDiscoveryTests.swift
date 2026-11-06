import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

@MainActor final class NativeChargeDiscoveryTests: XCTestCase {
    func testPartialCurrentTargetIsDistinctFromDiagnosticTargetAndDraft() async throws {
        let fixture = try DiscoveryFixture(admitted: false)
        defer { fixture.cleanUp() }
        await fixture.transport.setPartialObservation(current: 100, stored: 90)
        await fixture.model.refreshNativeCharge()
        XCTAssertEqual(fixture.native.currentReportedTarget, 100)
        XCTAssertEqual(fixture.native.diagnosticStoredTarget, 90)
        XCTAssertNotNil(fixture.native.incompleteObservation)
        XCTAssertNil(fixture.native.nativeSetting)
        XCTAssertNil(fixture.native.observed)
        XCTAssertNil(fixture.model.chargeState?.appliedTarget)
        XCTAssertEqual(fixture.model.draftText, "100", "An untouched draft may start from the reported target, never the lowest offered target")
        fixture.model.setDraft(90)
        await fixture.model.refreshNativeCharge()
        XCTAssertEqual(fixture.model.draftText, "90")
        XCTAssertEqual(fixture.native.currentReportedTarget, 100)
        XCTAssertFalse(fixture.model.canApply)
        let writes = await fixture.transport.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.admission.path))
    }

    func testStalePartialTargetCannotInitializeDraftOrDisplayStoredTarget() async throws {
        let fixture = try DiscoveryFixture(admitted: false)
        defer { fixture.cleanUp() }
        await fixture.transport.setPartialObservation(current: 100, stored: 90, date: Date().addingTimeInterval(-120))
        await fixture.model.refreshNativeCharge()
        XCTAssertNil(fixture.native.currentReportedTarget)
        XCTAssertNil(fixture.native.diagnosticStoredTarget)
        XCTAssertTrue(fixture.model.draftText.isEmpty)
        XCTAssertFalse(fixture.native.canApply)
    }

    func testCompleteOrUnrelatedFailedReadClearsPartialObservation() async throws {
        for fullRead in [false, true] {
            let fixture = try DiscoveryFixture(admitted: false)
            defer { fixture.cleanUp() }
            await fixture.transport.setPartialObservation(current: 100, stored: 90)
            await fixture.model.refreshNativeCharge()
            XCTAssertNotNil(fixture.native.incompleteObservation)
            if fullRead { await fixture.transport.setUnknown(false) }
            else { await fixture.transport.setUnsupported() }
            await fixture.model.refreshNativeCharge()
            XCTAssertNil(fixture.native.incompleteObservation)
            XCTAssertNil(fixture.native.diagnosticStoredTarget)
            XCTAssertEqual(fixture.native.currentReportedTarget, fullRead ? 85 : nil)
            if fullRead { XCTAssertNil(fixture.native.message, "A recovered complete read clears its former partial-read warning") }
            XCTAssertFalse(fixture.native.admitted)
        }
    }

    func testUnknownConfigurationDoesNotInventLowestOfferedLimitAsDraft() async throws {
        let fixture = try DiscoveryFixture(admitted: false)
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.model.draftText.isEmpty, "An unread setting must not look like an 80% limit")
        await fixture.model.refreshNativeCharge()
        XCTAssertTrue(fixture.model.draftText.isEmpty)
        XCTAssertNil(fixture.model.draftTarget)

        fixture.model.setDraft(90)
        await fixture.model.refreshNativeCharge()
        XCTAssertEqual(fixture.model.draftText, "90", "A deliberately selected draft survives read failure")
        XCTAssertEqual(fixture.model.draftTarget, 90)
        XCTAssertFalse(fixture.model.canApply)
    }

    func testUnknownStateKeepsNativeEditorVisibleWithoutAuthorizingWrites() async throws {
        for admitted in [false, true] {
            let fixture = try DiscoveryFixture(admitted: admitted)
            defer { fixture.cleanUp() }
            await fixture.native.refresh()

            XCTAssertTrue(fixture.model.usesNativeCharge)
            XCTAssertTrue(fixture.model.canShowChargeControls)
            XCTAssertEqual(fixture.model.acceptedTargets, [80, 85, 90, 95, 100])
            XCTAssertNil(fixture.native.nativeSetting)
            XCTAssertNil(fixture.native.observed)
            XCTAssertFalse(fixture.native.isAvailable)
            XCTAssertFalse(fixture.model.canPerformChargeActions)
            fixture.model.setDraft(90)
            XCTAssertFalse(fixture.model.canApply, "A discovered target is only a draft until the policy is confirmed")
            do { try await fixture.native.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Unknown state must block Apply") } catch {}
            do { try await fixture.native.qualify(); XCTFail("Unknown state must block qualification before any setter") } catch {}
            let writes = await fixture.transport.writes
            XCTAssertTrue(writes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.admission.path))
        }
    }

    func testUnknownStateClearsCachedPreferenceAcrossEveryReadEntryPoint() async throws {
        for action in ["refresh", "apply", "restore", "qualify"] {
            let fixture = try DiscoveryFixture(admitted: true)
            defer { fixture.cleanUp() }
            await fixture.transport.setUnknown(false)
            await fixture.native.refresh()
            if action == "apply" || action == "restore" {
                try await fixture.native.apply(90, batteryPercent: 60, batteryFresh: true)
            }
            let journalBefore = try? Data(contentsOf: fixture.journal)
            let writesBefore = await fixture.transport.writes
            let ownershipBefore = fixture.native.hasOwnedSettings
            XCTAssertNotNil(fixture.native.nativeSetting)
            await fixture.transport.setUnknown(true)

            do {
                switch action {
                case "refresh": await fixture.native.refresh()
                case "apply": try await fixture.native.apply(95, batteryPercent: 60, batteryFresh: true)
                case "restore": _ = try await fixture.native.restore(batteryPercent: 60, batteryFresh: true)
                default: try await fixture.native.qualify()
                }
                if action != "refresh" { XCTFail("The unknown state must stop \(action)") }
            } catch {}

            XCTAssertNil(fixture.native.nativeSetting, "\(action) must not display a cached enabled setting after an unknown state")
            XCTAssertNil(fixture.native.observed)
            XCTAssertEqual(fixture.native.acceptedTargets, [80, 85, 90, 95, 100])
            XCTAssertFalse(fixture.native.canApply)
            XCTAssertEqual(fixture.native.hasOwnedSettings, ownershipBefore)
            XCTAssertEqual(try? Data(contentsOf: fixture.journal), journalBefore)
            let writesAfter = await fixture.transport.writes
            XCTAssertEqual(writesAfter, writesBefore, "Discovery may not dispatch a setter")
        }
    }

    func testFullReadRecoversPresentationWithoutGrantingAdmission() async throws {
        let fixture = try DiscoveryFixture(admitted: false)
        defer { fixture.cleanUp() }
        await fixture.native.refresh()
        XCTAssertTrue(fixture.model.usesNativeCharge)
        await fixture.transport.setUnknown(false)
        await fixture.native.refresh()
        XCTAssertEqual(fixture.native.nativeSetting?.configuration.target, 85)
        XCTAssertEqual(fixture.native.observed?.configuration.target, 85)
        XCTAssertFalse(fixture.native.admitted)
        XCTAssertFalse(fixture.model.canPerformChargeActions)
        let writes = await fixture.transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testUnsupportedInterfaceDoesNotInventTargets() async throws {
        let fixture = try DiscoveryFixture(admitted: false)
        defer { fixture.cleanUp() }
        await fixture.transport.setUnsupported()
        await fixture.native.refresh()
        XCTAssertFalse(fixture.model.usesNativeCharge)
        XCTAssertFalse(fixture.model.canShowChargeControls)
        XCTAssertTrue(fixture.native.acceptedTargets.isEmpty)
        let writes = await fixture.transport.writes
        XCTAssertTrue(writes.isEmpty)
    }
}

@MainActor private struct DiscoveryFixture {
    let suite = "NativeChargeDiscovery-\(UUID())"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeChargeDiscovery-\(UUID())")
    let preferences: UserDefaults
    let transport = DiscoveryTransport()
    let native: NativeChargeService
    let model: TilveroModel
    var journal: URL { root.appendingPathComponent("session.json") }
    var admission: URL { root.appendingPathComponent("admission.json") }

    init(admitted: Bool) throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(false, forKey: "historyEnabled")
        native = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("session.json"),
            admitted: admitted, verificationAttempts: 2, environment: "discovery-fixture",
            batteryProvider: { .init(percent: 60, externalPower: true) }, admissionURL: root.appendingPathComponent("admission.json"))
        model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: [:]), preferences: preferences,
            historyURL: root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { .unavailable(reason: "Discovery fixture; no native telemetry") }, nativeCharge: native)
    }

    func cleanUp() {
        model.stop()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor DiscoveryTransport: NativeChargeTransport {
    private var unknown = true
    private var unsupported = false
    private var target = 85
    private var enabled = true
    private var partialCurrent: Int?
    private var partialStored: Int?
    private var partialDate: Date?
    private(set) var writes: [String] = []
    func setUnknown(_ value: Bool) { unknown = value }
    func setUnsupported() { unsupported = true }
    func setPartialObservation(current: Int?, stored: Int?, date: Date? = nil) {
        partialCurrent = current; partialStored = stored; partialDate = date
    }
    func read() throws -> NativeChargeSnapshot {
        if unsupported { throw NSError(domain: "Tilvero.NativeCharge", code: 4) }
        if unknown {
            throw NativeChargeReadFailure(supportedTargets: [80, 85, 90, 95, 100], currentTarget: partialCurrent,
                rawManualState: 3, diagnosticStoredTarget: partialStored, collectedAt: partialDate ?? Date())!
        }
        return .init(configuration: .init(enabled: enabled, target: target, optimizedCharging: true),
            supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: enabled ? target : nil)
    }
    func setLimit(_ value: Int) { writes.append("limit\(value)"); target = value }
    func setEnabled(_ value: Bool) { writes.append("enabled\(value)"); enabled = value }
}
