// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// The redesigned main window (direction C, behind `FeatureFlags.newWindow`): the glass column with the sections, the
/// page beside it, unified toolbar.
@MainActor struct MainWindowView: View {
    let model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("MainWindowView")
        WindowThemeResolver {
            WindowShell(model: model) { WindowDetail(model: model) }
        }
        .environment(\.locale, L10n.locale)
        .font(.system(size: 13))
        .id(model.language)
        // No SwiftUI minimum frame: the window's `contentMinSize` holds it. A 560 pt minimum here applied below the
        // toolbar, overflowed a 560 pt window and the hosting view centred it (page tabs slid under the toolbar).
    }
}

/// Sidebar variant C «Колонна» (owner choice 2026-11-22): one inset glass panel with the sections, full height, the
/// traffic lights on its glass. The column's toggle (⌃⌘S) narrows it to an icon rail below the toolbar in one motion:
/// icons keep their place, names and group titles fade, group titles turn into dividers. The page keeps the column's
/// width free. The page title is drawn by this view in the toolbar row, not as a toolbar item: a toolbar item's place
/// is AppKit's to decide (it moved between window states), and steering it from a measurement made it jitter.
@MainActor struct WindowShell<Detail: View>: View {
    let model: TilveroModel
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        let collapsed = model.navigation.sidebarCollapsed
        let inset = WindowColumn.inset(progress: collapsed ? 1 : 0)
        ZStack(alignment: .topLeading) {
            detail()
                .safeAreaPadding(.leading, inset)
                .toolbar(removing: .title)
                .toolbar {
                    // Keeps toolbar items off the drawn title. Computed, never measured: a measured item fed back into
                    // the toolbar layout and jittered.
                    ToolbarItem(placement: .navigation) {
                        Color.clear.frame(width: WindowPageTitle.reservedWidth(model: model, collapsed: collapsed), height: 1)
                            .accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    WindowColumn(model: model, progress: collapsed ? 1 : 0, height: proxy.size.height)
                    WindowPageTitle(model: model, progress: collapsed ? 1 : 0)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// The page title in the toolbar row, above the page's leading edge; it travels with the column through the motion.
@MainActor struct WindowPageTitle: View, Animatable {
    let model: TilveroModel
    var progress: Double
    @Environment(\.appearsActive) private var active

    static let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    /// Width of the leading toolbar spacer that keeps items clear of the title: up to the title's end plus a gap, from
    /// the earliest place AppKit starts the first item (66 pt, right of the traffic lights).
    static func reservedWidth(model: TilveroModel, collapsed: Bool) -> CGFloat {
        let title = WindowSection.entry(model.navigation.section).title as NSString
        let end = WindowColumn.inset(progress: collapsed ? 1 : 0) + WindowTheme.pagePadding.leading
            + title.size(withAttributes: [.font: font]).width
        return max(1, (end + 16 - 66).rounded(.up))
    }

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Text(WindowSection.entry(model.navigation.section).title)
            .font(Font(Self.font))
            .foregroundStyle(active ? .primary : .tertiary)
            .lineLimit(1).fixedSize()
            .frame(height: WindowColumn.toolbarHeight)
            .offset(x: WindowColumn.inset(progress: progress) + WindowTheme.pagePadding.leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the window title carries it
    }
}

/// The glass column. Animatable: the body runs every frame of the toggle, so names fade in the first half and the
/// dividers appear in the second. Its own view: telemetry does not re-render it (only the section, the attention marks
/// and the progress are read).
@MainActor struct WindowColumn: View, Animatable {
    let model: TilveroModel
    var progress: Double          // 0 = full column, 1 = icon rail
    let height: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static let fullWidth: CGFloat = 220
    static let railWidth: CGFloat = 60
    static let edge: CGFloat = 8
    static let toolbarHeight: CGFloat = 52
    static let motion = Animation.smooth(duration: 0.32)
    static func width(progress: Double) -> CGFloat { railWidth + (fullWidth - railWidth) * (1 - progress) }
    /// Leading space the page keeps free.
    static func inset(progress: Double) -> CGFloat { edge + width(progress: progress) }

    var body: some View {
        let _ = RenderProbe.hit("WindowColumn")
        let names = max(0, 1 - progress / 0.5)
        let dividers = max(0, (progress - 0.5) / 0.5)
        let width = Self.width(progress: progress)
        let top = Self.edge + (Self.toolbarHeight - Self.edge) * progress
        let selected = model.navigation.section
        let railed = progress > 0.5
        VStack(alignment: .leading, spacing: 0) {
            WindowColumnHeader(progress: progress, names: names, collapsed: model.navigation.sidebarCollapsed) {
                withAnimation(Self.motion) { model.navigation.sidebarCollapsed.toggle() }
            }
            ForEach(Array(WindowSidebarGroup.allCases.enumerated()), id: \.element) { index, group in
                if index > 0 {
                    ZStack(alignment: .leading) {
                        Text(group.title ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .fixedSize().padding(.leading, 6).opacity(names)
                        Divider().frame(width: 26).padding(.leading, 6).opacity(dividers)
                    }
                    .frame(height: 26 - 6 * progress, alignment: .bottomLeading).padding(.bottom, 4)
                    .accessibilityHidden(names == 0)
                }
                ForEach(WindowSection.sections(in: group)) { entry in
                    let mark = WindowSidebarMark.mark(entry.section, model: model)
                    WindowColumnRow(entry: entry, selected: entry.section == selected, width: width - 22, names: names,
                                    railed: railed, mark: mark?.color, markLabel: mark?.label) {
                        model.navigation.navigate(to: .section(entry.section))
                    }
                }
            }
            Spacer(minLength: 0)
            if model.isDemo {
                Label(L10n.text("Simulation"), systemImage: "testtube.2").labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                    .opacity(names).padding(.leading, 6).padding(.bottom, 14)
            }
        }
        .padding(.top, (Self.toolbarHeight - Self.edge) * (1 - progress))   // clears the traffic lights at full height
        .padding(.horizontal, 11)
        .frame(width: width, height: max(0, height - top - Self.edge), alignment: .topLeading)
        .clipped()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.leading, Self.edge).padding(.top, top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }
}

/// The column's head: the brand, and the sidebar toggle (⌃⌘S) that lives in the column — at the right end of the brand
/// row while the column is open, under the wave on the rail — moving with the column through the motion.
@MainActor struct WindowColumnHeader: View {
    let progress: Double
    let names: Double
    let collapsed: Bool
    let action: @MainActor () -> Void
    @State private var hovering = false

    static let toggleSize = CGSize(width: 32, height: 30)

    var body: some View {
        let label = L10n.text(collapsed ? "Show sidebar" : "Hide sidebar")
        let fullX = WindowColumn.fullWidth - 22 - Self.toggleSize.width
        let railX = (38 - Self.toggleSize.width) / 2
        let x = fullX + (railX - fullX) * progress
        let y = 14 + 36 * progress
        ZStack(alignment: .topLeading) {
            WindowColumnBrand(names: names)
            Button(action: action) {
                Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: Self.toggleSize.width, height: Self.toggleSize.height)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("sidebar.toggle")
            .offset(x: x, y: y)
        }
        .frame(height: 14 + 30 + 12 + 34 * progress, alignment: .topLeading)
    }
}

/// The wave in the icon column and «Tilvero» beside it (the name fades with the section names).
struct WindowColumnBrand: View {
    let names: Double
    var body: some View {
        HStack(spacing: 10) {
            TilveroEnergyMark().stroke(WindowTheme.accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 30, height: 16).frame(width: 38)
            Text(AppIdentity.displayName).font(.system(size: 20, weight: .semibold)).fixedSize().opacity(names)
        }
        .frame(height: 30).padding(.top, 14)
        .accessibilityElement().accessibilityLabel(AppIdentity.displayName).accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.brand")
    }
}

/// One section: green icon in a fixed column, name, the neutral grey selection plate (owner decision 2026-11-20). On
/// the rail the attention dot moves onto the icon and the name becomes the tooltip.
@MainActor struct WindowColumnRow: View {
    let entry: WindowSection
    let selected: Bool
    let width: CGFloat
    let names: Double
    let railed: Bool
    var mark: Color?
    var markLabel: String?
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol).font(.system(size: 16)).foregroundStyle(WindowTheme.accent)
                    .frame(width: 38, height: 34)
                    .overlay(alignment: .topTrailing) {
                        if let mark, railed { Circle().fill(mark).frame(width: 7, height: 7).offset(x: -3, y: 4) }
                    }
                Text(entry.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1).fixedSize()
                    .opacity(names)
                Spacer(minLength: 4)
                if let mark, !railed { Circle().fill(mark).frame(width: 7, height: 7).padding(.trailing, 10).opacity(names) }
            }
            .frame(width: max(38, width), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(selected ? WindowTheme.sidebarSelectionOpacity : 0)))
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .help(railed ? entry.title : "")
        .keyboardShortcut(Self.shortcut(entry), modifiers: .command)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(markLabel ?? "")
        .accessibilityIdentifier("sidebar." + entry.section.rawValue)
    }

    /// ⌘1…⌘9 follow the column order (Go menu equivalents).
    static func shortcut(_ entry: WindowSection) -> KeyEquivalent {
        KeyEquivalent(Character(String(WindowSection.shortcutIndex(entry.section) ?? 0)))
    }
}

/// Attention dots on the column's sections.
@MainActor enum WindowSidebarMark {
    /// Orange dot on Diagnostics (charge attention, recovery required); dot on Settings when an update is available.
    /// The dot is never colour alone: VoiceOver reads its label as the row's value.
    static func mark(_ section: InfoSection, model: TilveroModel) -> (color: Color, label: String)? {
        switch section {
        case .diagnostics:
            guard !model.isDemo else { return nil }
            if model.liveControl.recoveryRequired { return (.orange, L10n.text("App-owned settings require restoration")) }
            let presentation = model.nativeCharge.presentation()
            return presentation.requiresGlobalAttention ? (.orange, L10n.text(presentation.attention.titleKey)) : nil
        case .settings:
            return model.updates.newerRelease.map { (WindowTheme.accent, String(format: L10n.text("New version %@"), String($0.tag.dropFirst()))) }
        default: return nil
        }
    }
}

/// Detail column: canvas, tint, one page per section.
@MainActor struct WindowDetail: View {
    let model: TilveroModel

    var body: some View {
        let section = model.navigation.section
        Group {
            switch section {
            case .overview:
                OverviewPage(model: model)
            case .battery:
                BatteryPage(model: model)
            case .cooling:
                CoolingPage(model: model)
            case .history:
                HistoryPage(model: model)
            case .diagnostics:
                DiagnosticsPage(model: model)
            case .activity:
                AppsPage(model: model)
            case .charging:
                ChargingPage(model: model)
            case .sleep:
                SleepDrainPage(model: model)
            case .settings:
                SettingsHostPage(model: model)
            }
        }
        .background { WindowCanvas().ignoresSafeArea() }
        .tint(WindowTheme.accent)
        // One export preview for the whole window: an export started on one page and finished after switching to
        // another is still presented, never stranded until a page with its own sheet appears.
        .sheet(isPresented: Binding(get: { model.exportPreview != nil }, set: { if !$0 { model.exportPreview = nil } })) {
            ExportPreviewSheet(model: model)
        }
        .toolbar {
            if model.isDemo {
                ToolbarItem(placement: .navigation) {
                    Text("DEMO").font(.caption.weight(.bold)).foregroundStyle(.orange).padding(.horizontal, 8)
                        .accessibilityLabel(L10n.text("Simulation"))
                }
            }
        }
    }
}

/// Export preview (same layout as the previous window's sheet).
@MainActor struct ExportPreviewSheet: View {
    var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Export preview")).font(.title2)
            Text(L10n.text("Serials and private identifiers are excluded.")).foregroundStyle(.secondary)
            ScrollView {
                Text(model.exportPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L10n.text("Cancel")) { model.exportPreview = nil }
                Spacer()
                Button(L10n.text("Save…")) { model.saveExport() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 620, height: 470)
    }
}
