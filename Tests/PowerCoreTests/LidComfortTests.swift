// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import PowerCore

final class LidComfortTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Cap policy

    func testCapLowersLouderValue() {
        XCTAssertEqual(LidComfortPolicy.capTarget(current: 0.5, level: 0.25), 0.25)
    }
    func testCapDoesNotRaiseQuieterValue() {
        XCTAssertNil(LidComfortPolicy.capTarget(current: 0.13, level: 0.25))
    }
    func testCapWritesNothingWithinTolerance() {
        XCTAssertNil(LidComfortPolicy.capTarget(current: 0.255, level: 0.25))
    }
    func testLevelZeroWritesZero() {
        XCTAssertEqual(LidComfortPolicy.capTarget(current: 0.6, level: 0), 0)
        XCTAssertNil(LidComfortPolicy.capTarget(current: 0, level: 0))
    }
    func testCapIgnoresNonFiniteInput() {
        XCTAssertNil(LidComfortPolicy.capTarget(current: .nan, level: 0.25))
        XCTAssertNil(LidComfortPolicy.capTarget(current: 0.5, level: .infinity))
    }
    func testLevelIsClampedToUnitRange() {
        XCTAssertEqual(LidComfortPolicy.capTarget(current: 0.9, level: -1), 0)
        XCTAssertNil(LidComfortPolicy.capTarget(current: 0.9, level: 7))
    }

    // MARK: Settings

    func testDefaultsMatchTheOwnerDecision() {
        let defaults = LidComfortSettings.default
        XCTAssertTrue(defaults.dimDisplay); XCTAssertEqual(defaults.displayLevel, 0)
        XCTAssertTrue(defaults.limitVolume); XCTAssertEqual(defaults.volumeLevel, 0.25)
        XCTAssertTrue(defaults.isActive)
    }
    func testSettingsAreInactiveWhenBothSwitchesAreOff() {
        var settings = LidComfortSettings.default
        settings.dimDisplay = false; settings.limitVolume = false
        XCTAssertFalse(settings.isActive)
    }
    func testSettingsSanitizeNonFiniteAndOutOfRangeLevels() {
        let sanitized = LidComfortSettings(dimDisplay: true, displayLevel: .nan, limitVolume: true, volumeLevel: 4).sanitized
        XCTAssertEqual(sanitized.displayLevel, 0); XCTAssertEqual(sanitized.volumeLevel, 1)
    }

    // MARK: Restore decisions

    private func entry(_ phase: LidComfortEntry.Phase = .applied, original: Double = 0.5, written: Double = 0.25,
                       age: TimeInterval = 10) -> LidComfortEntry {
        LidComfortEntry(target: .volume(deviceUID: "speakers"), original: original, written: written, phase: phase,
                        createdAt: now.addingTimeInterval(-age))
    }
    func testRestoreWritesOriginalWhenValueIsStillOurs() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(), current: 0.25, now: now), .write(0.5))
    }
    func testRestoreToleratesDeviceQuantization() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(), current: 0.2500002, now: now), .write(0.5))
    }
    func testRestoreSkipsWhenUserChangedValue() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(), current: 0.8, now: now), .clear)
    }
    func testRestoreClearsWhenAlreadyOriginal() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(), current: 0.5, now: now), .clear)
    }
    func testIntentThatNeverLandedClearsWithoutWriting() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(.intent), current: 0.5, now: now), .clear)
    }
    func testIntentThatLandedIsRestored() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(.intent), current: 0.25, now: now), .write(0.5))
    }
    func testRestoreKeepsEntryWhenTargetIsMissing() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(), current: nil, now: now), .keep)
    }
    func testStaleEntryIsDroppedAfter24Hours() {
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(age: 25 * 3600), current: nil, now: now), .clear)
        XCTAssertEqual(LidComfortPolicy.restoreDecision(for: entry(age: 23 * 3600), current: nil, now: now), .keep)
    }

    // MARK: Journal

    func testJournalRoundTrip() throws {
        let journal = LidComfortJournal(mode: .scheduledSleep, entries: [
            LidComfortEntry(target: .display(id: 1), original: 0.57, written: 0, phase: .applied, createdAt: now),
            entry()
        ], createdAt: now)
        let decoded = LidComfortJournal.decode(try journal.encoded())
        XCTAssertEqual(decoded, journal)
    }
    func testJournalRejectsUnknownVersionAndGarbage() throws {
        var journal = LidComfortJournal(mode: .keepAwake, entries: [entry()], createdAt: now)
        journal.version = 2
        XCTAssertNil(LidComfortJournal.decode(try journal.encoded()))
        XCTAssertNil(LidComfortJournal.decode(Data("nope".utf8)))
    }
    func testJournalRejectsNonFiniteValues() throws {
        let bad = LidComfortJournal(mode: .keepAwake, entries: [
            LidComfortEntry(target: .display(id: 1), original: .nan, written: 0, phase: .applied, createdAt: now)], createdAt: now)
        XCTAssertNil(LidComfortJournal.decode(try bad.encoded()))
    }
}
