import SwiftUI
import AppKit
import PowerCore
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, quickPanel, history
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .quickPanel: "Quick panel"; case .history: "History" }
    }
}

@MainActor struct QuickPanelBuilder: View {
    @ObservedObject var model: TilveroModel
    @State private var drag = OverviewDragState()
    @State private var dropTarget: OverviewMetric?
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                controls.frame(minWidth: 300, idealWidth: 320, maxWidth: .infinity)
                preview.frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 20) { controls; preview.frame(width: 360) }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Quick panel builder")).font(.title3).bold().fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Drag blocks to reorder. Switch off the ones you do not need."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(model.overviewPreferences.order) { item in
                    HStack(spacing: 10) {
                        OverviewDragHandle(title: L10n.text(item.title), begin: { drag.begin(item).payload }, end: {
                            drag.end(); dropTarget = nil
                        }).frame(width: 20, height: 30)
                        Label(L10n.text(item.title), systemImage: item.symbol)
                        Spacer(minLength: 8)
                        Button { model.overviewPreferences.move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel(L10n.text("Move up") + ": " + L10n.text(item.title))
                            .disabled(model.overviewPreferences.order.first == item)
                        Button { model.overviewPreferences.move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel(L10n.text("Move down") + ": " + L10n.text(item.title))
                            .disabled(model.overviewPreferences.order.last == item)
                        Toggle(L10n.text(item.title), isOn: Binding(get: { !model.overviewPreferences.hidden.contains(item) }, set: {
                            if $0 { model.overviewPreferences.hidden.remove(item) } else { model.overviewPreferences.hidden.insert(item) }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(dropTarget == item ? 0.12 : 0.04)))
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.text], delegate: OverviewBlockDropDelegate(model: model, target: item, drag: $drag, dropTarget: $dropTarget))
                }
            }
            Button(L10n.text("Restore layout defaults")) { model.overviewPreferences = .init() }
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
    @ObservedObject var model: TilveroModel
    @State var section: QuickPanelSection = .overview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppIdentity.displayName).font(.headline)
                Spacer()
                if model.isDemo { Text(L10n.text("Simulation")).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            if model.keepAwake.hasOwnedAssertion { passiveSession }
            Picker(L10n.text("Battery menu"), selection: $section) {
                ForEach(QuickPanelSection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            VStack(alignment: .leading, spacing: 12) {
                switch section {
                case .overview:
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.chargeText).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(model.chargingStateText).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Image(nsImage: NativeBatteryStatusImage.make(
                            level: model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil,
                            style: .iconOnly,
                            externalPower: model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.freshness != .stale && model.snapshot.isExternalPower.value == true))
                            .resizable().interpolation(.high).frame(width: 54, height: 36).accessibilityHidden(true)
                    }
                    if model.snapshot.chargePercent.freshness == .stale { Text(L10n.text("Stale")).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    OverviewMetricsPanel(model: model)
                case .charge: charge
                case .modes: modes
                case .awake: awake
                }
            }.allowsHitTesting(false)
            Divider()
            HStack {
                Label(L10n.text("History & reports…"), systemImage: "chart.bar.xaxis")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.font(.callout).foregroundStyle(.secondary)
        }.padding(20).frame(width: 360, alignment: .leading)
            .tint(.blue).accentColor(.blue)
            .environment(\.locale, L10n.locale)
    }
    private var passiveSession: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("Keep Mac Awake"), systemImage: "cup.and.saucer.fill").font(.caption).bold()
                Spacer()
                if model.keepAwake.isActive {
                    Text(model.keepAwake.expiry == .untilStopped ? "∞" : KeepAwakePresentation.countdown(model.keepAwake.remainingSeconds))
                        .font(.headline).monospacedDigit()
                } else { Text(L10n.text("Check session")).font(.caption).foregroundStyle(.orange) }
                inactiveButton("Stop")
            }
            if model.keepAwake.isActive, let end = model.keepAwake.endDate { Text(KeepAwakePresentation.endTime(end)).font(.caption).foregroundStyle(.secondary) }
            if model.keepAwake.isActive, model.keepAwake.expiry != .untilStopped {
                HStack {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("+\(minutes) " + L10n.text("min")) {}.disabled(true).font(.caption).frame(maxWidth: .infinity)
                    }
                }
            }
            if let message = model.keepAwake.message {
                Text(L10n.text(message)).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10)))
    }
    private var awake: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.keepAwake.hasOwnedAssertion { Text(L10n.text("Next session")).font(.subheadline).foregroundStyle(.secondary) }
            else { KeepAwakeSummary(service: model.keepAwake) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    passiveChoice(duration.rawValue < 60 ? "\(duration.rawValue) " + L10n.text("min") : "\(duration.rawValue / 60) " + L10n.text("h"), option: duration.rawValue)
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
                if model.canChargeToFullOnce || model.isOneShotDemo { inactiveButton(model.isOneShotDemo ? "Cancel one-time charge" : "Charge to 100% once") }
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

@MainActor private struct OverviewBlockDropDelegate: DropDelegate {
    let model: TilveroModel
    let target: OverviewMetric
    @Binding var drag: OverviewDragState
    @Binding var dropTarget: OverviewMetric?
    func validateDrop(info: DropInfo) -> Bool {
        return drag.active != nil && info.hasItemsConforming(to: [UTType.text])
    }
    func dropEntered(info: DropInfo) { if drag.active != nil { dropTarget = target } }
    func dropExited(info: DropInfo) { if dropTarget == target { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first, let session = drag.prepareDrop() else { return false }
        dropTarget = nil
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            let payload = value as? String ?? ""
            Task { @MainActor in
                _ = drag.completeDrop(payload, session: session, onto: target, preferences: &model.overviewPreferences)
            }
        }
        return true
    }
}

/// AppKit supplies the drag-end callback missing from SwiftUI's onDrag API.
/// Only the dedicated handle starts a local move; buttons/toggles keep their input.
@MainActor private struct OverviewDragHandle: NSViewRepresentable {
    let title: String
    let begin: () -> String
    let end: () -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.begin = begin; view.end = end
        view.toolTip = L10n.text("Drag to reorder")
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(L10n.text("Drag to reorder") + ": " + title)
        view.setAccessibilityRole(.image)
    }
    final class Handle: NSView, NSDraggingSource {
        var begin: (() -> String)?
        var end: (() -> Void)?
        private var handleImage: NSImage? {
            NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        }
        override func draw(_ dirtyRect: NSRect) {
            handleImage?.draw(in: NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 12) / 2, width: 14, height: 12))
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let payload = begin?() else { return }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(payload, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let image = handleImage ?? NSImage(size: bounds.size)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { end?() }
    }
}
