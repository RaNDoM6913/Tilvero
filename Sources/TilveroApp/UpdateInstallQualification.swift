// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Security

struct UpdateInstallConfiguration: Equatable {
    static let productionBundleID = "io.github.random6913.tilvero"
    let enabled: Bool
    let teamID: String
    let feedURL: URL?
    let publicKey: String

    init(info: [String: Any]) {
        let config = info["TilveroUpdaterConfiguration"] as? [String: Any] ?? [:]
        enabled = config["enabled"] as? Bool == true
        teamID = config["teamID"] as? String ?? ""
        feedURL = (config["feedURL"] as? String).flatMap(URL.init(string:))
        publicKey = config["publicKey"] as? String ?? ""
    }

    var blockers: [String] {
        var reasons: [String] = []
        if !enabled { reasons.append("updates.install.notConfigured") }
        if teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil { reasons.append("updates.install.missingTeam") }
        if !Self.isHTTPS(feedURL) { reasons.append("updates.install.missingFeed") }
        if Data(base64Encoded: publicKey)?.count != 32 { reasons.append("updates.install.missingKey") }
        return reasons
    }

    static func isHTTPS(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
}

struct UpdateInstallHostFacts {
    var bundleID: String?
    var dataScope: String?
    var profile: String?
    var build: String?
    var helperFree: Bool
    var signatureValid: Bool
    var signedTeamID: String?
    var policyFlagsValid: Bool

    func blockers(configuration: UpdateInstallConfiguration) -> [String] {
        var reasons = configuration.blockers
        if bundleID != UpdateInstallConfiguration.productionBundleID { reasons.append("updates.install.manualIdentity") }
        if dataScope != "production" || profile != "monitoring" || !helperFree { reasons.append("updates.install.manualProfile") }
        if build.flatMap(UInt64.init) == nil { reasons.append("updates.install.invalidBuild") }
        if !signatureValid || signedTeamID != configuration.teamID { reasons.append("updates.install.untrustedSignature") }
        if !policyFlagsValid { reasons.append("updates.install.unsafeConfiguration") }
        return reasons
    }

    static func inspect(bundle: Bundle, configuration: UpdateInstallConfiguration) -> Self {
        let info = bundle.infoDictionary ?? [:]
        let library = bundle.bundleURL.appendingPathComponent("Contents/Library")
        let helperFree = ["HelperTools", "LaunchDaemons"].allSatisfy {
            let path = library.appendingPathComponent($0)
            if !FileManager.default.fileExists(atPath: path.path) { return true }
            return (try? FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty) == true
        }
        var code: SecStaticCode?
        var signedInfo: CFDictionary?
        let found = SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess
        var requirement: SecRequirement?
        // Developer ID Application, not an ad-hoc or merely development signature.
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(UpdateInstallConfiguration.productionBundleID)\""
        let requirementOK = SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let valid = found && requirementOK && code.map { SecStaticCodeCheckValidity($0, validationFlags, requirement) == errSecSuccess } == true
        if let code { SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signedInfo) }
        let signing = signedInfo as? [String: Any]
        let flags = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUEnableJavaScript"].allSatisfy { info[$0] as? Bool == false }
            && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true
            && info["SURequireSignedFeed"] as? Bool == true
            && info["SUSignedFeedFailureExpirationInterval"] as? Int == 0
            && info["SUFeedURL"] as? String == configuration.feedURL?.absoluteString
            && info["SUPublicEDKey"] as? String == configuration.publicKey
        return Self(bundleID: bundle.bundleIdentifier, dataScope: info["TilveroDataScope"] as? String,
                    profile: info["TilveroReleaseMode"] as? String, build: info["CFBundleVersion"] as? String,
                    helperFree: helperFree, signatureValid: valid,
                    signedTeamID: signing?[kSecCodeInfoTeamIdentifier as String] as? String, policyFlagsValid: flags)
    }
}

struct UpdateInstallCandidate {
    var build: String
    var bundleID: String?
    var profile: String?
    var teamID: String?
    var architecture: String?
    var url: URL?
    var edSignature: String?
    var installationType: String
    var informationOnly: Bool

    func isAdmitted(currentBuild: String, configuration: UpdateInstallConfiguration) -> Bool {
        guard let current = UInt64(currentBuild), let next = UInt64(build), next > current,
              bundleID == UpdateInstallConfiguration.productionBundleID, profile == "monitoring",
              teamID == configuration.teamID, architecture == "arm64", !informationOnly,
              UpdateInstallConfiguration.isHTTPS(url), installationType == "application",
              Data(base64Encoded: edSignature ?? "")?.count == 64 else { return false }
        // Source ZIPs and arbitrary archives can never be promoted by their extension.
        return url?.pathExtension.lowercased() == "dmg"
    }
}
