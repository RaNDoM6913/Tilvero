// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest

/// The helper every preference suite in these tests goes through.
final class TestDefaultsTests: XCTestCase {
    func testSuitesArePrefixedAndRemovalDeletesDomainAndFile() async throws {
        let (name, defaults) = TestDefaults.make("SelfTest")
        XCTAssertTrue(name.hasPrefix("TilveroTests-SelfTest-"))
        XCTAssertTrue(TestDefaults.name().hasPrefix(TestDefaults.prefix))
        defaults.set(42, forKey: "answer")
        CFPreferencesAppSynchronize(name as CFString)
        let file = TestDefaults.plistURL(name)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The suite reached disk, so its removal is observable")
        TestDefaults.remove(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "The plist goes with the domain")
        XCTAssertNil(UserDefaults(suiteName: name)?.object(forKey: "answer"))
        XCTAssertTrue(UserDefaults(suiteName: name)?.persistentDomain(forName: name)?.isEmpty ?? true)
        TestDefaults.remove(name)   // idempotent
    }

    func testMakeTestDefaultsRemovesItsSuiteWhenTheTestEnds() {
        final class Name: @unchecked Sendable { var value = "" }
        let name = Name()
        // Teardown blocks run last-in, first-out: this check runs after makeTestDefaults' removal below.
        addTeardownBlock {
            XCTAssertNil(UserDefaults(suiteName: name.value)?.object(forKey: "flag"), "The domain is gone after the test")
            XCTAssertFalse(FileManager.default.fileExists(atPath: TestDefaults.plistURL(name.value).path), "And so is its file")
        }
        let suite = makeTestDefaults("SelfTestTeardown")
        name.value = suite.name
        suite.defaults.set(true, forKey: "flag")
        CFPreferencesAppSynchronize(suite.name as CFString)
        XCTAssertTrue(suite.defaults.bool(forKey: "flag"))
    }
}
