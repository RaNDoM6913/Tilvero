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
                controls.frame(width: 320)
                preview.frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 20) { controls; preview.frame(maxWidth: 340) }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Live preview")).font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(AppIdentity.displayName).font(.headline); Spacer(); Image(systemName: "gearshape") }
                HStack {
                    Text(model.chargeText).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Image(nsImage: NativeBatteryStatusImage.make(level: ReadingPresentation.validLevel(model.snapshot.chargePercent.value), style: .iconOnly,
                        externalPower: model.snapshot.isExternalPower.value == true))
                        .resizable().frame(width: 44, height: 28)
                }
                Text(model.chargingStateText).font(.caption).foregroundStyle(.secondary)
                Divider()
                // Passive metrics have no task, navigation or mutation action.
                OverviewMetricsPanel(model: model)
                Divider()
                Label(L10n.text("History & reports…"), systemImage: "chart.bar.xaxis").font(.callout)
            }.padding(16).background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.35)))
                .allowsHitTesting(false).help(L10n.text("Preview only"))
        }
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
