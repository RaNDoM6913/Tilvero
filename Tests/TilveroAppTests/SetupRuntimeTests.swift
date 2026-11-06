import XCTest
import PowerPrivileged
@testable import TilveroApp

@MainActor final class SetupRuntimeTests: XCTestCase {
    func testSetupReadAndReviewHaveNoActionAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let coordinator = model.setupCoordinator
        XCTAssertEqual(fixture.statusReads, 0)
        XCTAssertTrue(model.canShowSetup)
        XCTAssertFalse(model.hasReviewedSetup)

        let readiness = await coordinator.refresh()
        XCTAssertEqual(readiness.item(for: .launchAtLogin).status, .optional)
        XCTAssertEqual(fixture.statusReads, 1)
        model.markSetupReviewed()
        XCTAssertTrue(model.hasReviewedSetup)
        XCTAssertTrue(fixture.model().hasReviewedSetup)
        XCTAssertEqual(fixture.effects, [])

        fixture.login = .requiresApproval
        let result = await coordinator.perform(.enableLogin)
        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertTrue(result.readiness.inputs.hasReviewedSetup)
        XCTAssertEqual(result.readiness.item(for: .launchAtLogin).status, .needsOSApproval)
        XCTAssertEqual(fixture.effects, [])
    }

    func testEnableLoginAndHistoryUseExplicitStateAndApprovalIsSeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let coordinator = model.setupCoordinator
        let enabled = await coordinator.perform(.enableLogin)
        let repeated = await coordinator.perform(.enableLogin)
        XCTAssertEqual(enabled.outcome, .performed)
        XCTAssertEqual(enabled.readiness.inputs.login, .enabled)
        XCTAssertEqual(repeated.outcome, .alreadySatisfied)
        XCTAssertEqual(fixture.effects, ["register"])

        let history = await coordinator.perform(.setHistoryEnabled(false))
        XCTAssertEqual(history.outcome, .performed)
        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(fixture.effects, ["register"])

        fixture.login = .requiresApproval
        let approval = await coordinator.perform(.openApprovalSettings(.launchAtLogin))
        XCTAssertEqual(approval.outcome, .performed)
        XCTAssertEqual(approval.readiness.inputs.login, .requiresApproval)
        XCTAssertEqual(fixture.effects, ["register", "approval"])
    }

    func testPortRechecksStatusAtRegistrationBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.login = .enabled
        try fixture.loginPort.enable()
        XCTAssertEqual(fixture.effects, [])
        fixture.login = .requiresApproval
        XCTAssertThrowsError(try fixture.loginPort.enable())
        XCTAssertEqual(fixture.effects, [])
    }

    func testLabAndDemoDoNotDispatchEffectsEvenWithSuppliedPorts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let lab = try fixture.bundle(identifier: ReleaseIdentity.laboratoryBundleIdentifier, scope: "laboratory")
        for model in [fixture.model(bundle: lab), fixture.model(demo: true)] {
            XCTAssertFalse(model.canShowSetup)
            let login = await model.setupCoordinator.perform(.enableLogin)
            XCTAssertEqual(login.outcome, .unavailable)
            model.markSetupReviewed()
            XCTAssertFalse(model.hasReviewedSetup)
        }
        XCTAssertEqual(fixture.statusReads, 0)
        XCTAssertEqual(fixture.effects, [])
    }

    func testNativeQualificationAndUntrustedHelperCannotBeStartedFromSetup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let coordinator = model.setupCoordinator
        let validation = await coordinator.perform(.requestValidation(.nativeCharging))
        let enrollment = await coordinator.perform(.registerHelper)
        XCTAssertEqual(validation.outcome, .unavailable)
        XCTAssertEqual(enrollment.outcome, .unavailable)
        XCTAssertEqual(enrollment.readiness.item(for: .fans).reason, .signedBuildRequired)
        model.openDetails = { fixture.effects.append("open details") }
        let navigation = await coordinator.perform(.viewRequirements(.nativeCharging))
        XCTAssertEqual(navigation.outcome, .performed)
        XCTAssertEqual(model.selectedSection, .charging)
        XCTAssertEqual(fixture.effects, [])
    }

    private final class Fixture: LiveHelperRegistrationDriving {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroSetup-\(UUID())")
        let suite = "TilveroSetup-\(UUID())"
        lazy var preferences = UserDefaults(suiteName: suite)!
        let appBundle: Bundle
        var login: SetupRegistrationState = .notRegistered
        var statusReads = 0
        var effects: [String] = []

        init() throws {
            appBundle = try Self.makeBundle(at: root.appendingPathComponent("prototype.bundle"),
                                            identifier: ReleaseIdentity.prototypeBundleIdentifier, scope: "prototype")
        }

        var state: HelperInstallationState { .notRegistered }
        func register() async throws { effects.append("helper") }
        func unregister(afterVerifiedRestoration: Bool) async throws { effects.append("remove helper") }

        var loginPort: SetupLoginPort {
            SetupLoginPort(readStatus: { self.statusReads += 1; return self.login },
                register: { self.effects.append("register"); self.login = .enabled },
                openApprovalSettings: { self.effects.append("approval") })
        }

        func model(bundle: Bundle? = nil, demo: Bool = false) -> TilveroModel {
            let helper = LiveControlService(preferences: preferences, trustVerified: false, registration: self,
                makeTransport: { throw LiveControlError.unavailable }, discovery: { LiveControlDiscovery(capabilities: []) })
            return TilveroModel(isDemo: demo, launchPolicy: .resolve(metadata: [:]), preferences: preferences,
                historyURL: root.appendingPathComponent("History.sqlite"), liveControl: helper,
                sideEffects: .init(loginStatus: { "Fixture" }, toggleLogin: { self.effects.append("toggle") },
                    openBatterySettings: {}, rawCatalog: { [] }, setupLogin: loginPort), setupBundle: bundle ?? appBundle)
        }

        func cleanUp() {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func bundle(identifier: String, scope: String) throws -> Bundle {
            try Self.makeBundle(at: root.appendingPathComponent(scope + ".bundle"), identifier: identifier, scope: scope)
        }

        private static func makeBundle(at url: URL, identifier: String, scope: String) throws -> Bundle {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                "CFBundlePackageType": "BNDL", "TilveroDataScope": scope], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: url))
        }
    }
}
