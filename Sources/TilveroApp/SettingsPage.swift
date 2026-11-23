// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import PowerCore

/// Which Settings tabs a build shows, and which one is presented. Features (the former Setup page) is hidden exactly
/// where the old Setup tab was: DEMO, laboratory and fixture builds (`model.canShowSetup`, carried by
/// `FeatureFlags.setupPage`).
enum SettingsTabs {
    static func visible(setupPage: Bool) -> [SettingsPage] {
        SettingsPage.allCases.filter { $0 != .setup || setupPage }
    }
    static func presented(_ requested: SettingsPage, visible: [SettingsPage]) -> SettingsPage {
        visible.contains(requested) ? requested : .general
    }
}

/// The page tabs «Основные · Быстрое меню · История · Обновления · Функции».
struct SettingsTabPicker: View {
    @Binding var selection: SettingsPage
    let tabs: [SettingsPage]
    var body: some View {
        WindowPageTabs(label: L10n.text("Settings section"), selection: $selection, values: tabs) { L10n.text($0.title) }
            .accessibilityIdentifier("settings-tabs")
    }
}

/// Settings page of the main window (direction C): page tabs and one pane per tab. Every control binds to the
/// same model property or calls the same action as the previous Settings panel.
@MainActor struct SettingsHostPage: View {
    var model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("SettingsHostPage")
        let tabs = SettingsTabs.visible(setupPage: model.features.setupPage)
        let page = SettingsTabs.presented(model.navigation.settingsPage, visible: tabs)
        WindowTabbedPage {
            SettingsTabPicker(selection: Binding(get: { page }, set: { model.navigation.navigate(to: .settings($0)) }),
                              tabs: tabs)
        } content: {
            Group {
                switch page {
                case .general: SettingsGeneralPane(model: model)
                case .quickPanel: SettingsQuickMenuPane(model: model)
                case .history: SettingsHistoryPane(model: model)
                case .updates: SettingsUpdatesPane(model: model, service: model.updates)
                case .setup: SettingsFeaturesPane(model: model)
                }
            }
            .id(page)
        }
        .navigationTitle(WindowSection.entry(.settings).title)
    }
}

// MARK: Shared pieces

/// Scroll + page padding of one Settings pane.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap, content: content)
                .padding(WindowTheme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Group title above a rows tile, with an optional (i).
struct SettingsHeading: View {
    let title: String
    var info: [String] = []
    var infoID = ""
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !info.isEmpty { SectionInfoButton(title: title, paragraphs: info, id: infoID) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4).padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A tile of label/control rows separated by inset hairlines.
struct SettingsRowsTile<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        WindowTile(padding: 0) {
            VStack(spacing: 0, content: content).padding(.vertical, 4)
        }
    }
}

/// Label left, control right.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            Text(label).lineLimit(1)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

struct SettingsRowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

// MARK: General

@MainActor struct SettingsGeneralPane: View {
    var model: TilveroModel
    var body: some View {
        SettingsScroll {
            SettingsHeading(title: L10n.text("Menu bar"))
            SettingsMenuBarTile(model: model)
            SettingsHeading(title: L10n.text("App (settings group)"))
            SettingsAppTile(model: model)
        }
    }
}

@MainActor private struct SettingsMenuBarTile: View {
    @Bindable var model: TilveroModel
    var body: some View {
        SettingsRowsTile {
            SettingsRow(label: L10n.text("Battery appearance")) {
                Picker(L10n.text("Battery appearance"), selection: $model.menuBarBatteryAppearance) {
                    ForEach(MenuBarBatteryAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityIdentifier("settings.batteryAppearance")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Percentage (menu bar)")) {
                Picker(L10n.text("Percentage (menu bar)"), selection: $model.shownDisplayStyle) {
                    ForEach(MenuBarDisplayStyle.available(for: model.menuBarBatteryAppearance)) { Text(L10n.text(Self.segmentKey($0))).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityIdentifier("settings.displayStyle")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Percentage size")) {
                Picker(L10n.text("Percentage size"), selection: $model.menuBarTextSize) {
                    ForEach(MenuBarTextSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .disabled(model.shownDisplayStyle == .iconOnly)
                .accessibilityIdentifier("settings.percentageSize")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Keep Awake color")) {
                SettingsAwakeColorPicker(model: model)
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Icon scale")) {
                HStack(spacing: 10) {
                    Text("\(Int((model.menuBarIconScale * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.menuBarIconScale }, set: model.setMenuBarIconScale), in: 0.85...1.15, step: 0.05)
                        .frame(width: 180)
                        .accessibilityLabel(L10n.text("Icon scale"))
                        .accessibilityIdentifier("settings.iconScale")
                    Button(L10n.text("Reset size")) { model.resetMenuBarSizing() }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.resetSize")
                }
            }
        }
    }

    /// «Рядом · Внутри · Нет» in the row (the full names stay in the quick menu and the old panel).
    static func segmentKey(_ style: MenuBarDisplayStyle) -> String {
        switch style {
        case .beside: "Beside (percentage)"
        case .inside: "Inside (percentage)"
        case .iconOnly: "None (percentage)"
        }
    }
}

@MainActor private struct SettingsAwakeColorPicker: View {
    var model: TilveroModel
    var body: some View {
        HStack(spacing: 8) {
            ForEach(AwakeIndicatorColor.allCases) { option in
                let selected = model.awakeIndicatorColor == option
                Button { model.awakeIndicatorColor = option } label: {
                    Circle().fill(Color(nsColor: option.nsColor)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 2).padding(-3))
                        .padding(3)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .accessibilityLabel(option.title).accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(option.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.awakeColor")
    }
}

@MainActor private struct SettingsAppTile: View {
    @Bindable var model: TilveroModel
    var body: some View {
        SettingsRowsTile {
            SettingsRow(label: L10n.text("Language")) {
                Picker(L10n.text("Language"), selection: $model.language) {
                    Text(L10n.text("System language")).tag("system"); Text("Русский").tag("ru"); Text("English").tag("en")
                }
                .fixedSize().labelsHidden()
                .accessibilityIdentifier("settings.language")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Temperature")) {
                Picker(L10n.text("Temperature units"), selection: $model.temperatureUnit) {
                    Text(L10n.text("Follow system")).tag(TemperatureUnitSetting.system)
                    Text("°C").tag(TemperatureUnitSetting.celsius)
                    Text("°F").tag(TemperatureUnitSetting.fahrenheit)
                }
                .fixedSize().labelsHidden()
                .accessibilityIdentifier("settings.temperature")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Launch at login")) {
                SettingsLoginToggle(model: model)
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Keyboard backlight")) {
                SettingsKeyboardBacklightControl(service: model.keyboardBacklight)
            }
        }
    }
}

/// The previous Enable/Disable button as a switch: on = macOS reports the login item enabled; a change calls the same
/// `toggleLogin()`. Any other macOS status is shown beside the switch.
@MainActor private struct SettingsLoginToggle: View {
    var model: TilveroModel
    var body: some View {
        let status = model.loginStatus
        let enabled = status == "Enabled"
        HStack(spacing: 8) {
            if !enabled && status != "Not enabled" {
                Text(L10n.text(status)).foregroundStyle(.secondary).lineLimit(1)
            }
            Toggle(L10n.text("Launch at login"), isOn: Binding(get: { enabled }, set: { if $0 != enabled { model.toggleLogin() } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(model.isDemo || status == "Not available from this local build")
                .accessibilityIdentifier("settings.login")
        }
    }
}

/// Keyboard backlight switch: the same service calls as the previous panel (read on appearance, write on a gesture).
/// No switch while the state is unknown or suppressed by macOS: «—» instead of a guessed position.
@MainActor private struct SettingsKeyboardBacklightControl: View {
    @ObservedObject var service: KeyboardBacklightService
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if service.isBusy { ProgressView().controlSize(.small) }
                if service.isAvailable, let enabled = service.isEnabled {
                    Toggle(L10n.text("Keyboard backlight"), isOn: Binding(get: { enabled }, set: { value in
                        Task { await service.setEnabled(value) }
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(service.isBusy)
                    .accessibilityIdentifier("settings.keyboardBacklight")
                } else if service.observation != nil {
                    // Suppressed by macOS: the position is unknown, so explicit Turn on / Turn off (as before), no switch.
                    Button(L10n.text("Turn on")) { Task { await service.setEnabled(true) } }
                    Button(L10n.text("Turn off")) { Task { await service.setEnabled(false) } }
                        .help(L10n.text("macOS has dimmed or suppressed the backlight. The setting does not confirm illuminated keys."))
                } else if !service.isBusy {
                    Text("—").foregroundStyle(.tertiary)
                        .help(L10n.text(service.error == .disabledInSimulation
                            ? "Keyboard controls are unavailable in this build or simulation." : "Keyboard backlight state is unavailable."))
                        .accessibilityLabel(L10n.text("Unavailable"))
                }
            }
            .disabled(service.isBusy)
            if let error = service.error, error != .disabledInSimulation {
                Text(L10n.text(error.localizedDescription)).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.refresh() }
        }
    }
}

// MARK: History

/// Inputs of the History lead: only what the store reports.
struct SettingsHistoryInputs: Equatable, Sendable {
    var megabytes: Int64?
    var limitMegabytes: Int64?
    var since: Date?
    var enabled = true
    var demo = false
}

enum SettingsHistory {
    /// «38 МБ», «Запись идёт» / «Запись выключена», «из 512 МБ · с 4 ноября». A value the store did not report is
    /// «—» or left out, never a zero.
    static func lead(_ input: SettingsHistoryInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        let ru = language == "ru"
        let unit = ru ? "МБ" : "MB"
        if input.demo {
            return LeadDisplay(value: "—", status: L10n.text("Recording is off"), tone: .secondary,
                               detail: L10n.text("Simulation is never stored in history"))
        }
        let value = input.megabytes.map { $0.formatted(.number.locale(locale)) + " " + unit } ?? "—"
        var fragments: [String] = []
        if let limit = input.limitMegabytes, limit > 0 {
            fragments.append((ru ? "из " : "of ") + limit.formatted(.number.locale(locale)) + " " + unit)
        }
        if let since = input.since {
            let date = since.formatted(.dateTime.day().month(ru ? .wide : .abbreviated).locale(locale))
            fragments.append((ru ? "с " : "since ") + date)
        }
        return LeadDisplay(value: value, status: L10n.text(input.enabled ? "Recording (history)" : "Recording is off"),
                           tone: input.enabled ? .accent : .secondary, detail: fragments.joined(separator: " · "))
    }

    /// The erase confirmation: the same title, message, buttons and action as the previous panel.
    static let eraseTitleKey = "Erase history"
    static let eraseMessageKey = "Delete local measurements? This does not change charging or cooling settings."
    static let eraseButtonKey = "Erase history…"
}

@MainActor struct SettingsHistoryPane: View {
    var model: TilveroModel
    @State private var confirmErase: Bool
    /// - confirmingErase: start with the confirmation shown (the state the erase button sets; used by tests).
    init(model: TilveroModel, confirmingErase: Bool = false) {
        self.model = model
        _confirmErase = State(initialValue: confirmingErase)
    }
    var body: some View {
        SettingsScroll {
            SettingsHistoryLead(model: model)
            WindowNoticeView(model: model)
            SettingsHistoryRows(model: model)
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text(SettingsHistory.eraseButtonKey), role: .destructive) { confirmErase = true }
                    .disabled(model.isDemo)
                    .accessibilityIdentifier("settings.history.erase")
            }
        }
        .alert(L10n.text(SettingsHistory.eraseTitleKey), isPresented: $confirmErase) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text(SettingsHistory.eraseTitleKey), role: .destructive) { model.eraseHistory() }
        } message: {
            Text(L10n.text(SettingsHistory.eraseMessageKey))
        }
    }
}

@MainActor private struct SettingsHistoryLead: View {
    var model: TilveroModel
    var body: some View {
        let storage = model.historyStorage
        let input = SettingsHistoryInputs(megabytes: storage?.megabytes, limitMegabytes: storage?.limitMegabytes,
                                          since: model.historySummary?.monitoringStart,
                                          enabled: model.historyEnabled, demo: model.isDemo)
        LeadLine(lead: SettingsHistory.lead(input)) {
            SectionInfoButton(title: L10n.text("History"),
                              paragraphs: [L10n.text("Minute samples use the selected period. Hourly aggregates are kept for 12 months."),
                                           L10n.text("Sleep reports use the selected detailed-history period.")],
                              id: "settings-history-info")
        }
    }
}

@MainActor private struct SettingsHistoryRows: View {
    @Bindable var model: TilveroModel
    var body: some View {
        SettingsRowsTile {
            SettingsRow(label: L10n.text("Save history")) {
                Toggle(L10n.text("Save history"), isOn: $model.historyEnabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(model.isDemo)
                    .accessibilityIdentifier("settings.history.enabled")
            }
            SettingsRowDivider()
            SettingsRow(label: L10n.text("Detailed samples")) {
                Picker(L10n.text("Detailed samples"), selection: $model.retentionDays) {
                    ForEach([7, 14, 30], id: \.self) { Text(L10n.text("\($0) days")).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .disabled(model.isDemo)
                .accessibilityIdentifier("settings.history.retention")
            }
        }
    }
}
