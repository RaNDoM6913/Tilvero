// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// Tokens of the main window (direction C, approved 2026-11-20): green-tinted canvas, opaque tiles, glass only on the
/// system sidebar and toolbar controls. A pure resolver over colour scheme × Reduce Transparency × Increase Contrast,
/// so tests pass the inputs explicitly. Values are those of the approved renders
/// (`local-lab/pages/window-design-20261120/Render/Sources/Render/Kit.swift`).
struct WindowTheme: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        let red, green, blue: Double
        var opacity: Double = 1
        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }
    }

    let isDark: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
    /// Canvas gradient, top-leading → (0.5, 0.75).
    let canvasTop: RGB
    let canvasBottom: RGB
    let tileFill: RGB
    let tileStroke: RGB
    let tileStrokeWidth: CGFloat
    /// Increase Contrast: secondary values are drawn in the primary colour.
    let secondaryIsPrimary: Bool

    static func resolve(dark: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> WindowTheme {
        let opaque = reduceTransparency || increaseContrast
        let fill: RGB = opaque
            ? (dark ? RGB(red: 0.15, green: 0.15, blue: 0.15) : RGB(red: 1, green: 1, blue: 1))
            : (dark ? RGB(red: 1, green: 1, blue: 1, opacity: 0.065) : RGB(red: 1, green: 1, blue: 1, opacity: 0.80))
        let primary = dark ? 1.0 : 0.0
        let stroke: RGB = increaseContrast
            ? RGB(red: primary, green: primary, blue: primary, opacity: 0.40)
            : reduceTransparency
                ? RGB(red: primary, green: primary, blue: primary, opacity: 0.18)
                : RGB(red: 1, green: 1, blue: 1, opacity: dark ? 0.08 : 0.60)
        return WindowTheme(
            isDark: dark, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast,
            canvasTop: dark ? RGB(red: 0.070, green: 0.150, blue: 0.115) : RGB(red: 0.885, green: 0.945, blue: 0.910),
            canvasBottom: dark ? RGB(red: 0.095, green: 0.100, blue: 0.105) : RGB(red: 0.958, green: 0.960, blue: 0.965),
            tileFill: fill, tileStroke: stroke, tileStrokeWidth: opaque ? 1 : 0.5,
            secondaryIsPrimary: increaseContrast)
    }

    static let light = resolve(dark: false, reduceTransparency: false, increaseContrast: false)

    // MARK: Fixed tokens
    static let accent = Color(.sRGB, red: 0.16, green: 0.68, blue: 0.42)
    static let inputPower = Color(.sRGB, red: 0.12, green: 0.52, blue: 0.98)
    static let batteryPower = Color(.sRGB, red: 1.0, green: 0.58, blue: 0.10)
    static let temperature = Color(.sRGB, red: 0.95, green: 0.27, blue: 0.30)
    static let sleep = Color.indigo

    static let tileRadius: CGFloat = 12
    static let fieldRadius: CGFloat = 10
    static let pagePadding = EdgeInsets(top: 4, leading: 24, bottom: 24, trailing: 24)
    static let tileGap: CGFloat = 14
    static let tilePadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 7
    static let leadValueSize: CGFloat = 56
    static let tileValueSize: CGFloat = 22
    /// Sidebar selection plate (owner decision 2026-11-20): neutral grey, primary at about 11 %.
    static let sidebarSelectionOpacity = 0.11
}

private struct WindowThemeKey: EnvironmentKey {
    static let defaultValue = WindowTheme.light
}

extension EnvironmentValues {
    var windowTheme: WindowTheme {
        get { self[WindowThemeKey.self] }
        set { self[WindowThemeKey.self] = newValue }
    }
}

/// Resolves the theme from the environment the view is drawn in and hands it to its content.
struct WindowThemeResolver<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environment(\.windowTheme, WindowTheme.resolve(
            dark: scheme == .dark, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased))
    }
}
