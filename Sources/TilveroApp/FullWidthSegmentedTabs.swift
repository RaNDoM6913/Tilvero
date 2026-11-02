import AppKit
import SwiftUI

/// The selected Lab control, shared by production and the inspector wrappers.
/// Giving AppKit the proposed width prevents intrinsic-width tabs inside a wider frame.
@MainActor struct FullWidthSegmentedTabs: NSViewRepresentable {
    @Binding var selection: Int
    let labels: [String]
    var isEnabled = true
    @Environment(\.isEnabled) private var environmentIsEnabled
    let accessibilityID: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> FullWidthControl {
        let control = FullWidthControl(frame: .zero)
        control.segmentCount = labels.count
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        control.setAccessibilityIdentifier(accessibilityID)
        return control
    }

    func updateNSView(_ control: FullWidthControl, context: Context) {
        context.coordinator.selection = $selection
        if control.segmentCount != labels.count { control.segmentCount = labels.count }
        for (index, label) in labels.enumerated() {
            if control.label(forSegment: index) != label { control.setLabel(label, forSegment: index) }
            control.setWidth(0, forSegment: index)
        }
        let selected = labels.indices.contains(selection) ? selection : -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
        control.isEnabled = isEnabled && environmentIsEnabled
        control.setAccessibilityIdentifier(accessibilityID)
        control.setAccessibilityLabel(accessibilityLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullWidthControl, context: Context) -> CGSize? {
        let naturalHeight = nsView.intrinsicContentSize.height
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320
        return CGSize(width: width, height: naturalHeight)
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard sender.isEnabled, sender.selectedSegment >= 0, sender.selectedSegment < sender.segmentCount else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }

    /// Only sizing changes. AppKit retains select-one accessibility, focus,
    /// keyboard navigation, selection rendering and target/action behavior.
    @MainActor final class FullWidthControl: NSSegmentedControl {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
    }
}

@MainActor struct QuickPanelTabs: View {
    @Binding var selection: QuickPanelSection

    private var selectedIndex: Binding<Int> {
        Binding(get: { QuickPanelSection.allCases.firstIndex(of: selection) ?? 0 }, set: { index in
            guard QuickPanelSection.allCases.indices.contains(index) else { return }
            selection = QuickPanelSection.allCases[index]
        })
    }

    var body: some View {
        FullWidthSegmentedTabs(selection: selectedIndex, labels: QuickPanelSection.allCases.map(\.title),
            accessibilityID: "quick.tabs", accessibilityLabel: L10n.text("Battery menu"))
    }
}

@MainActor struct CompactSleepTabs: View {
    @Binding var selection: SleepPage
    private let pages: [SleepPage] = [.timer, .awake]

    private var selectedIndex: Binding<Int> {
        Binding(get: { pages.firstIndex(of: selection) ?? 0 }, set: { index in
            guard pages.indices.contains(index) else { return }
            selection = pages[index]
        })
    }

    var body: some View {
        FullWidthSegmentedTabs(selection: selectedIndex, labels: pages.map(\.title),
            accessibilityID: "sleep.tabs", accessibilityLabel: L10n.text("Sleep"))
    }
}
