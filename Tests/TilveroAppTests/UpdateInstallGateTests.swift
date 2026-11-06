import XCTest
@testable import TilveroApp

@MainActor
final class UpdateInstallGateTests: XCTestCase {
    func testRestartRetryRetainsFreshConsentAndReadinessAfterLaterAndFailure() async {
        var consent = false, blocked = false, attempts = 0, preparations = 0
        let gate = UpdateInstallGate(readOnlyReadiness: { blocked ? ["recovery"] : [] },
            prepareAfterExplicitConsent: { preparations += 1; return true }, releaseInstallationExclusion: {})
        XCTAssertTrue(gate.beginStaging(explicitConsent: true))
        let action = UpdateInstallProgressAction()
        action.setRetry {
            attempts += 1; gate.invalidateHandoff()
            Task { _ = await gate.authorizeHandoff(explicitConsent: consent) }
        }
        action.perform(); await Task.yield()
        XCTAssertEqual(attempts, 1); XCTAssertEqual(preparations, 0)
        consent = true; blocked = true
        action.perform(); await Task.yield()
        XCTAssertEqual(attempts, 2); XCTAssertEqual(preparations, 0)
        blocked = false
        action.perform()
        for _ in 0..<20 where !gate.validatedHandoffAllowsTermination { await Task.yield() }
        XCTAssertEqual(attempts, 3); XCTAssertEqual(preparations, 1)
        XCTAssertTrue(gate.validatedHandoffAllowsTermination)
        action.clear(); action.perform(); XCTAssertEqual(attempts, 3)
    }

    func testDownloadCancellationRemainsOneShot() {
        var cancelled = 0
        let action = UpdateInstallProgressAction()
        action.setCancellation { cancelled += 1 }
        action.perform(); action.perform()
        XCTAssertEqual(cancelled, 1)
    }
    func testCheckingAndStagingNeverPrepareWithoutExplicitConsent() async {
        var reads = 0, preparations = 0, releases = 0
        let gate = UpdateInstallGate(readOnlyReadiness: { reads += 1; return [] },
                                     prepareAfterExplicitConsent: { preparations += 1; return true },
                                     releaseInstallationExclusion: { releases += 1 })
        XCTAssertFalse(gate.beginStaging(explicitConsent: false))
        let rejected = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertFalse(rejected)
        XCTAssertEqual(reads, 0); XCTAssertEqual(preparations, 0)
        gate.protectUpdateSession()
        XCTAssertTrue(gate.installationBlocksQuit)
        XCTAssertFalse(gate.validatedHandoffAllowsTermination)
        XCTAssertEqual(reads, 0); XCTAssertEqual(preparations, 0)
        XCTAssertTrue(gate.beginStaging(explicitConsent: true))
        XCTAssertTrue(gate.installationBlocksQuit)
        XCTAssertFalse(gate.validatedHandoffAllowsTermination)
        XCTAssertEqual(reads, 1); XCTAssertEqual(preparations, 0)
        gate.finish(); XCTAssertEqual(releases, 1)
    }

    func testUnknownOwnershipBlocksBeforeSharedRecovery() async {
        var preparations = 0
        let gate = UpdateInstallGate(readOnlyReadiness: { ["unknown journal"] },
                                     prepareAfterExplicitConsent: { preparations += 1; return true }, releaseInstallationExclusion: {})
        XCTAssertFalse(gate.beginStaging(explicitConsent: true))
        let rejected = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertFalse(rejected); XCTAssertEqual(preparations, 0)
    }

    func testEveryResumedAndFinalHandoffRechecksAndRequiresConsent() async {
        var blockers: [String] = [], preparations = 0
        let gate = UpdateInstallGate(readOnlyReadiness: { blockers },
                                     prepareAfterExplicitConsent: { preparations += 1; return true }, releaseInstallationExclusion: {})
        XCTAssertTrue(gate.beginStaging(explicitConsent: true))
        let first = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertTrue(first); XCTAssertEqual(preparations, 1)
        gate.invalidateHandoff()
        let noConsent = await gate.authorizeHandoff(explicitConsent: false)
        XCTAssertFalse(noConsent); XCTAssertFalse(gate.validatedHandoffAllowsTermination)
        blockers = ["new ownership"]
        let resumed = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertFalse(resumed); XCTAssertEqual(preparations, 1)
        blockers = []
        let final = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertTrue(final); XCTAssertEqual(preparations, 2)
    }

    func testReadinessIsFreshAfterAsyncPreparationAndFailureReleasesExclusion() async {
        var blockers: [String] = [], releases = 0
        let gate = UpdateInstallGate(readOnlyReadiness: { blockers },
                                     prepareAfterExplicitConsent: { blockers = ["foreign session"]; return true },
                                     releaseInstallationExclusion: { releases += 1 })
        XCTAssertTrue(gate.beginStaging(explicitConsent: true))
        let accepted = await gate.authorizeHandoff(explicitConsent: true)
        XCTAssertFalse(accepted); XCTAssertFalse(gate.validatedHandoffAllowsTermination)
        XCTAssertEqual(releases, 1)
    }

    func testCancelDuringSuspendedPreparationCannotAuthorizeLateHandoff() async {
        var resume: CheckedContinuation<Bool, Never>?
        let gate = UpdateInstallGate(readOnlyReadiness: { [] }, prepareAfterExplicitConsent: {
            await withCheckedContinuation { resume = $0 }
        }, releaseInstallationExclusion: {})
        XCTAssertTrue(gate.beginStaging(explicitConsent: true))
        let work = Task { await gate.authorizeHandoff(explicitConsent: true) }
        while resume == nil { await Task.yield() }
        gate.finish(); resume?.resume(returning: true)
        let accepted = await work.value
        XCTAssertFalse(accepted); XCTAssertFalse(gate.validatedHandoffAllowsTermination)
        XCTAssertFalse(gate.installationBlocksQuit)
    }
}
