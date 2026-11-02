import Foundation
import Security
import PowerPrivileged

/// Reuses the existing exact Apple-anchor/Team/identifier validator, with wholly
/// separate bundle metadata and no production coordinator or storage bootstrap.
public struct ClosedLidTrust: Sendable {
    private let configuration: HelperTrustConfiguration
    private let verifyRequirement: @Sendable (String) throws -> Void
    public var teamID: String { configuration.teamID }
    public var appIdentifier: String { configuration.appIdentifier }
    public var helperIdentifier: String { configuration.helperIdentifier }
    public var appRequirement: String { configuration.appRequirement }
    public var helperRequirement: String { configuration.helperRequirement }
    public init(teamID: String, appIdentifier: String, helperIdentifier: String) throws {
        do {
            let configuration = try HelperTrustConfiguration(teamID: teamID, appIdentifier: appIdentifier, helperIdentifier: helperIdentifier)
            self.init(configuration: configuration, verifyRequirement: { requirement in
                // The owning helper validator constructs and checks precisely these requirements.
                try configuration.verifyCurrentProcess(helper: requirement == configuration.helperRequirement)
            })
        } catch { throw ClosedLidFailure.missingTrust }
    }
    init(configuration: HelperTrustConfiguration, verifyRequirement: @escaping @Sendable (String) throws -> Void) {
        self.configuration = configuration; self.verifyRequirement = verifyRequirement
    }
    public static func fromBundle(_ bundle: Bundle = .main) throws -> Self {
        try fromMetadata(bundle.infoDictionary ?? [:])
    }
    static func fromMetadata(_ metadata: [String: Any]) throws -> Self {
        guard let team = metadata["TilveroLidTeamIdentifier"] as? String,
              let app = metadata["TilveroLidAppIdentifier"] as? String,
              let helper = metadata["TilveroLidHelperIdentifier"] as? String else { throw ClosedLidFailure.missingTrust }
        return try Self(teamID: team, appIdentifier: app, helperIdentifier: helper)
    }
    public func verify(helper: Bool) throws {
        do { try verifyRequirement(helper ? helperRequirement : appRequirement) }
        catch { throw ClosedLidFailure.missingTrust }
    }
    static func validateConsolePeer(userID: UInt32, activeUserID: UInt32?) throws {
        guard userID >= 500, userID == activeUserID else { throw ClosedLidFailure.wrongUser }
    }
}
