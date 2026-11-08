// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import PowerCore

enum QuickPanelSection: String, CaseIterable, Identifiable {
    case overview, awake, charge, modes
    var id: String { rawValue }

    /// Tabs still in development (Modes) are shown only in debug and laboratory builds, never in a release.
    static var showsDevelopmentSections: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.object(forInfoDictionaryKey: "TilveroDataScope") as? String == "laboratory"
        #endif
    }
    static func visibleSections(development: Bool) -> [QuickPanelSection] {
        allCases.filter { development || $0 != .modes }
    }
    /// The tabs the quick panel offers in this build.
    static var visible: [QuickPanelSection] { visibleSections(development: showsDevelopmentSections) }
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

    /// One timeline per page switch: the outgoing page fades, the incoming page fades in, and the page area (and
    /// with it the popover) changes height on a spring with no overshoot. Opacity only, no scale.
    static let pageFade = Animation.easeInOut(duration: 0.2)
    static let pageTransition = AnyTransition.opacity
    @State private var pageMotion = QuickPanelPageMotion()   // not observed here: only the page area follows it

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
            QuickPageSwitcher(selection: section) {
                switch section {
                case .overview: overview.quickPage(section)
                case .charge: charge.quickPage(section)
                case .modes: modes.quickPage(section)
                case .awake: SleepControlsPanel(model: model, compact: true).id(model.language).quickPage(section)
                }
            }
            .animation(reduceMotion ? nil : Self.pageFade, value: section)
            .onChange(of: section) { _, _ in model.dismissActionNotice() }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageMotion.naturalHeightChanged($0, animated: !reduceMotion) }
            .quickPageArea(pageMotion)
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
        // The native charge status is the Charge page's own business (QuickNativeChargePanel prints it); it must neither
        // repeat there nor leak onto the Sleep and other tabs.
        if model.noticeIsNativeChargeStatus { return nil }
        if section == .charge, model.usesNativeCharge { return nil }
        if model.isDemo, notice == L10n.text("Simulation only — your Mac settings are unchanged.") { return nil }
        return notice
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverviewHero(model: model, openCharge: { section = .charge })
            Divider()
            if model.sleepTimer.isActive { SleepTimerActiveRow(model: model, open: { section = .awake }); Divider() }
            // The Keep Awake block carries its own running session; the stop row only stands in while that block is hidden.
            if model.keepAwake.hasOwnedAssertion, model.overviewPreferences.hidden.contains(.keepAwake) { KeepAwakeActivePanel(service: model.keepAwake).id(model.language) }
            OverviewMetricsPanel(model: model, allowsAwakeActions: true, openSleep: { model.selectedSleepPage = .awake; section = .awake })
        }
    }

    @ViewBuilder private var charge: some View {
        if !model.isDemo && model.usesNativeCharge {
            QuickNativeChargePanel(model: model)
        } else { legacyCharge }
    }

    private var legacyCharge: some View {
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

/// Layout key naming a page; the switcher sizes itself to the selected page only, so the outgoing page that is
/// still fading out does not make the area taller.
private struct QuickPageIDKey: LayoutValueKey { static let defaultValue: String = "" }

extension View {
    func quickPage(_ section: QuickPanelSection) -> some View { quickPage(id: section.rawValue) }
    func quickPage(id: String) -> some View {
        layoutValue(key: QuickPageIDKey.self, value: id).transition(QuickPanel.pageTransition)
    }
}

/// Stacks pages at the top edge and sizes to the selected one. Page changes are cross-fades (see `quickPage`).
struct QuickPageSwitcher<Selection: RawRepresentable, Content: View>: View where Selection.RawValue == String {
    let selection: Selection
    @ViewBuilder var content: Content
    var body: some View { QuickPageLayout(selectedID: selection.rawValue) { content } }
}

private struct QuickPageLayout: Layout {
    let selectedID: String
    private func width(_ proposal: ProposedViewSize) -> CGFloat? { proposal.width }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { ($0[QuickPageIDKey.self], $0.sizeThatFits(proposed)) }
        let chosen = sizes.first { $0.0 == selectedID }?.1 ?? sizes.last?.1 ?? .zero
        return CGSize(width: proposal.width ?? chosen.width, height: chosen.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}


/// Height of the page area, advanced by a spring on the display's frame clock. SwiftUI's own animated layout is not
/// observable from the AppKit side, and the popover has to follow every intermediate height, so the value is
/// stepped here and applied as an ordinary (unanimated) frame: content, divider/footer and window all move together
/// from one source. The target is the selected page's natural height; an interrupted move retargets with its
/// current velocity.
@MainActor final class QuickPanelPageMotion: NSObject, ObservableObject {
    @Published private(set) var height: CGFloat?
    weak var clockView: NSView? { didSet { if clockView == nil { stop() } } }
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private static let spring = Spring(duration: 0.34, bounce: 0)

    func naturalHeightChanged(_ natural: CGFloat, animated: Bool) {
        guard natural.isFinite, natural > 0 else { return }
        target = natural
        guard let current = height else { height = natural; return }
        guard abs(current - natural) >= 0.01 || velocity != 0 else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let view = clockView, view.window?.isVisible == true else {
            stop(); height = natural; return
        }
        if link == nil {
            let created = view.displayLink(target: self, selector: #selector(step(_:)))
            created.add(to: .main, forMode: .common)
            link = created
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard var value = height else { stop(); return }
        let dt = max(1.0 / 240.0, min(1.0 / 20.0, link.targetTimestamp - link.timestamp))
        Self.spring.update(value: &value, velocity: &velocity, target: target, deltaTime: dt)
        if abs(value - target) < 0.25 && abs(velocity) < 2 {
            stop(); height = target
        } else {
            // Whole backing pixels: a fractional height would shimmer the top-aligned content.
            let scale = clockView?.window?.backingScaleFactor ?? 2
            height = (value * scale).rounded() / scale
        }
    }

    private func stop() {
        link?.invalidate(); link = nil; velocity = 0
    }
}

private struct QuickPageAreaModifier: ViewModifier {
    @ObservedObject var motion: QuickPanelPageMotion
    func body(content: Content) -> some View {
        content
            .frame(height: motion.height, alignment: .top)
            .clipped()
            .background(QuickFrameClock(motion: motion))
    }
}

private struct QuickFrameClock: NSViewRepresentable {
    let motion: QuickPanelPageMotion
    func makeNSView(context: Context) -> NSView { let view = NSView(frame: .zero); motion.clockView = view; return view }
    func updateNSView(_ view: NSView, context: Context) { motion.clockView = view }
}

extension View {
    fileprivate func quickPageArea(_ motion: QuickPanelPageMotion) -> some View { modifier(QuickPageAreaModifier(motion: motion)) }
}
// tlv-origin:3d006ddad068f1f7
