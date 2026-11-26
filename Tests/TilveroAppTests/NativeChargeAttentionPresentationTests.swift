// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
@testable import TilveroApp

final class NativeChargeAttentionPresentationTests: XCTestCase {
    /// Only a session file that could not be handled safely is flagged globally (banner, Diagnostics dot); every other state
    /// is a local status line that blocks nothing.
    func testOnlyJournalIntegrityIsGlobal() {
        XCTAssertTrue(presentation(.journalIntegrity).requiresGlobalAttention)
        XCTAssertTrue(presentation(.journalIntegrity).showsAttentionBanner)
        for attention in [NativeChargePresentation.Attention.none, .mutationUnresolved, .operationPending, .policyUnconfirmed] {
            XCTAssertFalse(presentation(attention).requiresGlobalAttention, "\(attention)")
            XCTAssertFalse(presentation(attention, purpose: .setLimit(target: 85), recordedMutation: true).showsAttentionBanner, "\(attention)")
        }
        XCTAssertNil(presentation(.mutationUnresolved).activePolicy, "a quieter presentation must not invent an active policy")
    }

    /// The one status text: an unconfirmed change, the two-row hint, a pending operation only past its deadline, and nothing
    /// for a fresh stored setting.
    func testStatusTextSpeaksOnlyWhenThereIsSomethingToSay() {
        typealias T = NativeChargeStatusText
        XCTAssertEqual(T.text(presentation(.mutationUnresolved), .init()), "macOS has not confirmed the last change yet.")
        XCTAssertEqual(T.text(presentation(.mutationUnresolved), .init(registryConflict: true)), NativeChargeService.registryConflictMessage)
        XCTAssertEqual(T.text(presentation(.policyUnconfirmed), .init(registryConflict: true)), NativeChargeService.registryConflictMessage)
        XCTAssertNil(T.text(presentation(.policyUnconfirmed), .init(message: "x")), "a fresh stored setting is shown as it is")
        XCTAssertEqual(T.text(presentation(.policyUnconfirmed, preference: false), .init(message: "x")), "x")
        XCTAssertEqual(T.text(presentation(.policyUnconfirmed), .init(partialRead: true)), T.partialReadWarning)
        XCTAssertNil(T.text(presentation(.operationPending, purpose: .read), .init()), "a known setting's read has its spinner")
        XCTAssertEqual(T.text(presentation(.operationPending, purpose: .read, preference: false), .init()), "Reading the native charge policy…")
        XCTAssertEqual(T.text(presentation(.operationPending, purpose: .read, timedOut: true), .init()),
                       "The native policy read timed out. Further actions wait for the read to return.")
        XCTAssertEqual(T.text(presentation(.operationPending, purpose: .setLimit(target: 85), timedOut: true), .init()),
                       "The native setting operation timed out. Its outcome needs review; further writes are blocked.")
        XCTAssertEqual(T.text(presentation(.journalIntegrity), .init()), "The native session journal needs review before further changes.")
        XCTAssertNil(T.text(presentation(.none), .init()))
        XCTAssertTrue(T.isWarning(presentation(.journalIntegrity)))
        XCTAssertTrue(T.isWarning(presentation(.operationPending, purpose: .read, timedOut: true)))
        XCTAssertFalse(T.isWarning(presentation(.mutationUnresolved)))
    }

    private func presentation(_ attention: NativeChargePresentation.Attention,
                              purpose: NativeChargeOperationGate.Purpose? = nil, timedOut: Bool = false,
                              recordedMutation: Bool = false, preference: Bool = true) -> NativeChargePresentation {
        .init(currentPreference: preference ? .init(enabled: true, target: 85, optimizedCharging: true) : nil, activePolicy: nil,
              pendingPurpose: purpose, pendingTimedOut: timedOut, attention: attention, hasRecordedMutation: recordedMutation)
    }
}
