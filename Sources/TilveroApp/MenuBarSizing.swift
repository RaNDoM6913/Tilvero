import Foundation

/// Percentage typography is independent of battery geometry and measured charge.
enum MenuBarTextSize: String, CaseIterable, Identifiable, Sendable {
    case system, larger

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.text("System size")
        case .larger: L10n.text("Larger size")
        }
    }
}

enum MenuBarSizing {
    /// Corrupt or obsolete preferences must not hide, invert or enlarge the
    /// indicator beyond the user-visible slider's supported range.
    static func validatedIconScale(_ value: Double) -> Double {
        guard value.isFinite, (0.85...1.15).contains(value) else { return 1 }
        return value
    }
}
