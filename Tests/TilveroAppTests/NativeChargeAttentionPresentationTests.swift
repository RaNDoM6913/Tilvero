import XCTest
import ChargeBackends
@testable import TilveroApp

final class NativeChargeAttentionPresentationTests: XCTestCase {
    func testSavedSessionReviewUsesDiagnosticsInsteadOfPageBanner() {
        let saved = presentation(.sessionReview)
        XCTAssertTrue(saved.requiresGlobalAttention, "The saved issue must remain globally discoverable")
        XCTAssertFalse(saved.showsAttentionBanner, "Readable85 plus a saved review must not dominate every page")
        XCTAssertNil(saved.activePolicy, "A quieter presentation must not invent an active policy")
    }

    func testUnknownMutationAndJournalIntegrityRemainProminent() {
        for reason in [NativeChargePresentation.Attention.mutationUnresolved, .journalIntegrity] {
            let unresolved = presentation(reason)
            XCTAssertTrue(unresolved.requiresGlobalAttention)
            XCTAssertTrue(unresolved.showsAttentionBanner, "A readable85 preference cannot hide an unresolved operation")
        }
        XCTAssertTrue(presentation(.sessionReview, purpose: .setLimit(target: 85)).showsAttentionBanner)
        XCTAssertTrue(presentation(.sessionReview, recordedMutation: true).showsAttentionBanner)
        XCTAssertTrue(presentation(.sessionReview, savedAction: true).showsAttentionBanner)
        XCTAssertTrue(presentation(.sessionReview, owned: false).showsAttentionBanner, "An unreadable journal must not become a passive owned session")
    }

    func testPendingIntentStaysProminentThroughReviewAndSuspendedRead() {
        for reason in [NativeChargePresentation.Attention.sessionReview, .operationPending, .lowerTargetPending, .restorationPending] {
            XCTAssertTrue(presentation(reason, purpose: .read, pending: 80).showsAttentionBanner)
            XCTAssertTrue(presentation(reason, purpose: .read, restoring: 80).showsAttentionBanner)
        }
        XCTAssertFalse(presentation(.operationPending, purpose: .read).showsAttentionBanner)
        XCTAssertFalse(presentation(.sessionReview, purpose: .read).showsAttentionBanner)
    }

    func testOwnedUnconfirmedPolicyRemainsVisibleWithoutInventingOwnerAttention() {
        XCTAssertTrue(presentation(.policyUnconfirmed).showsAttentionBanner)
        XCTAssertFalse(presentation(.policyUnconfirmed, owned: false).showsAttentionBanner)
        XCTAssertFalse(presentation(.none).showsAttentionBanner)
    }

    private func presentation(_ attention: NativeChargePresentation.Attention,
                              purpose: NativeChargeOperationGate.Purpose? = nil,
                              pending: Int? = nil, restoring: Int? = nil,
                              owned: Bool = true, recordedMutation: Bool = false,
                              savedAction: Bool = false) -> NativeChargePresentation {
        .init(currentPreference: .init(enabled: true, target: 85, optimizedCharging: true), activePolicy: nil,
              pendingPurpose: purpose, hasOwnership: owned, pendingTarget: pending,
              restorationTarget: restoring, attention: attention,
              hasRecordedMutation: recordedMutation, hasSavedAction: savedAction)
    }
}
