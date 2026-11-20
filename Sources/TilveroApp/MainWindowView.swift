// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

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
            ForEach(WindowSidebarGroup.allCases) { group in
                Section {
                    ForEach(WindowSection.sections(in: group)) { entry in
                        WindowSidebarRow(entry: entry, selected: entry.section == selected, mark: mark(entry.section)) {
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
    private func mark(_ section: InfoSection) -> Color? {
        switch section {
        case .diagnostics:
            guard !model.isDemo else { return nil }
            let attention = model.nativeCharge.presentation().requiresGlobalAttention || model.liveControl.recoveryRequired
            return attention ? .orange : nil
        case .settings:
            return model.updates.newerRelease != nil ? WindowTheme.accent : nil
        default: return nil
        }
    }
}

/// One sidebar row. Selection is a neutral grey plate (owner decision 2026-11-20), icons green, text primary.
@MainActor struct WindowSidebarRow: View {
    let entry: WindowSection
    let selected: Bool
    var mark: Color?
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar." + entry.section.rawValue)
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
            default:
                LegacyPage(model: model, section: section)
            }
        }
        .background { WindowCanvas().ignoresSafeArea() }
        .tint(WindowTheme.accent)
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

/// A page not rebuilt yet: the previous page body inside the new shell (temporary, removed page by page).
@MainActor private struct LegacyPage: View {
    let model: TilveroModel
    let section: InfoSection
    var body: some View {
        BatteryInfoView(model: model, embedded: true)
            .navigationTitle(WindowSection.entry(section).title)
    }
}
