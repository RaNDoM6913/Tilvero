import AppKit
import SwiftUI
import PowerCore

enum QuickPanelSection: String, CaseIterable, Identifiable {
    case overview, charge, modes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: L10n.text("Overview")
        case .charge: L10n.text("Charge")
        case .modes: L10n.text("Modes")
        }
    }
}

@MainActor
struct QuickPanel: View {
    @ObservedObject var model: TilveroModel
    var maximumHeight: CGFloat = 700
    var onSizeChange: ((CGSize) -> Void)?
    @State var section: QuickPanelSection = .overview

    var body: some View {
        QuickPanelLayout(maximumHeight: maximumHeight) {
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
            }
        }
        .frame(width: 360)
        .environment(\.locale, L10n.locale)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange?($0) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppIdentity.displayName).font(.headline)
                Spacer()
                Text(L10n.text(model.isDemo ? "Simulation" : "Live readings"))
                    .font(.caption).foregroundStyle(.secondary)
                settingsMenu
            }
            Picker(L10n.text("Battery menu"), selection: $section) {
                ForEach(QuickPanelSection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                switch section {
                case .overview: overview
                case .charge: charge
                case .modes: modes
                }
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button {
                model.selectedSection = .history
                model.openDetails?()
            } label: {
                HStack {
                    Label(L10n.text("History & reports…"), systemImage: "chart.bar.xaxis")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderless)
            Text("\(L10n.text("Last collection")): \(model.snapshot.collectedAt.formatted(.dateTime.hour().minute().locale(L10n.locale)))")
                .font(.caption2).foregroundStyle(.secondary)
                .help(L10n.text("This is an observation time, not necessarily the hardware measurement time."))
        }.padding(20).frame(width: 360, alignment: .leading)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.chargeText).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(model.chargingStateText).font(.subheadline).foregroundStyle(.secondary)
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
            OverviewMetricsPanel(model: model)
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
                Button(L10n.text(model.isOneShotDemo ? "Cancel one-time charge" : "Charge to 100% once")) { model.toggleOneShotDemo() }
                    .disabled(model.isApplying || !model.canChargeToFullOnce)
                Button(L10n.text("Return to system control")) { model.releaseControl() }
                    .disabled(model.isApplying || !model.canReleaseCharge)
            }
        }
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Profiles")).font(.headline)
            Text(L10n.text("Profiles require verified control capabilities."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(["At desk", "On battery profile", "Before leaving", "Sustained work"], id: \.self) { name in
                Button(L10n.text(name)) { model.applyProfile(name) }
                    .disabled(!model.canApplyProfiles || model.isApplying)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button(L10n.text("Settings")) { model.selectedSection = .settings; model.openDetails?() }
            Button(L10n.text("Customize quick panel…")) { model.selectedSection = .settings; model.openDetails?() }
            Picker(L10n.text("Menu bar"), selection: $model.displayStyle) {
                ForEach(MenuBarDisplayStyle.allCases) { style in Text(style.title).tag(style) }
            }
            Divider()
            Button(L10n.text("Quit Tilvero")) { NSApplication.shared.terminate(nil) }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("Settings"))
    }
}

@MainActor
struct ChargeLimitControl: View {
    @ObservedObject var model: TilveroModel
    var isQuickPanel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.text("Charge limit")).font(.headline)
                Spacer()
                if model.canShowChargeControls {
                    TextField(L10n.text("Desired percentage"), text: Binding(get: { model.draftText }, set: { model.draftText = $0; model.typedDraftChanged() }))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 55)
                        .disabled(!model.canEdit).onSubmit { _ = model.validateTypedDraft() }
                        .accessibilityLabel(L10n.text("Desired percentage"))
                    Text("%")
                }
            }
            if model.canShowChargeControls {
                Slider(value: Binding(get: { model.sliderIndex }, set: model.setSliderIndex),
                       in: 0...Double(max(1, model.acceptedTargets.count - 1)), step: 1)
                    .disabled(!model.canEdit).accessibilityLabel(L10n.text("Charge limit"))
                    .accessibilityValue("\(model.draftText)%, \(L10n.text("Draft"))")
                HStack {
                    Text(model.acceptedTargets.first.map { "\($0)%" } ?? "—")
                    Spacer()
                    Text(model.acceptedTargets.last.map { "\($0)%" } ?? "—")
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([80, 90, 100], id: \.self) { target in
                        Button("\(target)%") { model.setDraft(target) }.disabled(!model.canEdit || !model.acceptedTargets.contains(target))
                    }
                    Spacer()
                    Button(L10n.text(model.isApplying ? "Applying…" : "Apply")) { model.applyDemoTarget() }
                        .buttonStyle(.borderedProminent).disabled(!model.canApply)
                }
                Text(L10n.text("Draft") + ": " + model.draftText + "%").font(.caption).foregroundStyle(.secondary)
                Text(model.effectiveLimitText).font(.caption).foregroundStyle(.secondary)
                if model.usesNativeCharge { NativeChargeStatusPanel(model: model) }
                if model.pendingTarget != nil {
                    Button(L10n.text("Cancel pending target")) { model.cancelPendingDemo() }
                    Text(L10n.text("Reconnecting early may charge to the effective limit while a lower target is pending."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if model.usesNativeCharge {
                NativeChargeStatusPanel(model: model)
                Button(L10n.text("Refresh")) { Task { await model.refreshNativeCharge() } }
            } else {
                SystemChargeLimitPanel(model: model)
                Text(L10n.text("Direct Tilvero control requires a trusted signed helper and verified hardware restoration."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if isQuickPanel {
                    Button(L10n.text("Control availability…")) {
                        model.selectedSection = .diagnostics
                        model.openDetails?()
                    }
                }
            }
        }.task { await model.refreshNativeCharge() }
    }
}

/// Measure the natural stack before offering a bounded viewport to ViewThatFits.
/// A maxHeight frame around a ScrollView alone asks AppKit to reserve the entire cap.
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
