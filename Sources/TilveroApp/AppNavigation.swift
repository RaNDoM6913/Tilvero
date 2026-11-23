// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Observation

/// A place in the details window: a section as the user left it, or a section on a given sub-page.
enum AppDestination: Hashable, Sendable {
    /// The section with its sub-page unchanged.
    case section(InfoSection)
    /// Sleep & drain on the given page.
    case sleep(SleepPage)
    /// Settings on the given page.
    case settings(SettingsPage)
    /// Battery in the given mode (Summary or All data).
    case battery(BatteryMode)

    var section: InfoSection {
        switch self {
        case .section(let section): section
        case .sleep: .sleep
        case .settings: .settings
        case .battery: .battery
        }
    }
}

/// Which page the details window shows, and the one way every surface gets there: the quick menu, the sleep warning,
/// the update pill, first run, Setup and the window itself call `navigate(to:)` (select only) or `open(_:)` (select and
/// bring the window forward). Views that only need the page observe this object, not the model. The section is
/// remembered across launches (`lastSection`); sub-pages start on their first page each launch.
@MainActor @Observable final class AppNavigation {
    static let lastSectionKey = "lastSection"
    static let sidebarCollapsedKey = "windowSidebarCollapsed"

    private(set) var section: InfoSection
    var settingsPage: SettingsPage = .general
    var sleepPage: SleepPage = .timer
    var batteryMode: BatteryMode = .summary
    /// The window's glass column narrowed to the icon rail; remembered across launches.
    var sidebarCollapsed: Bool {
        didSet { if sidebarCollapsed != oldValue { preferences.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey) } }
    }

    /// Shows the details window; set by the app delegate (nil in tests and previews).
    @ObservationIgnored var presentDetails: (@MainActor () -> Void)?
    /// Called after the section changed (old, new).
    @ObservationIgnored var onSectionChange: (@MainActor (_ old: InfoSection, _ new: InfoSection) -> Void)?
    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
        section = InfoSection(rawValue: preferences.string(forKey: Self.lastSectionKey) ?? "") ?? .overview
        sidebarCollapsed = preferences.bool(forKey: Self.sidebarCollapsedKey)
    }

    /// Selects `destination` in the details window without showing the window.
    func navigate(to destination: AppDestination) {
        switch destination {
        case .section: break
        case .sleep(let page): sleepPage = page
        case .settings(let page): settingsPage = page
        case .battery(let mode): batteryMode = mode
        }
        select(destination.section)
    }

    /// Selects `destination` and brings the details window forward.
    func open(_ destination: AppDestination) {
        navigate(to: destination)
        presentDetails?()
    }

    /// Brings the details window forward on the page it already shows.
    func openDetails() { presentDetails?() }

    private func select(_ new: InfoSection) {
        let old = section
        if old != new { section = new }
        preferences.set(new.rawValue, forKey: Self.lastSectionKey)
        if old != new { onSectionChange?(old, new) }
    }
}
