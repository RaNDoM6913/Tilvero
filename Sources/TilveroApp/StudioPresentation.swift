import SwiftUI

struct StudioPresentationValues: Equatable {
    var theme = "baseline"
    var spacingAdjustment = 0.0
    var cornerRadius: Double? = nil
    var rgb: [Double]? = nil
    var accent: Color {
        guard let rgb, rgb.count == 3 else { return .green }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
    var canvas: Color { theme == "baseline" ? .white : Color(nsColor: .windowBackgroundColor) }
    var surface: Color { theme == "baseline" ? .white : Color(nsColor: .controlBackgroundColor) }
    var foreground: Color { theme == "baseline" ? .black.opacity(0.9) : .primary }
    var sidebar: Color { theme == "baseline" ? Color(red: 0.95, green: 0.95, blue: 0.95) : Color(nsColor: .underPageBackgroundColor) }
    func spacing(_ base: CGFloat) -> CGFloat { max(0, base + spacingAdjustment) }
    func radius(_ base: CGFloat) -> CGFloat { cornerRadius ?? base }
}
private struct StudioPresentationKey: EnvironmentKey { static let defaultValue = StudioPresentationValues() }
extension EnvironmentValues {
    var studioPresentation: StudioPresentationValues { get { self[StudioPresentationKey.self] } set { self[StudioPresentationKey.self] = newValue } }
}

func studioSemanticID(_ value: String) -> String {
    value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
}

/// Presentation-only attachment points. The ordinary product compiles these to
/// identity operations; the laboratory supplies the optional editor environment.
extension View {
    @ViewBuilder func studioElement(_ id: String, kind: String = "control", label: String = "", file: String = #filePath, line: UInt = #line) -> some View {
        #if TILVERO_LAB_STUDIO
        modifier(StudioElementModifier(id: id, kind: kind, label: label, file: file, line: line))
        #else
        self
        #endif
    }

    @ViewBuilder func studioScope(_ scope: String) -> some View {
        #if TILVERO_LAB_STUDIO
        modifier(StudioScopeModifier(scope: scope))
        #else
        self
        #endif
    }

    @ViewBuilder func studioSubpresentation(_ id: String) -> some View {
        #if TILVERO_LAB_STUDIO
        modifier(StudioSubpresentationModifier(id: id))
        #else
        self
        #endif
    }

    func studioMainScheme() -> some View { modifier(StudioMainSchemeModifier()) }
}

private struct StudioMainSchemeModifier: ViewModifier {
    @Environment(\.studioPresentation) private var presentation
    @Environment(\.colorScheme) private var inherited
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, presentation.theme == "dark" ? .dark : presentation.theme == "system" ? inherited : .light)
    }
}

/// A String text leaf, preserving the original Text styling when no editor is
/// present. Explicit semantic IDs belong to the owning real component.
struct StudioText: View {
    let value: String
    let id: String
    let file: String
    let line: UInt
    init(_ value: String, id: String, file: String = #filePath, line: UInt = #line) {
        self.value = value; self.id = id; self.file = file; self.line = line
    }
    var body: some View {
        #if TILVERO_LAB_STUDIO
        StudioEditableText(value: value, id: id, file: file, line: line)
        #else
        Text(value)
        #endif
    }
}

struct StudioActionButton: View {
    let title: String
    let id: String
    var role: ButtonRole? = nil
    let file: String
    let line: UInt
    let action: () -> Void
    init(_ title: String, id: String, role: ButtonRole? = nil, file: String = #filePath, line: UInt = #line, action: @escaping () -> Void) {
        self.title = title; self.id = id; self.role = role; self.file = file; self.line = line; self.action = action
    }
    var body: some View {
        #if TILVERO_LAB_STUDIO
        Button(role: role, action: action) { StudioText(title, id: id + ".caption", file: file, line: line) }
            .studioElement(id, label: title, file: file, line: line)
        #else
        Button(title, role: role, action: action)
        #endif
    }
}
