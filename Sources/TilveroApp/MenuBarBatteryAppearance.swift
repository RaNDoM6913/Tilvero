// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Foundation

/// Battery geometry is independent of percentage placement and sizing. Resolve
/// only a missing/invalid preference from the OS; an explicit choice survives an
/// OS upgrade and changing this choice never rewrites the other preferences.
enum MenuBarBatteryAppearance: String, CaseIterable, Identifiable, Sendable {
    case macOS27, macOS26

    var id: String { rawValue }
    var title: String { self == .macOS27 ? "macOS 27" : "macOS 26" }
    var defaultDisplayStyle: MenuBarDisplayStyle { self == .macOS27 ? .inside : .beside }

    static func restored(_ stored: String?, operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Self {
        stored.flatMap(Self.init(rawValue:)) ?? (operatingSystemMajorVersion >= 27 ? .macOS27 : .macOS26)
    }
}

/// Colour of the battery fill while a Keep Awake style hold is running. Blue is the default; the others are the
/// system colours, so they adapt to the appearance like the rest of the menu bar.
enum AwakeIndicatorColor: String, CaseIterable, Identifiable, Sendable {
    case blue, teal, green, orange, pink, purple
    var id: String { rawValue }
    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .teal: .systemTeal
        case .green: .systemGreen
        case .orange: .systemOrange
        case .pink: .systemPink
        case .purple: .systemPurple
        }
    }
    var title: String {
        switch self {
        case .blue: L10n.text("Blue")
        case .teal: L10n.text("Teal")
        case .green: L10n.text("Green")
        case .orange: L10n.text("Orange")
        case .pink: L10n.text("Pink")
        case .purple: L10n.text("Purple")
        }
    }
}
