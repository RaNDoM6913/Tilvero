import AppKit
import SwiftUI
import PowerCore

enum QuickPanelSection: String, CaseIterable, Identifiable {
    case overview, charge, modes, awake
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: L10n.text("Overview")
        case .charge: L10n.text("Charge")
        case .modes: L10n.text("Modes")
        case .awake: L10n.text("Sleep")
        }
    }
}

@MainActor
struct QuickPanel: View {
    @Environment(\.studioPresentation) private var studioPresentation
    @ObservedObject var model: TilveroModel
    var maximumHeight: CGFloat = 700
    var onSizeChange: ((CGSize) -> Void)?
    @State var section: QuickPanelSection = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        QuickPanelViewport(maximumHeight: maximumHeight) { content }
        .frame(width: 360)
        .environment(\.locale, L10n.locale)
        .studioElement("quick.canvas", kind: "container", label: "Quick panel canvas")
        .studioScope("page." + section.rawValue)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange?($0) }
    }

    /// Smooth cross-fade with a barely perceptible scale; the panel height follows the same curve.
    static let pageAnimation = Animation.smooth(duration: 0.34)
    static let pageTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.985, anchor: .top))

    private var content: some View {
        VStack(alignment: .leading, spacing: studioPresentation.spacing(14)) {
            HStack {
                StudioText(AppIdentity.displayName, id: "quick.brand").font(.headline)
                Spacer()
                if model.isDemo { Text(L10n.text("Simulation")).font(.caption).foregroundStyle(.secondary) }
                settingsMenu
            }
            QuickPanelTabs(selection: $section)
                .frame(maxWidth: .infinity).id(L10n.language)
                .studioElement("quick.tabs", label: "Quick menu destinations")
            Group {
                switch section {
                case .overview: overview.transition(Self.pageTransition)
                case .charge: charge.transition(Self.pageTransition)
                case .modes: modes.transition(Self.pageTransition)
                case .awake: SleepControlsPanel(model: model, compact: true).id(model.language).transition(Self.pageTransition)
                }
            }
            .animation(reduceMotion ? nil : Self.pageAnimation, value: section)
            if let notice = contextualNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button {
                model.selectedSection = section == .awake ? .sleep : .history
                model.openDetails?()
            } label: {
                HStack {
                    Label(L10n.text(section == .awake ? "Open Sleep & drain…" : "History & reports…"), systemImage: section == .awake ? "moon" : "chart.bar.xaxis")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderless).studioElement("quick.openDetails", label: "Open details")

        }.padding(20).frame(width: 360, alignment: .leading)
    }

    private var contextualNotice: String? {
        guard let notice = model.notice else { return nil }
        if section == .charge, model.usesNativeCharge, notice == model.nativeCharge.message.map(L10n.text) { return nil }
        if model.isDemo, notice == L10n.text("Simulation only — your Mac settings are unchanged.") { return nil }
        return notice
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    StudioText(model.chargeText, id: "quick.charge.value").font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    StudioText(model.chargingStateText, id: "quick.charge.status").font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(nsImage: NativeBatteryStatusImage.make(
                    level: model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil,
                    style: .iconOnly,
                    externalPower: model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.freshness != .stale && model.snapshot.isExternalPower.value == true))
                    .resizable().interpolation(.high).frame(width: 54, height: 36)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if model.snapshot.chargePercent.freshness == .stale {
                Text(L10n.text("Stale")).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            if model.sleepTimer.isActive { SleepTimerActiveRow(model: model, open: { section = .awake }); Divider() }
            if model.keepAwake.hasOwnedAssertion { KeepAwakeActivePanel(service: model.keepAwake).id(model.language) }
            OverviewMetricsPanel(model: model, allowsAwakeActions: true)
        }
    }

    private func metric(_ title: String, symbol: String, reading: CatalogReading) -> some View {
        HStack {
            Label(L10n.text(title), systemImage: symbol)
            Spacer()
            Text(ReadingPresentation.display(reading, reveal: false, fahrenheit: model.fahrenheit)).monospacedDigit()
            if reading.freshness == .stale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange) }
        }.font(.subheadline)
            .help("\(L10n.text("Source")): \(reading.source) · \(L10n.text("Freshness")): \(reading.freshness.rawValue)")
    }

    private var charge: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChargeLimitControl(model: model, isQuickPanel: true)
            if model.canShowChargeControls {
                if model.canChargeToFullOnce || model.isOneShotDemo {
                    StudioActionButton(L10n.text(model.isOneShotDemo ? "Cancel one-time charge" : "Charge to 100% once"), id: "charge.once") { model.toggleOneShotDemo() }
                        .disabled(model.isApplying)
                }
                StudioActionButton(L10n.text("Return to system control"), id: "action.return-to-system-control") { model.releaseControl() }
                    .disabled(model.isApplying || !model.canReleaseCharge)
            }
        }
    }

    private var modes: some View { SavedModePanel(model: model) }

    private var settingsMenu: some View {
        Menu {
            StudioActionButton(L10n.text("Settings"), id: "action.settings") { model.selectedSection = .settings; model.openDetails?() }
            StudioActionButton(L10n.text("Customize quick panel…"), id: "action.customize-quick-panel") { model.selectedSettingsPage = .quickPanel; model.selectedSection = .settings; model.openDetails?() }
            StudioActionButton(L10n.text("Keep Mac Awake…"), id: "action.keep-mac-awake") { model.selectedSleepPage = .awake; model.selectedSection = .sleep; model.openDetails?() }
            Picker(L10n.text("Menu bar"), selection: $model.displayStyle) {
                ForEach(MenuBarDisplayStyle.allCases) { style in Text(style.title).tag(style) }
            }
            Divider()
            StudioActionButton(L10n.text("Quit Tilvero"), id: "action.quit-tilvero") { NSApplication.shared.terminate(nil) }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("Settings"))
        .studioElement("quick.settings", label: "Quick menu settings")
    }
}

@MainActor
struct ChargeLimitControl: View {
    @ObservedObject var model: TilveroModel
    var isQuickPanel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                StudioText(L10n.text(model.isDemo ? "Charge limit" : "New charge limit"), id: "charge.title").font(.headline)
                Spacer()
                if model.canShowChargeControls {
                    TextField(L10n.text("Choose"), text: Binding(get: { model.draftText }, set: { model.draftText = $0; model.typedDraftChanged() }))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 55)
                        .disabled(!model.canEdit).onSubmit { _ = model.validateTypedDraft() }
                        .accessibilityLabel(L10n.text("Desired percentage"))
                        .studioElement("charge.percentage", label: "Desired percentage")
                    Text("%")
                }
            }
            if model.canShowChargeControls {
                if model.draftTarget != nil {
                    Slider(value: Binding(get: { model.sliderIndex }, set: model.setSliderIndex),
                           in: 0...Double(max(1, model.acceptedTargets.count - 1)), step: 1)
                        .disabled(!model.canEdit).accessibilityLabel(L10n.text("Charge limit"))
                        .accessibilityValue("\(model.draftText)%, \(L10n.text("Draft"))")
                        .accessibilityIdentifier("charge.slider")
                        .studioElement("charge.slider", label: "Charge limit slider")
                    HStack {
                        Text(model.acceptedTargets.first.map { "\($0)%" } ?? "—")
                        Spacer()
                        Text(model.acceptedTargets.last.map { "\($0)%" } ?? "—")
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Choose a new limit. No target has been selected."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    ForEach([80, 90, 100], id: \.self) { target in
                        StudioActionButton("\(target)%", id: "charge.preset.\(target)") { model.setDraft(target) }.disabled(!model.canEdit || !model.acceptedTargets.contains(target))
                    }
                    Spacer()
                    StudioActionButton(L10n.text(model.isApplying ? "Applying…" : "Apply"), id: "charge.apply") { model.applyDemoTarget() }
                        .buttonStyle(.borderedProminent).disabled(!model.canApply)
                        .accessibilityIdentifier("charge.apply")
                }
                if !isQuickPanel, model.draftTarget != nil { Text(L10n.text("Draft") + ": " + model.draftText + "%").font(.caption).foregroundStyle(.secondary) }
                if !model.usesNativeCharge { StudioText(model.effectiveLimitText, id: "charge.effective").font(.subheadline).foregroundStyle(.secondary) }
                if model.usesNativeCharge { NativeChargeStatusPanel(model: model, compact: isQuickPanel) }
                if model.pendingTarget != nil {
                    StudioActionButton(L10n.text("Cancel pending target"), id: "action.cancel-pending-target") { model.cancelPendingDemo() }
                        .help(L10n.text("Reconnecting early may charge to the effective limit while a lower target is pending."))
                    if !isQuickPanel {
                        Text(L10n.text("Reconnecting early may charge to the effective limit while a lower target is pending."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if model.usesNativeCharge {
                NativeChargeStatusPanel(model: model, compact: isQuickPanel)
            } else {
                SystemChargeLimitPanel(model: model)
                Text(L10n.text("Direct Tilvero control requires a trusted signed helper and verified hardware restoration."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if isQuickPanel {
                    StudioActionButton(L10n.text("Control availability…"), id: "action.control-availability") {
                        model.selectedSection = .diagnostics
                        model.openDetails?()
                    }
                }
            }
        }.studioElement("charge.editor", kind: "container", label: "Charge limit editor")
        .task { await model.refreshNativeChargeIfStale() }
    }
}

struct QuickPanelViewport<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        QuickPanelLayout(maximumHeight: maximumHeight) {
            ScrollView { content }
        }
    }
}

/// Measure the scroll content with an unspecified height, then offer its single
/// viewport the bounded result. Keep one editor tree as content crosses the cap;
/// separate fitted/scrolling copies lose local page and disclosure state.
private struct QuickPanelLayout: Layout {
    let maximumHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: 360, height: nil))
        return CGSize(width: 360, height: min(ideal.height, max(1, maximumHeight)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
