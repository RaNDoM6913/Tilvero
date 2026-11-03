import XCTest
@testable import TilveroApp

final class UpdateInstallQualificationTests: XCTestCase {
    private var config: UpdateInstallConfiguration {
        .init(info: ["TilveroUpdaterConfiguration": ["enabled": true, "teamID": "ABCD123456", "feedURL": "https://updates.example.org/monitoring/appcast.xml", "publicKey": Data(repeating: 1, count: 32).base64EncodedString()]])
    }
    private var host: UpdateInstallHostFacts {
        .init(bundleID: UpdateInstallConfiguration.productionBundleID, dataScope: "production", profile: "monitoring", build: "3", helperFree: true, signatureValid: true, signedTeamID: "ABCD123456", policyFlagsValid: true)
    }
    private var candidate: UpdateInstallCandidate {
        .init(build: "4", bundleID: UpdateInstallConfiguration.productionBundleID, profile: "monitoring", teamID: "ABCD123456", architecture: "arm64", url: URL(string: "https://downloads.example.org/Tilvero-4.dmg"), edSignature: Data(repeating: 1, count: 64).base64EncodedString(), installationType: "application", informationOnly: false)
    }
    func testExactProductionMonitoringHostOnly() {
        XCTAssertTrue(host.blockers(configuration: config).isEmpty)
        for id in ["local.tilvero.prototype", "io.github.random6913.tilvero.lab", "io.github.random6913.tilvero.lidtrial"] {
            var wrong = host; wrong.bundleID = id
            XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
        }
        for profile in ["development", "controller", "lid-trial", "Monitoring"] {
            var wrong = host; wrong.profile = profile
            XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
        }
        var helper = host; helper.helperFree = false; XCTAssertFalse(helper.blockers(configuration: config).isEmpty)
    }
    func testMissingTrustAndUnsafePreferencesNeverQualify() {
        XCTAssertFalse(host.blockers(configuration: .init(info: [:])).isEmpty)
        var wrong = host; wrong.signatureValid = false; XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
        wrong = host; wrong.signedTeamID = "OTHER12345"; XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
        wrong = host; wrong.policyFlagsValid = false; XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
        wrong = host; wrong.build = "unknown"; XCTAssertFalse(wrong.blockers(configuration: config).isEmpty)
    }
    func testSignedFeedCandidateMustBeNewerExactProfileAndAppArtifact() {
        XCTAssertTrue(candidate.isAdmitted(currentBuild: "3", configuration: config))
        for build in ["1", "3", "unknown", "18446744073709551616", "4.0"] {
            var wrong = candidate; wrong.build = build
            XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        }
        var wrong = candidate; wrong.profile = "controller"; XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        wrong = candidate; wrong.teamID = "OTHER12345"; XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        wrong = candidate; wrong.edSignature = nil; XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        wrong = candidate; wrong.informationOnly = true; XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        wrong = candidate; wrong.installationType = "package"; XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        for url in ["https://github.com/RaNDoM6913/Tilvero/archive/refs/tags/v4.zip", "http://downloads.example.org/app.dmg", "https://user:secret@downloads.example.org/app.dmg"] {
            wrong = candidate; wrong.url = URL(string: url)
            XCTAssertFalse(wrong.isAdmitted(currentBuild: "3", configuration: config))
        }
    }
    func testActualUnitTestHostCannotAcquireProductionQualification() {
        let configuration = UpdateInstallConfiguration(info: Bundle.main.infoDictionary ?? [:])
        XCTAssertFalse(UpdateInstallHostFacts.inspect(bundle: .main, configuration: configuration).blockers(configuration: configuration).isEmpty)
    }
}
