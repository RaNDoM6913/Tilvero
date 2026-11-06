import Foundation

enum UpdateChannel: String, CaseIterable, Codable, Sendable { case stable, beta }
enum UpdateBuildProfile: String, Codable, Sendable { case development, lab, trial, monitoring, manual }

/// Information from the running bundle, independent of release packaging configuration.
/// Installer profile eligibility here is not evidence of signing or update trust.
struct UpdateIdentity: Equatable, Codable, Sendable {
    let version: String?
    let build: String?
    let bundleIdentifier: String?
    let profile: UpdateBuildProfile
    let defaultChannel: UpdateChannel

    init(info: [String: Any], bundleIdentifier: String? = nil) {
        version = Self.nonempty(info["CFBundleShortVersionString"] as? String)
        build = Self.nonempty(info["CFBundleVersion"] as? String)
        self.bundleIdentifier = Self.nonempty(bundleIdentifier ?? info["CFBundleIdentifier"] as? String)
        switch self.bundleIdentifier {
        case "local.tilvero.prototype": profile = .development
        case "local.tilvero.lab": profile = .lab
        case "local.tilvero.lidtrial": profile = .trial
        case "io.github.random6913.tilvero" where info["TilveroReleaseMode"] as? String == "monitoring"
            && info["TilveroDataScope"] as? String == "production": profile = .monitoring
        default: profile = .manual
        }
        defaultChannel = (info["TilveroReleaseChannel"] as? String).flatMap(UpdateChannel.init(rawValue:))
            ?? ([.development, .lab, .trial].contains(profile) ? .beta : .stable)
    }

    static func current(bundle: Bundle = .main) -> Self {
        Self(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
    }

    var supportsInstallerProfile: Bool {
        profile == .monitoring && version != nil && build.flatMap { Self.compareBuilds($0, $0) } != nil
    }

    /// Positive decimal machine builds are compared without integer overflow or lexical ordering.
    static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard validBuild(lhs), validBuild(rhs) else { return nil }
        if lhs.count != rhs.count { return lhs.count > rhs.count ? .orderedDescending : .orderedAscending }
        if lhs == rhs { return .orderedSame }
        return lhs > rhs ? .orderedDescending : .orderedAscending
    }

    static func validBuild(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.first.map { ("1"..."9").contains(String($0)) } == true
            && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func nonempty(_ string: String?) -> String? {
        guard let string, !string.isEmpty, string.utf8.count <= 256 else { return nil }
        return string
    }
}
