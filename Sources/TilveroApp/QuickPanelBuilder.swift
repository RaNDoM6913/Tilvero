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
    /// The block whose settings are open, and the block under the pointer: both are outlined in the preview.
    @State private var expanded: OverviewMetric?
    @State private var hovered: OverviewMetric?
    @State private var previewHeight: CGFloat = 0
    @Namespace private var blocks
    init(model: TilveroModel, expanded: OverviewMetric? = nil) {
        self.model = model
        _expanded = State(initialValue: expanded)
    }
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
        let prefs = model.overviewPreferences
        let spring = OverviewBlockList.settle
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Quick panel builder")).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(OverviewLayoutPreset.allCases) { preset in
                    OverviewPresetCapsule(title: L10n.text(preset.title), symbol: preset.symbol, selected: prefs.layoutPreset == preset) {
                        withAnimation(spring) { expanded = nil; model.overviewPreferences.apply(preset) }
                    }
                }
                OverviewPresetCapsule(title: L10n.text("Your own (layout)"), symbol: "slider.horizontal.3", selected: prefs.layoutPreset == nil) {
                    withAnimation(spring) { expanded = nil; model.overviewPreferences.restoreCustomLayout() }
                }
                .disabled(prefs.layoutPreset != nil && prefs.customLayout == nil)
            }
            Text(L10n.text("In the menu")).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
            if prefs.visible.isEmpty {
                Text(L10n.text("No blocks in the menu. Add one below.")).font(.callout).foregroundStyle(.secondary)
            } else {
                OverviewBlockList(model: model, expanded: $expanded, hovered: $hovered, namespace: blocks)
            }
            Text(L10n.text("Can be added")).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
            if prefs.available.isEmpty {
                Text(L10n.text("Every block is in the menu.")).font(.callout).foregroundStyle(.secondary)
            } else {
                QuickPresetFlow(spacing: 8) {
                    ForEach(prefs.available) { item in
                        OverviewAddChip(item: item) { withAnimation(spring) { model.overviewPreferences.add(item) } }
                            .matchedGeometryEffect(id: item, in: blocks)
                    }
                }
            }
            OverviewHeightMeter(height: previewHeight)
            Button(L10n.text("Restore layout defaults")) {
                withAnimation(spring) { expanded = nil; Self.restoreLayoutDefaults(model) }
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
                .environment(\.overviewHighlightedBlock, expanded ?? hovered)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
            Text(L10n.text("Preview uses your current readings and saved layout. Controls are inactive."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A read-only rendering of the quick menu. Its Sleep and Charge pages are the real panels (their appearance tasks
/// only read), kept unreachable: hit testing off, disabled and hidden from accessibility, so nothing can apply.
/// Only the local preview-tab selection can change here.
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
                HStack(spacing: 3) {   // the real header's borderless gear menu: gear + small chevron
                    Image(systemName: "gearshape")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }.foregroundStyle(.secondary)
            }
            // The real quick menu's tabs (full-width capsules), as in the Sleep presets preview.
            QuickPanelTabs(selection: $section).frame(maxWidth: .infinity)
            if section == .awake { CompactSleepTabs(selection: $sleepPage) }
            VStack(alignment: .leading, spacing: 12) {
                switch section {
                case .overview:
                    OverviewHero(model: model, openCharge: nil)
                    Divider()
                    if model.sleepTimer.isActive { SleepTimerActiveRow(model: model).disabled(true) }
                    if model.keepAwake.hasOwnedAssertion, model.overviewPreferences.hidden.contains(.keepAwake) { passiveSession }
                    OverviewMetricsPanel(model: model)
                case .charge:
                    // The real charge page (it only reads on appearance; nothing here can be pressed, so it never applies).
                    if !model.isDemo && model.usesNativeCharge { QuickNativeChargePanel(model: model) } else { charge }
                case .modes: modes
                case .awake:
                    // The real Sleep pages, as in the quick menu and the Sleep presets preview.
                    if sleepPage == .timer { SleepTimerPillsPanel(model: model) } else { KeepAwakePillsPanel(model: model) }
                }
            }
            // The live panels are shown for their look only: no mouse, no keyboard focus, no VoiceOver press can reach them.
            .allowsHitTesting(false).disabled(true).accessibilityHidden(true)
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

/// «В меню»: the shown blocks as a list that reorders in place. A block is dragged whole (lifted, tinted, with a
/// shadow), the blocks it passes slide aside, and on release it settles into its slot. (−) hides a block; a chart
/// block opens its own settings. VoiceOver gets Move up / Move down actions.
@MainActor struct OverviewBlockList: View {
    @Bindable var model: TilveroModel
    @Binding var expanded: OverviewMetric?
    @Binding var hovered: OverviewMetric?
    let namespace: Namespace.ID
    @State private var dragging: OverviewMetric?
    @State private var translation: CGFloat = 0
    /// `frozenDrag`: a drag caught mid-way (render tests); nil in the app.
    init(model: TilveroModel, expanded: Binding<OverviewMetric?>, hovered: Binding<OverviewMetric?>, namespace: Namespace.ID,
         frozenDrag: (OverviewMetric, CGFloat)? = nil) {
        self.model = model; _expanded = expanded; _hovered = hovered; self.namespace = namespace
        _dragging = State(initialValue: frozenDrag?.0)
        _translation = State(initialValue: frozenDrag?.1 ?? 0)
    }
    static let rowHeight: CGFloat = 46
    static let spacing: CGFloat = 6
    static var pitch: CGFloat { rowHeight + spacing }
    static let settle = Animation.spring(response: 0.32, dampingFraction: 0.84)

    var body: some View {
        let order = model.overviewPreferences.visible
        let from = dragging.flatMap { order.firstIndex(of: $0) }
        let target = from.map { OverviewBlockReorder.target(from: $0, translation: translation, pitch: Self.pitch, count: order.count) }
        VStack(spacing: Self.spacing) {
            ForEach(Array(order.enumerated()), id: \.element) { index, item in
                let lifted = item == dragging
                OverviewBlockRow(model: model, item: item, lifted: lifted, expanded: expanded == item,
                                 toggleSettings: { withAnimation(Self.settle) { expanded = expanded == item ? nil : item } },
                                 remove: { withAnimation(Self.settle) {
                                     if expanded == item { expanded = nil }
                                     model.overviewPreferences.remove(item)
                                 } })
                    .frame(minHeight: Self.rowHeight)
                    .matchedGeometryEffect(id: item, in: namespace)
                    .offset(y: lifted ? translation : OverviewBlockReorder.shift(index: index, from: from, to: target, pitch: Self.pitch))
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted ? nil : Self.settle, value: target)
                    .gesture(dragGesture(for: item))
                    .onHover { inside in if inside { hovered = item } else if hovered == item { hovered = nil } }
                    .accessibilityAction(named: L10n.text("Move up")) {
                        withAnimation(Self.settle) { model.overviewPreferences.moveVisible(item, to: index - 1) }
                    }
                    .accessibilityAction(named: L10n.text("Move down")) {
                        withAnimation(Self.settle) { model.overviewPreferences.moveVisible(item, to: index + 1) }
                    }
            }
        }
        .onDisappear { dragging = nil; translation = 0 }
    }

    private func dragGesture(for item: OverviewMetric) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragging == nil {
                    expanded = nil   // equal row heights while a row travels
                    withAnimation(.easeOut(duration: 0.15)) { dragging = item }
                }
                if dragging == item { translation = value.translation.height }
            }
            .onEnded { value in
                guard dragging == item, let start = model.overviewPreferences.visible.firstIndex(of: item) else {
                    dragging = nil; translation = 0   // never left lifted (a block hidden mid-drag)
                    return
                }
                let slot = OverviewBlockReorder.target(from: start, translation: value.translation.height, pitch: Self.pitch,
                                                       count: model.overviewPreferences.visible.count)
                withAnimation(Self.settle) {
                    model.overviewPreferences.moveVisible(item, to: slot)
                    dragging = nil
                    translation = 0
                }
            }
    }
}

/// One shown block: grab handle, accent icon, title, settings (chart blocks), (−); open, its chart height.
@MainActor private struct OverviewBlockRow: View {
    @Bindable var model: TilveroModel
    let item: OverviewMetric
    let lifted: Bool
    let expanded: Bool
    let toggleSettings: () -> Void
    let remove: () -> Void
    @Environment(\.windowTheme) private var theme

    var body: some View {
        let title = L10n.text(item.title)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let tinted = lifted || expanded
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(width: 16).accessibilityHidden(true)
                Image(systemName: item.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(WindowTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WindowTheme.accent.opacity(0.14)))
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if item.hasSettings {
                    Button(action: toggleSettings) {
                        Image(systemName: expanded ? "chevron.up" : "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(expanded ? WindowTheme.accent : Color.secondary).frame(width: 24, height: 24)
                    }
                    .help(L10n.text("Block settings")).accessibilityLabel(L10n.text("Block settings") + ": " + title)
                }
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .help(L10n.text("Remove from the menu")).accessibilityLabel(L10n.text("Remove from the menu") + ": " + title)
            }
            if expanded, item == .forecast {
                HStack(spacing: 8) {
                    Text(L10n.text("Look (block)")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker(L10n.text("Look (block)"), selection: $model.overviewPreferences.forecastStyle) {
                        ForEach(OverviewForecastStyle.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                }
                .padding(.leading, 54)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if expanded {
                HStack(spacing: 8) {
                    Text(L10n.text("Chart")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker(L10n.text("Chart size"), selection: Binding(get: { model.overviewPreferences.chartSize(for: item) },
                                                                      set: { model.overviewPreferences.setChartSize($0, for: item) })) {
                        ForEach(MetricChartSize.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                }
                .padding(.leading, 54)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tinted ? WindowTheme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
        .overlay(shape.strokeBorder(tinted ? WindowTheme.accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: tinted ? 1 : 0.5))
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

/// «Можно добавить»: a hidden block as a dashed chip; a click adds it to the end of the menu.
@MainActor private struct OverviewAddChip: View {
    let item: OverviewMetric
    let add: () -> Void
    var body: some View {
        Button(action: add) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(WindowTheme.accent)
                Image(systemName: item.symbol).foregroundStyle(.secondary)
                Text(L10n.text(item.title)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Add to the menu") + ": " + L10n.text(item.title))
    }
}

/// A ready-made layout: accent fill when the shown blocks match it.
@MainActor private struct OverviewPresetCapsule: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? WindowTheme.accent : Color.primary.opacity(0.07)))
                .opacity(enabled || selected ? 1 : 0.45)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How tall the quick menu gets against the screen it opens on (the preview's height, so ≈); orange when it would not fit.
@MainActor private struct OverviewHeightMeter: View {
    let height: CGFloat
    var body: some View {
        let screen = (NSScreen.main?.visibleFrame.height ?? 0) - 40   // the popover's arrow and margin
        let fits = height <= screen
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Menu height")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(height > 0 && screen > 0 ? "≈ \(Int(height.rounded())) / \(Int(screen.rounded())) pt" : "—")
                    .monospacedDigit().foregroundStyle(fits ? Color.secondary : Color.orange)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(fits ? WindowTheme.accent : Color.orange)
                        .frame(width: screen > 0 ? geo.size.width * min(1, height / screen) : 0)
                        .animation(.easeInOut(duration: 0.25), value: height)
                }
            }
            .frame(height: 8)
            if !fits {
                Text(L10n.text("The menu is taller than the screen. Remove a block or make a chart smaller."))
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}
