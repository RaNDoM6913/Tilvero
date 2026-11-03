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
