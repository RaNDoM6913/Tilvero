// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Which dormant or in-progress surfaces this build shows. Resolved once at launch and stored on the model, so the
/// quick menu and the window read the same value. A flag only hides UI: permission to write stays with
/// `HardwareQualification`, each service's own `allowed` state and `launchPolicy.monitoringOnly`.
struct FeatureFlags: Equatable, Sendable {
    /// Quick-menu Modes tab and the mode editor.
    var modes = false
    /// "Profiles & schedules" and schedule evaluation.
    var profilesAndSchedules = false
    /// Fan controls (they also need hardware qualification, or the simulation).
    var fanControls = false
    /// Simulation panel and the DEMO badge.
    var simulationControls = false
    /// Settings › Features (today's Setup page).
    var setupPage = true
    /// The redesigned main window (direction C). Migration switch: removed when the old window is deleted.
    var newWindow = false

    /// Launch argument that overrides `newWindow` for acceptance runs: `-TilveroNewWindow YES|NO`.
    static let newWindowArgument = "TilveroNewWindow"

    /// Pure resolution, so every build kind is testable.
    /// - development: debug and laboratory builds (`QuickPanelSection.showsDevelopmentSections`).
    /// - newWindowOverride: the launch argument, when given. Without it the redesigned window is on in every build
    ///   kind on this branch (owner testing, build 91); `-TilveroNewWindow NO` brings the old window back.
    static func resolve(development: Bool, isDemo: Bool, canShowSetup: Bool, newWindowOverride: Bool?) -> FeatureFlags {
        FeatureFlags(modes: development,
                     profilesAndSchedules: development,
                     fanControls: development || isDemo,
                     simulationControls: isDemo,
                     setupPage: canShowSetup,
                     newWindow: newWindowOverride ?? true)
    }

    /// `-TilveroNewWindow YES|NO` from the launch arguments only (a persisted preference never switches the window).
    static func newWindowOverride(arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) -> Bool? {
        switch arguments[newWindowArgument] {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String:
            switch value.uppercased() {
            case "YES", "TRUE", "1": true
            case "NO", "FALSE", "0": false
            default: nil
            }
        default: nil
        }
    }
}
