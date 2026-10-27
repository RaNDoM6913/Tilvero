import Foundation
import Security
import ServiceManagement
import SystemConfiguration
import Darwin
import PowerCore

public struct HelperTrustConfiguration: Sendable {
    public let teamID: String
    public let appIdentifier: String
    public let helperIdentifier: String
    public let appRequirement: String
    public let helperRequirement: String
    public init(teamID: String, appIdentifier: String, helperIdentifier: String) throws {
        guard teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
              appIdentifier != helperIdentifier,
              [appIdentifier, helperIdentifier].allSatisfy({ $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{2,180}$"#, options: .regularExpression) != nil }) else { throw PrivilegeError.missingTrust }
        self.teamID = teamID; self.appIdentifier = appIdentifier; self.helperIdentifier = helperIdentifier
        func requirement(_ identifier: String) throws -> String {
            let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
            var parsed: SecRequirement?
            guard SecRequirementCreateWithString(expression as CFString, [], &parsed) == errSecSuccess, parsed != nil else { throw PrivilegeError.missingTrust }
            return expression
        }
        appRequirement = try requirement(appIdentifier); helperRequirement = try requirement(helperIdentifier)
    }
    public static func fromBundle(_ bundle: Bundle = .main) throws -> Self {
        guard let team = bundle.object(forInfoDictionaryKey: "TilveroTeamIdentifier") as? String,
              let app = bundle.object(forInfoDictionaryKey: "TilveroAppIdentifier") as? String,
              let helper = bundle.object(forInfoDictionaryKey: "TilveroHelperIdentifier") as? String else { throw PrivilegeError.missingTrust }
        return try Self(teamID: team, appIdentifier: app, helperIdentifier: helper)
    }
    public func verifyCurrentProcess(helper: Bool) throws {
        var ownCode: SecCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecRequirementCreateWithString((helper ? helperRequirement : appRequirement) as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(ownCode, [], requirement) == errSecSuccess else { throw PrivilegeError.missingTrust }
    }
}

public enum HelperInstallationState: String, Sendable { case notRegistered, enabled, requiresApproval, notFound, unavailable }
@MainActor public final class HelperRegistration {
    private let service: SMAppService
    private let guardian: SMAppService
    public init(plistName: String = "local.tilvero.helper.plist", guardianPlistName: String = "local.tilvero.guardian.plist") {
        service = .daemon(plistName: plistName); guardian = .daemon(plistName: guardianPlistName)
    }
    public var state: HelperInstallationState {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: guardian.status == .enabled ? .enabled : (guardian.status == .requiresApproval ? .requiresApproval : .unavailable)
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }
    public func register(trust: HelperTrustConfiguration) async throws {
        try trust.verifyCurrentProcess(helper: false)
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        guard path.hasPrefix("/Applications/"), path.hasSuffix(".app") else { throw ControlUnavailableError(reason: "Install the trusted signed app in Applications before enabling supported control.") }
        try guardian.register()
        do { try service.register() } catch { try? await guardian.unregister(); throw error }
    }
    public func unregister(afterVerifiedRestoration verified: Bool) async throws {
        guard verified else { throw PrivilegeError.recoveryRequired }
        try await service.unregister()
        try await guardian.unregister()
    }
    public func openSystemApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

public enum HelperClock {
    public static func continuousSeconds() -> Double {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    public static func bootID() -> String {
        var boot = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "unavailable" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }
    public static func activeConsoleUserID() -> UInt32? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid), user as String != "loginwindow", uid >= 500 else { return nil }
        return uid
    }
}
