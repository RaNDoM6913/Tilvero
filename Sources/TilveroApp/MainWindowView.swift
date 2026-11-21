// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// The redesigned main window (direction C, behind `FeatureFlags.newWindow`): stock `NavigationSplitView`, system
/// sidebar, unified toolbar with the page title. Pages not rebuilt yet host the previous page body.
@MainActor struct MainWindowView: View {
    let model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("MainWindowView")
        WindowThemeResolver {
            NavigationSplitView {
                WindowSidebar(model: model)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            } detail: {
                WindowDetail(model: model)
            }
        }
        .environment(\.locale, L10n.locale)
        .font(.system(size: 13))
        .id(model.language)
        .frame(minWidth: MainWindowController.minimumSize.width, minHeight: MainWindowController.minimumSize.height)
    }
}

/// Sidebar: its own view, so telemetry does not re-render it (only the attention marks and the section are read).
@MainActor struct WindowSidebar: View {
    let model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("WindowSidebar")
        let selected = model.navigation.section
        List {
            WindowSidebarBrand()
            ForEach(WindowSidebarGroup.allCases) { group in
                Section {
                    ForEach(WindowSection.sections(in: group)) { entry in
                        let mark = mark(entry.section)
                        WindowSidebarRow(entry: entry, selected: entry.section == selected, mark: mark?.color, markLabel: mark?.label) {
                            model.navigation.navigate(to: .section(entry.section))
                        }
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if model.isDemo {
                Label(L10n.text("Simulation"), systemImage: "testtube.2")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
    }

    /// Orange dot on Diagnostics (charge attention, recovery required); dot on Settings when an update is available.
    /// The dot is never colour alone: VoiceOver reads its label as the row's value.
    private func mark(_ section: InfoSection) -> (color: Color, label: String)? {
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

/// «Tilvero» with the energy mark above the sections, as the previous window's sidebar had it.
struct WindowSidebarBrand: View {
    var body: some View {
        HStack(spacing: 7) {
            Text(AppIdentity.displayName).font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
            TilveroEnergyMark().stroke(WindowTheme.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 33, height: 18).accessibilityHidden(true)
        }
        .padding(.top, 2).padding(.bottom, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.brand")
    }
}

/// One sidebar row. Selection is a neutral grey plate (owner decision 2026-11-20), icons green, text primary.
@MainActor struct WindowSidebarRow: View {
    let entry: WindowSection
    let selected: Bool
    var mark: Color?
    var markLabel: String?
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Label {
                    Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                } icon: {
                    Image(systemName: entry.symbol).foregroundStyle(WindowTheme.accent)
                }
                Spacer(minLength: 4)
                if let mark {
                    Circle().fill(mark).frame(width: 7, height: 7).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(selected ? WindowTheme.sidebarSelectionOpacity : 0))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, -8)   // the plate spans the sidebar like the approved render
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(markLabel ?? "")
        .accessibilityIdentifier("sidebar." + entry.section.rawValue)
    }
}

extension WindowSidebarRow {
    /// ⌘1…⌘9 follow the sidebar order (Go menu equivalents).
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(WindowSection.shortcutIndex(entry.section) ?? 0)))
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
