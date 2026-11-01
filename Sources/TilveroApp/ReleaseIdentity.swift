import Foundation

/// Bundle metadata owns the data boundary; a new bundle ID never reuses the prototype store.
struct ReleaseIdentity {
    static let prototypeBundleIdentifier = "local.tilvero.prototype"
    static let laboratoryBundleIdentifier = "local.tilvero.lab"
    let bundleIdentifier: String
    let isProduction: Bool
    let isLaboratory: Bool

    enum MetadataError: Error { case invalidIdentity }

    init(metadata: [String: Any]) throws {
        // SwiftPM command-line development executables have no app bundle metadata.
        let identifier = metadata["CFBundleIdentifier"] as? String ?? Self.prototypeBundleIdentifier
        guard !identifier.isEmpty else { throw MetadataError.invalidIdentity }
        let scope = metadata["TilveroDataScope"] as? String
        isLaboratory = identifier == Self.laboratoryBundleIdentifier
        if identifier == Self.prototypeBundleIdentifier {
            guard scope == nil || scope == "prototype" else { throw MetadataError.invalidIdentity }
            isProduction = false
        } else if isLaboratory {
            guard scope == "laboratory" else { throw MetadataError.invalidIdentity }
            isProduction = false
        } else {
            guard scope == "production" else { throw MetadataError.invalidIdentity }
            isProduction = true
        }
        bundleIdentifier = identifier
    }

    var reopenNotificationName: Notification.Name {
        Notification.Name(isProduction || isLaboratory ? "\(bundleIdentifier).showDetails" : "local.tilvero.showDetails")
    }

    static func current(bundle: Bundle = .main) throws -> ReleaseIdentity {
        try ReleaseIdentity(metadata: bundle.infoDictionary ?? [:])
    }

    func historyURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(isLaboratory ? "Tilvero/Laboratory/History.sqlite" : isProduction ? "Tilvero/Production/History.sqlite" : "Tilvero/History.sqlite")
    }

    func historyURL() -> URL {
        historyURL(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
}
