// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

/// Every charge-limit error and status line that can reach the UI is a catalog key with a Russian value, including the
/// bridge's own failure texts and PowerCore's PolicyError (never "PolicyError error 3").
@MainActor final class NativeChargeLocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func russian() throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var result: [String: String] = [:]
        for (key, entry) in strings {
            if let value = (((entry["localizations"] as? [String: Any])?["ru"] as? [String: Any])?["stringUnit"] as? [String: String])?["value"] {
                result[key] = value
            }
        }
        return result
    }

    func testEveryChargeErrorAndStatusLineHasRussian() throws {
        let ru = try russian()
        var keys: [String] = [
            NativeChargeService.registryConflictMessage, NativeChargeService.policyUnconfirmedMessage,
            "macOS has not confirmed the last change yet.", "Wait until macOS confirms the last charge-limit change.",
            "The charge limit has not been read yet.", "Choose a level above your charge limit.", "Choose a later time.",
            "Controls are paused for sleep or an update.", "A charge-limit change is still in progress.",
            "macOS has not reported the charge limit yet.", "Use System Settings › Battery to change this limit.",
            "Charge limit change not confirmed", "Read from macOS; change it in System Settings › Battery.",
            "The native policy read timed out. Further actions wait for the read to return.",
            "The native setting operation timed out. Its outcome needs review; further writes are blocked.",
            "Set at once, as in System Settings.", "The limit is not available right now.",
            "The native session journal needs review before further changes.", NativeChargeStatusText.partialReadWarning,
        ]
        keys += [NativeChargePresentation.Attention.none, .mutationUnresolved, .journalIntegrity, .operationPending, .policyUnconfirmed].map(\.titleKey)
        keys += ChargeLimitKit.infoParagraphKeys + DiagnosticsChargeRows.infoKeys
        let errors: [NativeChargeServiceError] = [.unavailable, .busy, .unsupportedTarget, .unqualifiedTarget, .readbackMismatch, .changedElsewhere]
        keys += errors.map(\.localizedDescription)
        let policy: [PolicyError] = [.invalidContract, .unsupportedTarget, .staleGeneration, .readbackMismatch, .unavailable, .invalidPolicy]
        keys += policy.map(\.localizedDescription)
        keys.append(try XCTUnwrap(NativeChargeReadFailure(supportedTargets: [80, 85, 90, 95, 100])).localizedDescription)
        for key in keys { XCTAssertNotNil(ru[key], key) }
        XCTAssertEqual(PolicyError.readbackMismatch.localizedDescription, "macOS has not independently confirmed the requested charge setting.")
        XCTAssertFalse(PolicyError.unavailable.localizedDescription.contains("PolicyError"))
    }

    /// The bridge's failure texts (TVFail and the incomplete-readback description) reach the UI as the error message.
    func testEveryBridgeFailureTextHasRussian() throws {
        let ru = try russian()
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/PowerUIBridge/PowerUIBridge.m"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"(?:TVFail\(error,\d+,|NSLocalizedDescriptionKey:)@"([^"]+)""#)
        let literals = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertGreaterThanOrEqual(Set(literals).count, 10)
        for literal in Set(literals) { XCTAssertNotNil(ru[literal], literal) }
    }

    /// A pmset answer started before a write must not be recorded (and shared) after the write invalidated the cache.
    func testAQueryStartedBeforeAnInvalidationIsNotRecorded() {
        let readings = BatteryLimitReadings()
        let before = readings.generation
        readings.invalidate()   // a native write lands while the query runs
        readings.record("No battery level limits set", ifGeneration: before)
        XCTAssertNil(readings.recent(maximumAge: 5))
        readings.record("No battery level limits set", ifGeneration: readings.generation)
        XCTAssertNotNil(readings.recent(maximumAge: 5))
    }
}
