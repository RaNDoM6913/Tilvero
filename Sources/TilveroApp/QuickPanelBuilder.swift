// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import AppKit
import PowerCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, quickPanel, history, updates, setup
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .quickPanel: "Quick panel"; case .history: "History"; case .updates: "Updates"; case .setup: "Setup" }
    }
}

@MainActor struct QuickPanelBuilder: View {
    @Bindable var model: TilveroModel
    @State private var wide = true
    var body: some View {
        // One layout switched by width (not ViewThatFits): the preview of real quick-menu views is built once, not
        // measured twice on every frame of a window resize or sidebar animation.
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            WindowTile { controls }.frame(minWidth: 300, idealWidth: 340, maxWidth: .infinity, alignment: .leading)
            preview.frame(width: QuickPanelMetrics.width)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { wide = $0 }
    }
    /// Controls minimum (300) + gap (24) + preview.
    static var wideWidth: CGFloat { 300 + 24 + QuickPanelMetrics.width }
    /// Order and visibility return to their defaults.
    static func restoreLayoutDefaults(_ model: TilveroModel) { model.overviewPreferences = OverviewPreferences() }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Quick panel builder")).font(.system(size: 15, weight: .semibold))
                Text(L10n.text("Drag blocks to reorder. Switch off the ones you do not need."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L10n.text("Chart size"))
                Spacer(minLength: 8)
                Picker(L10n.text("Chart size"), selection: $model.overviewPreferences.chartSize) {
                    ForEach(MetricChartSize.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                    .studioElement("builder.chartSize", label: "Chart size")
            }
            OverviewBlockList(model: model)
            Button(L10n.text("Restore layout defaults")) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { Self.restoreLayoutDefaults(model) }
            }
            .studioElement("builder.reset", label: "Restore layout defaults")
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Live preview")).font(.headline)
                Spacer()
                Text(L10n.text("Preview only")).font(.caption).foregroundStyle(.secondary)
            }
            PassiveQuickPanelPreview(model: model)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
            Text(L10n.text("Preview uses your current readings and saved layout. Controls are inactive."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A separate read-only rendering boundary: it never instantiates live charge,
/// mode or Awake controls (some of those perform work in task/onChange handlers).
/// Only local preview-tab selection can mutate state here.
@MainActor struct PassiveQuickPanelPreview: View {
    var model: TilveroModel
    @State var section: QuickPanelSection = .overview
    @State private var sleepPage: SleepPage = .timer
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppIdentity.displayName).font(.headline)
                Spacer()
                if model.isDemo { Text(L10n.text("Simulation")).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            Picker(L10n.text("Battery menu"), selection: $section) {
                ForEach(QuickPanelSection.visible) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if section == .awake {
                Picker(L10n.text("Sleep"), selection: $sleepPage) {
                    Text(L10n.text("Sleep timer")).tag(SleepPage.timer)
                    Text(L10n.text("Keep Awake")).tag(SleepPage.awake)
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 12) {
                switch section {
                case .overview:
                    OverviewHero(model: model, openCharge: nil)
                    Divider()
                    if model.sleepTimer.isActive { SleepTimerActiveRow(model: model).disabled(true) }
                    if model.keepAwake.hasOwnedAssertion, model.overviewPreferences.hidden.contains(.keepAwake) { passiveSession }
                    OverviewMetricsPanel(model: model)
                case .charge: charge
                case .modes: modes
                case .awake:
                    if sleepPage == .timer { SleepTimerPanel(model: model, compact: true).disabled(true) }
                    else { awake }
                }
            }.allowsHitTesting(false)
            Divider()
            HStack {
                Label(L10n.text("History & reports…"), systemImage: "chart.bar.xaxis")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.font(.callout).foregroundStyle(.secondary)
        }.padding(QuickPanelMetrics.padding).frame(width: QuickPanelMetrics.width, alignment: .leading)
            .tint(.blue).accentColor(.blue)
            .environment(\.locale, L10n.locale)
    }
    private var passiveSession: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.text("Keep Mac Awake"), systemImage: "cup.and.saucer.fill").font(.subheadline.weight(.medium))
                    HStack(spacing: 6) {
                        Text(L10n.text(model.keepAwake.isActive ? "Active" : "Check session"))
                            .foregroundStyle(model.keepAwake.isActive ? Color.secondary : Color.orange)
                        if model.keepAwake.isActive {
                            Text(model.keepAwake.expiry == .untilStopped ? L10n.text("Until stopped") : KeepAwakePresentation.countdown(model.keepAwake.remainingSeconds)).monospacedDigit()
                        }
                    }.font(.caption)
                }
                Spacer(minLength: 6)
                inactiveButton("Stop")
                if model.keepAwake.isActive, model.keepAwake.expiry != .untilStopped {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(width: 20, height: 24)
                        .foregroundStyle(.secondary).accessibilityLabel(L10n.text("Extend session"))
                }
            }
            if model.keepAwake.isActive, let end = model.keepAwake.endDate {
                Text(KeepAwakePresentation.endTime(end)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.keepAwake.message {
                Text(L10n.text(message)).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var awake: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.keepAwake.hasOwnedAssertion {
                passiveSession
                Text(L10n.text("Next session")).font(.subheadline).foregroundStyle(.secondary)
            }
            else { KeepAwakeSummary(service: model.keepAwake) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(model.quickPresets.presets.keepAwake, id: \.self) { minutes in
                    passiveChoice(PresetLabel.duration(minutes), option: minutes)
                }
                passiveChoice(L10n.text("Custom…"), option: -1)
                passiveChoice(L10n.text("Until…"), option: -2)
            }
            passiveChoice("∞  " + L10n.text("Until stopped"), option: 0)
            if model.keepAwakeSelectedOption == -1 {
                HStack { Text(L10n.text("Minutes")); Spacer(); Text(model.keepAwakeCustomMinutes).monospacedDigit() }.font(.subheadline)
            }
            if case .until(let target) = model.keepAwakeDraft {
                Text(KeepAwakePresentation.endTime(target)).font(.caption).foregroundStyle(.secondary)
            }
            if model.keepAwakeDraft == .untilStopped {
                Text(L10n.text("Until stopped. Quitting Tilvero ends the session.")).font(.caption).foregroundStyle(.secondary)
            }
            if !model.keepAwake.hasOwnedAssertion { inactiveButton("Start").frame(maxWidth: .infinity, alignment: .trailing) }
            Text(L10n.text("The display can turn off. Closing the lid or choosing Sleep still works."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func passiveChoice(_ title: String, option: Int) -> some View {
        Text(title).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .foregroundStyle(model.keepAwakeSelectedOption == option ? Color.white : Color.primary)
            .background(Capsule().fill(model.keepAwakeSelectedOption == option ? Color.accentColor : Color.primary.opacity(0.07)))
    }
    private var charge: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(L10n.text("Charge limit")).font(.headline); Spacer(); Text(model.draftText + "%").monospacedDigit() }
            if model.canShowChargeControls {
                Slider(value: .constant(model.sliderIndex), in: 0...Double(max(1, model.acceptedTargets.count - 1)), step: 1).disabled(true)
                HStack {
                    Text(model.acceptedTargets.first.map { "\($0)%" } ?? "—")
                    Spacer()
                    Text(model.acceptedTargets.last.map { "\($0)%" } ?? "—")
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([80, 90, 100], id: \.self) { target in inactiveButton("\(target)%") }
                    Spacer()
                    inactiveButton("Apply")
                }
            }
            Text(model.effectiveLimitText).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.chargingStateText).font(.caption).foregroundStyle(.secondary)
            if model.canShowChargeControls {
                if model.isDemo { inactiveButton(model.isFullChargeOnceRequested ? "Cancel one-time charge" : "Charge to 100% once") }
                inactiveButton("Return to system control")
            }
        }
    }
    private var modes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("Work mode")); Spacer(); Text(L10n.text(model.selectedMode.title)).foregroundStyle(.secondary) }
            ForEach(model.modePreview(model.modeLibrary.plan(model.selectedMode)).filter { $0.status != .preserved || $0.action == .restore }) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(modeActionTitle(row.action))
                    Spacer(minLength: 8)
                    Text(L10n.text(row.status.title)).foregroundStyle(row.status == .excluded ? .orange : .secondary)
                }.font(.caption).help(L10n.text(row.detail))
            }
            HStack { inactiveButton("Edit modes…"); Spacer(); inactiveButton("Apply") }
        }
    }
    private func modeActionTitle(_ action: ModeAction) -> String {
        let plan = model.modeLibrary.plan(model.selectedMode)
        let value: String?
        switch action {
        case .charge: value = plan.chargeTarget.map { "\($0)%" }
        case .displayIdle: value = plan.displayIdleMinutes.map { "\($0) " + L10n.text("min") }
        case .brightness: value = plan.brightnessPercent.map { "\($0)%" }
        default: value = nil
        }
        return L10n.text(action.title) + (value.map { ": " + $0 } ?? "")
    }
    private func inactiveButton(_ title: String) -> some View {
        Button(L10n.text(title)) {}.disabled(true).accessibilityHint(L10n.text("Preview only"))
    }
}

/// The Overview blocks as a list that reorders in place: a block is dragged whole (lifted, tinted, with a shadow), the
/// blocks it passes slide aside, and on release it settles into its new slot. The arrows and the switch stay for
/// keyboard and VoiceOver; a switched-off block is dimmed.
@MainActor struct OverviewBlockList: View {
    @Bindable var model: TilveroModel
    @State private var dragging: OverviewMetric?
    @State private var translation: CGFloat = 0
    /// `frozenDrag`: a drag caught mid-way (render tests); nil in the app.
    init(model: TilveroModel, frozenDrag: (OverviewMetric, CGFloat)? = nil) {
        self.model = model
        _dragging = State(initialValue: frozenDrag?.0)
        _translation = State(initialValue: frozenDrag?.1 ?? 0)
    }
    static let rowHeight: CGFloat = 46
    static let spacing: CGFloat = 6
    static var pitch: CGFloat { rowHeight + spacing }
    static let settle = Animation.spring(response: 0.32, dampingFraction: 0.84)

    var body: some View {
        let order = model.overviewPreferences.order
        let from = dragging.flatMap { order.firstIndex(of: $0) }
        let target = from.map { OverviewBlockReorder.target(from: $0, translation: translation, pitch: Self.pitch, count: order.count) }
        VStack(spacing: Self.spacing) {
            ForEach(Array(order.enumerated()), id: \.element) { index, item in
                let lifted = item == dragging
                OverviewBlockRow(model: model, item: item, lifted: lifted,
                                 first: index == 0, last: index == order.count - 1)
                    .frame(height: Self.rowHeight)
                    .offset(y: lifted ? translation : OverviewBlockReorder.shift(index: index, from: from, to: target, pitch: Self.pitch))
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted ? nil : Self.settle, value: target)
                    .gesture(dragGesture(for: item))
            }
        }
    }

    private func dragGesture(for item: OverviewMetric) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragging == nil { withAnimation(.easeOut(duration: 0.15)) { dragging = item } }
                if dragging == item { translation = value.translation.height }
            }
            .onEnded { value in
                guard dragging == item, let start = model.overviewPreferences.order.firstIndex(of: item) else { return }
                let slot = OverviewBlockReorder.target(from: start, translation: value.translation.height, pitch: Self.pitch,
                                                       count: model.overviewPreferences.order.count)
                withAnimation(Self.settle) {
                    model.overviewPreferences.move(item, to: slot)
                    dragging = nil
                    translation = 0
                }
            }
    }
}

/// One block row: grab handle, tinted icon, title, arrows, switch.
@MainActor private struct OverviewBlockRow: View {
    @Bindable var model: TilveroModel
    let item: OverviewMetric
    let lifted: Bool
    let first: Bool
    let last: Bool
    @Environment(\.windowTheme) private var theme

    var body: some View {
        let shown = !model.overviewPreferences.hidden.contains(item)
        let title = L10n.text(item.title)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                .frame(width: 16).accessibilityHidden(true)
            Image(systemName: item.symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(shown ? WindowTheme.accent : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((shown ? WindowTheme.accent : Color.secondary).opacity(0.14)))
                .accessibilityHidden(true)
            Text(title).foregroundStyle(shown ? .primary : .secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button { withAnimation(OverviewBlockList.settle) { model.overviewPreferences.move(item, by: -1) } } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel(L10n.text("Move up") + ": " + title).disabled(first)
            Button { withAnimation(OverviewBlockList.settle) { model.overviewPreferences.move(item, by: 1) } } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel(L10n.text("Move down") + ": " + title).disabled(last)
            Toggle(title, isOn: Binding(get: { shown }, set: { on in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if on { model.overviewPreferences.hidden.remove(item) } else { model.overviewPreferences.hidden.insert(item) }
                }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(WindowTheme.accent)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(shape.fill(lifted ? WindowTheme.accent.opacity(0.20) : Color.primary.opacity(0.05)))
        .overlay(shape.strokeBorder(lifted ? WindowTheme.accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: lifted ? 1 : 0.5))
        .background(shape.fill(theme.tileFill.color).opacity(lifted ? 1 : 0))   // opaque under the tint while it floats
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
        .scaleEffect(lifted ? 1.02 : 1)
        .contentShape(shape)
        .pointerStyle(lifted ? .grabActive : .grabIdle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .studioElement("builder.block." + item.rawValue + ".row", kind: "container", label: item.title)
    }
}
