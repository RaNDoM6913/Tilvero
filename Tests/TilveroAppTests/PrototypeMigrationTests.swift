import XCTest
import Foundation
import PowerCore
import PowerTelemetry
import PowerPersistence
@testable import TilveroApp

@MainActor final class PrototypeMigrationTests: XCTestCase {
    private let salt = "5DDA446B-1515-42C4-823F-4FC532F3A8D1"

    func testPairedMigrationPrecedesFirstReadingAndPreservesIdentityHistoryAndSource() throws {
        let f = try Fixture(); defer { f.clean() }
        let provider = MacBatteryProvider(identitySalt: salt)
        let snapshot = provider.normalize(powerSource: [:], registry: ["Serial": "ISOLATED_FIXTURE"])
        let source = try BatteryHistoryStore(url: f.source)
        try source.record(snapshot); try source.close()
        let original = try Data(contentsOf: f.source)
        let result = try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt, "language": "ru"]))
        guard case .migrated(let receipt) = result else { return XCTFail("Expected paired import") }
        XCTAssertTrue(receipt.importedHistory)
        XCTAssertEqual(f.destination.string(forKey: "identitySalt"), salt)
        XCTAssertEqual(f.destination.string(forKey: "language"), "ru")
        XCTAssertEqual(try Data(contentsOf: f.source), original)
        let imported = try BatteryHistoryStore(url: f.target)
        XCTAssertEqual(try imported.samples().count, 1)
        let next = MacBatteryProvider(identitySalt: try XCTUnwrap(f.destination.string(forKey: "identitySalt")))
            .normalize(powerSource: [:], registry: ["Serial": "ISOLATED_FIXTURE"])
        XCTAssertEqual(next.batteryIdentityToken, snapshot.batteryIdentityToken)
        try imported.record(next)
        XCTAssertFalse(try imported.summary().gaps.contains { $0.reason == .batteryReplacement })
        try imported.close()
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .notNeeded)
    }

    func testDestinationPreferencesWinAndControlAuthorityAndSimulationNeverMigrate() throws {
        let f = try Fixture(); defer { f.clean() }
        f.destination.set("en", forKey: "language")
        let source: [String: Any] = ["identitySalt": salt, "language": "ru", "fahrenheit": true,
            "historyEnabled": false, "retentionDays": 14, "menuBarTextSize": "larger", "menuBarIconScale": 0.95,
            "menuBarDisplayStyle": "inside", "lastSection": "overview", "schedule": Data([1]), "arbiter": Data([2]),
            "liveRequestedChargeIntent": Data([3]), "livePriorOneShotChargeIntent": Data([4]), "simulationState": Data([5]),
            "demoSchedule": Data([6]), "helperAuthority": "never", "password": "never"]
        _ = try PrototypeMigration.prepare(environment: f.environment(source: source))
        XCTAssertEqual(f.destination.string(forKey: "language"), "en")
        XCTAssertEqual(f.destination.object(forKey: "fahrenheit") as? Bool, true)
        XCTAssertEqual(f.destination.integer(forKey: "retentionDays"), 14)
        for key in ["schedule", "arbiter", "liveRequestedChargeIntent", "livePriorOneShotChargeIntent", "simulationState", "demoSchedule", "helperAuthority", "password"] {
            XCTAssertNil(f.destination.object(forKey: key), key)
        }
    }

    func testEqualSaltAllowsHistoryButConflictAndInvalidLegacySaltBlockWithoutMutation() throws {
        for legacy in [salt, "", "invalid", "A09090DD-8CA1-410C-8514-C5AE60EE56F7"] {
            let f = try Fixture(); defer { f.clean() }
            try f.makeHistory()
            f.destination.set(salt, forKey: "identitySalt")
            let result = try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": legacy, "language": "ru"]))
            if legacy == salt {
                guard case .migrated = result else { return XCTFail("Equal salt must permit import") }
            } else {
                XCTAssertEqual(result, .conflictingIdentity)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
                XCTAssertEqual(f.destination.string(forKey: "identitySalt"), salt)
                XCTAssertNil(f.destination.object(forKey: "language"))
            }
        }
        let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: [:])), .conflictingIdentity)
        XCTAssertNil(f.destination.object(forKey: "identitySalt"))
    }

    func testExistingProductionStoreIsNeverReplacedOrPairedWithLegacySalt() throws {
        let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
        let production = try BatteryHistoryStore(url: f.target)
        try production.record(BatterySnapshot(chargePercent: .init(value: 42, source: "isolated fixture")))
        try production.close()
        let original = try Data(contentsOf: f.target)
        let destinationSalt = "A09090DD-8CA1-410C-8514-C5AE60EE56F7"
        f.destination.set(destinationSalt, forKey: "identitySalt")
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .notNeeded)
        XCTAssertEqual(try Data(contentsOf: f.target), original)
        XCTAssertEqual(f.destination.string(forKey: "identitySalt"), destinationSalt)
    }

    func testRunningPrototypeBlocksBeforeAnyDestinationStateIsCreated() throws {
        let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt], running: true)), .needsPrototypeQuit)
        XCTAssertNil(f.destination.object(forKey: "identitySalt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.deletingLastPathComponent().path))
    }

    func testInterruptionsRecoverBeforeModelUseAndDoNotTouchSource() throws {
        for step in PrototypeMigration.Checkpoint.allCases {
            let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
            let original = try Data(contentsOf: f.source)
            var environment = f.environment(source: ["identitySalt": salt])
            environment.onCheckpoint = { if $0 == step { throw Fixture.Interrupted.expected } }
            XCTAssertThrowsError(try PrototypeMigration.prepare(environment: environment), "\(step)")
            let recovered = try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt]))
            guard case .migrated = recovered else { return XCTFail("Recovery must complete at \(step)") }
            XCTAssertEqual(f.destination.string(forKey: "identitySalt"), salt)
            XCTAssertEqual(try Data(contentsOf: f.source), original)
            let store = try BatteryHistoryStore(url: f.target)
            XCTAssertEqual(try store.samples().first?.chargePercent, 73)
            try store.close()
            XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .notNeeded)
        }
    }

    func testCopyIncludesUncheckpointedWALAndDoesNotMutateSource() throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try BatteryHistoryStore(url: f.source)
        try source.record(BatterySnapshot(chargePercent: .init(value: 61, source: "isolated fixture")))
        let before = try f.storeBytes(at: f.source)
        XCTAssertTrue(before.keys.contains("-wal"))
        try BatteryHistoryStore.copyForPrototypeMigration(from: f.source, to: f.target)
        XCTAssertEqual(try f.storeBytes(at: f.source), before)
        let copied = try BatteryHistoryStore(url: f.target)
        XCTAssertEqual(try copied.samples().first?.chargePercent, 61)
        try copied.close(); try source.close()
    }

    func testFailedCopyAndChangedSaltDuringRecoveryNeverExposePartialImport() throws {
        let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
        let sourceBytes = try f.storeBytes(at: f.source)
        var environment = f.environment(source: ["identitySalt": salt])
        environment.copyStore = { _, _ in throw Fixture.Interrupted.expected }
        XCTAssertThrowsError(try PrototypeMigration.prepare(environment: environment))
        XCTAssertNil(f.destination.object(forKey: "identitySalt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
        XCTAssertEqual(try f.storeBytes(at: f.source), sourceBytes)
        environment = f.environment(source: ["identitySalt": salt])
        environment.onCheckpoint = { if $0 == .storeInstalled { throw Fixture.Interrupted.expected } }
        XCTAssertThrowsError(try PrototypeMigration.prepare(environment: environment))
        f.destination.set("A09090DD-8CA1-410C-8514-C5AE60EE56F7", forKey: "identitySalt")
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .conflictingIdentity)
        XCTAssertEqual(try f.storeBytes(at: f.source), sourceBytes)
    }

    func testMissingImportedStoreOrSaltBlocksInsteadOfStartingFresh() throws {
        for removeStore in [true, false] {
            let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
            _ = try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt]))
            if removeStore { try FileManager.default.removeItem(at: f.target) }
            else { f.destination.removeObject(forKey: "identitySalt") }
            XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .conflictingIdentity)
        }
    }

    func testPresentationOnlyMigrationCreatesDurableFreshIdentityWithoutHistory() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try PrototypeMigration.prepare(environment: f.environment(source: ["language": "ru"]))
        XCTAssertNotNil(f.destination.string(forKey: "identitySalt").flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["language": "ru"])), .notNeeded)
    }

    func testNewStoreDuringPreferenceOnlyRecoveryBlocksBeforeSaltCommit() throws {
        let f = try Fixture(); defer { f.clean() }
        var environment = f.environment(source: ["identitySalt": salt])
        environment.onCheckpoint = { if $0 == .storeStaged { throw Fixture.Interrupted.expected } }
        XCTAssertThrowsError(try PrototypeMigration.prepare(environment: environment))
        let foreign = try BatteryHistoryStore(url: f.target); try foreign.close()
        XCTAssertEqual(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])), .conflictingIdentity)
        XCTAssertNil(f.destination.object(forKey: "identitySalt"))
    }

    func testAliasedSourceAndProductionStoreCannotBecomeSharedWritableHistory() throws {
        for symbolic in [true, false] {
            let f = try Fixture(); defer { f.clean() }; try f.makeHistory()
            try FileManager.default.createDirectory(at: f.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if symbolic { try FileManager.default.createSymbolicLink(at: f.target, withDestinationURL: f.source) }
            else { try FileManager.default.linkItem(at: f.source, to: f.target) }
            let original = try Data(contentsOf: f.source)
            f.destination.set(salt, forKey: "identitySalt")
            XCTAssertThrowsError(try PrototypeMigration.prepare(environment: f.environment(source: ["identitySalt": salt])))
            XCTAssertEqual(try Data(contentsOf: f.source), original)
        }
    }

    func testReleaseIdentityChoosesDistinctStoreAndRejectsUnknownMetadata() throws {
        let root = URL(fileURLWithPath: "/isolated/Application Support")
        let prototype = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.prototype"])
        let production = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "io.github.random6913.tilvero", "TilveroDataScope": "production"])
        XCTAssertEqual(prototype.historyURL(applicationSupport: root).path, "/isolated/Application Support/Tilvero/History.sqlite")
        XCTAssertEqual(production.historyURL(applicationSupport: root).path, "/isolated/Application Support/Tilvero/Production/History.sqlite")
        XCTAssertThrowsError(try ReleaseIdentity(metadata: ["CFBundleIdentifier": "unrecognized.app"]))
        XCTAssertNotEqual(production.reopenNotificationName, prototype.reopenNotificationName)
        XCTAssertEqual(prototype.reopenNotificationName.rawValue, "local.tilvero.showDetails")
    }

    @MainActor private final class Fixture {
        enum Interrupted: Error { case expected }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroMigrationTests-\(UUID())")
        let suite = "TilveroMigrationTests.\(UUID())"
        let destination: UserDefaults
        var source: URL { directory.appendingPathComponent("Prototype/History.sqlite") }
        var target: URL { directory.appendingPathComponent("Production/History.sqlite") }
        init() throws { destination = try XCTUnwrap(UserDefaults(suiteName: suite)) }
        func environment(source: [String: Any], running: Bool = false) -> PrototypeMigration.Environment {
            .init(sourcePreferences: source, destinationPreferences: destination, sourceStore: self.source,
                  destinationStore: target, isPrototypeRunning: { running })
        }
        func makeHistory() throws {
            let store = try BatteryHistoryStore(url: source)
            try store.record(BatterySnapshot(chargePercent: .init(value: 73, source: "isolated fixture")))
            try store.close()
        }
        func storeBytes(at url: URL) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                result[suffix] = try Data(contentsOf: URL(fileURLWithPath: url.path + suffix))
            }
            return result
        }
        func clean() { destination.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }
}
