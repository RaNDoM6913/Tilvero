// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Carbon
import ServiceManagement

/// Facts that tell a brand-new install from an existing user. Read once at launch, before anything is written.
struct FirstRunSignals: Equatable {
    /// `firstRunIntroduced.v1`: the first-run window was shown (or skipped silently) before.
    var introduced = false
    var setupReviewed = false
    /// The user (or an older build) stored a history choice.
    var historyPreferenceStored = false
    var historyStoreExists = false
    var chargeValidationExists = false
    /// `tilvero-lid`, `tilvero-wake` or the merged `tilvero` rule file.
    var ruleFilesExist = false
    var loginItemEnabled = false

    /// Any sign that Tilvero has been used on this Mac before.
    var hasPriorUse: Bool {
        setupReviewed || historyPreferenceStored || historyStoreExists || chargeValidationExists || ruleFilesExist || loginItemEnabled
    }

    static func read(defaults: UserDefaults, historyURL: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                     loginItemEnabled: () -> Bool = { SMAppService.mainApp.status == .enabled }) -> Self {
        let root = historyURL.deletingLastPathComponent()
        return Self(introduced: defaults.bool(forKey: FirstRunDecision.introducedKey),
                    setupReviewed: defaults.bool(forKey: SetupRuntime.reviewedKey),
                    historyPreferenceStored: defaults.object(forKey: "historyEnabled") != nil,
                    historyStoreExists: fileExists(historyURL.path),
                    chargeValidationExists: fileExists(root.appendingPathComponent("native-charge-validation.json").path),
                    ruleFilesExist: SudoersRules.allPaths.contains(where: fileExists),
                    loginItemEnabled: loginItemEnabled())
    }
}

/// How this process was started; only an ordinary, interactive controller launch may introduce the app.
struct FirstRunLaunchContext: Equatable {
    var isDemo = false
    /// Monitor-only, sibling, release-monitoring or lease-unavailable sessions.
    var monitoringOnly = false
    var showDetailsRequested = false
    var launchedAsLoginItem = false

    static func current(arguments: [String], policy: AppLaunchPolicy) -> Self {
        Self(isDemo: arguments.contains("--demo"), monitoringOnly: policy.monitoringOnly,
             showDetailsRequested: arguments.contains("--show-details"), launchedAsLoginItem: LoginLaunchDetector.launchedAsLoginItem())
    }
}

/// The single exception to the quiet launch: a first-run window at the very first launch of a fresh install.
enum FirstRunDecision: Equatable {
    case show
    /// An existing user: record the key so nothing ever appears, now or after a later update.
    case markSilently
    case nothing

    static let introducedKey = "firstRunIntroduced.v1"

    static func decide(signals: FirstRunSignals, context: FirstRunLaunchContext) -> Self {
        if signals.introduced { return .nothing }
        // Demo and monitoring sessions neither show nor record anything: the real first launch is still ahead.
        if context.isDemo || context.monitoringOnly { return .nothing }
        if signals.hasPriorUse { return .markSilently }
        if context.launchedAsLoginItem || context.showDetailsRequested { return .nothing }
        return .show
    }

    static func markIntroduced(_ defaults: UserDefaults) { defaults.set(true, forKey: introducedKey) }
}

enum LoginLaunchDetector {
    /// The launch Apple event carries `keyAELaunchedAsLogInItem` when macOS starts the app at login.
    static func launchedAsLoginItem(event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
