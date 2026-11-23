// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// The sidebar of the main window as one table: groups, order, names and symbols (IA 2026-11-20 with the owner's
/// decisions: «Сон и расход» in the first group after «Зарядка»). `InfoSection` raw values do not change, so the
/// remembered `lastSection` still restores.
enum WindowSidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case main, insights, system
    var id: String { rawValue }
    /// Nil for the first group (no heading).
    var titleKey: String? {
        switch self {
        case .main: nil
        case .insights: "Insights"
        case .system: "System (sidebar group)"
        }
    }
    var title: String? { titleKey.map(L10n.text) }
}

struct WindowSection: Identifiable, Equatable, Sendable {
    let section: InfoSection
    let group: WindowSidebarGroup
    let titleKey: String
    let symbol: String
    var id: InfoSection { section }
    var title: String { L10n.text(titleKey) }

    static let all: [WindowSection] = [
        WindowSection(section: .overview, group: .main, titleKey: "Overview", symbol: "gauge.with.dots.needle.67percent"),
        WindowSection(section: .battery, group: .main, titleKey: "Battery", symbol: "battery.75percent"),
        WindowSection(section: .charging, group: .main, titleKey: "Charging (sidebar)", symbol: "powerplug.portrait"),
        WindowSection(section: .sleep, group: .main, titleKey: "Sleep & drain", symbol: "moon.zzz"),
        WindowSection(section: .cooling, group: .main, titleKey: "Cooling", symbol: "fan"),
        WindowSection(section: .history, group: .insights, titleKey: "History", symbol: "chart.xyaxis.line"),
        WindowSection(section: .activity, group: .insights, titleKey: "Apps (sidebar)", symbol: "square.stack.3d.up"),
        WindowSection(section: .diagnostics, group: .system, titleKey: "Diagnostics", symbol: "checkmark.shield"),
        WindowSection(section: .settings, group: .system, titleKey: "Settings", symbol: "gearshape"),
    ]

    static func entry(_ section: InfoSection) -> WindowSection {
        all.first { $0.section == section } ?? all[0]
    }
    static func sections(in group: WindowSidebarGroup) -> [WindowSection] { all.filter { $0.group == group } }
    /// ⌘1…⌘9 follow the sidebar order.
    static func shortcutIndex(_ section: InfoSection) -> Int? { all.firstIndex { $0.section == section }.map { $0 + 1 } }
}
