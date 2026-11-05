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
        // The capsule pill is the selection cue; the system focus ring around the whole control looked like a stray frame.
        control.focusRingType = .none
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
        override class var cellClass: AnyClass? {
            get { CapsuleSegmentedCell.self }
            set {}
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: max(super.intrinsicContentSize.height, CapsuleSegmentedCell.height))
        }

        // The selection pill is a spring-driven fractional segment index (read by CapsuleSegmentedCell). A press or
        // drag moves the pill with the pointer and stretches it slightly; release snaps to the nearest segment.
        private(set) var indicator: CGFloat = 0
        private(set) var isDragging = false
        private var goal: CGFloat = 0
        private var velocity: CGFloat = 0
        private var link: CADisplayLink?

        override var selectedSegment: Int {
            didSet { if !isDragging { moveIndicator(to: CGFloat(max(0, selectedSegment)), animated: window != nil) } }
        }

        private func fraction(for event: NSEvent) -> CGFloat {
            guard segmentCount > 0, bounds.width > 0 else { return 0 }
            let point = convert(event.locationInWindow, from: nil)
            return point.x / (bounds.width / CGFloat(segmentCount)) - 0.5
        }
        private func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0), CGFloat(max(0, segmentCount - 1))) }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, segmentCount > 0 else { return }
            isDragging = true
            moveIndicator(to: clamped(fraction(for: event)), animated: true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }
            moveIndicator(to: clamped(fraction(for: event)), animated: true)
        }
        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            isDragging = false
            let index = Int(clamped(fraction(for: event)).rounded())
            if selectedSegment != index {
                selectedSegment = index
                sendAction(action, to: self.target)
            } else {
                moveIndicator(to: CGFloat(index), animated: true)
            }
            needsDisplay = true
        }

        private func moveIndicator(to value: CGFloat, animated: Bool) {
            goal = value
            if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                indicator = value; velocity = 0; needsDisplay = true; link?.invalidate(); link = nil
                return
            }
            if link == nil {
                let created = displayLink(target: self, selector: #selector(step(_:)))
                created.add(to: .main, forMode: .common)
                link = created
            }
        }
        @objc private func step(_ link: CADisplayLink) {
            let dt = CGFloat(max(1.0 / 240.0, min(1.0 / 20.0, link.targetTimestamp - link.timestamp)))
            let stiffness: CGFloat = 520, damping = 2 * stiffness.squareRoot() * 0.72
            velocity += (stiffness * (goal - indicator) - damping * velocity) * dt
            indicator += velocity * dt
            needsDisplay = true
            if abs(goal - indicator) < 0.002 && abs(velocity) < 0.03 {
                indicator = goal; velocity = 0; link.invalidate(); self.link = nil
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { link?.invalidate(); link = nil }
            else if !isDragging && link == nil { indicator = CGFloat(max(0, selectedSegment)); goal = indicator }
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

/// macOS 26/27 look for the equal-width tabs: a translucent capsule track and one neutral capsule behind the
/// selected segment, without separators. Only drawing changes; selection, keyboard and accessibility stay AppKit's.
final class CapsuleSegmentedCell: NSSegmentedCell {
    static let height: CGFloat = 30
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let track = NSBezierPath(roundedRect: cellFrame, xRadius: cellFrame.height / 2, yRadius: cellFrame.height / 2)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        track.fill()
        guard segmentCount > 0 else { return }
        let width = cellFrame.width / CGFloat(segmentCount)
        let control = controlView as? FullWidthSegmentedTabs.FullWidthControl
        let position = control?.indicator ?? CGFloat(max(0, selectedSegment))
        let dragging = control?.isDragging == true
        // Pill: inset 2 pt inside the track (concentric corners). While dragged it grows a little and lifts.
        let grow: CGFloat = dragging ? 3 : 0
        let pillWidth = width - 4 + grow * 2
        let pillRect = NSRect(x: cellFrame.minX + (position + 0.5) * width - pillWidth / 2, y: cellFrame.minY + 2 - grow / 2,
                              width: pillWidth, height: cellFrame.height - 4 + grow)
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        if dragging {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        // The system accent, not the selected-content colour: that one turns grey in a non-key panel.
        NSColor.controlAccentColor.setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        if dragging {
            // Liquid-glass sheen: a soft top-down highlight clipped to the lifted pill.
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])?
                .draw(in: pillRect, angle: 270)
            NSGraphicsContext.restoreGraphicsState()
        }
        let selectedIndex = Int(position.rounded())
        for index in 0..<segmentCount {
            let frame = NSRect(x: cellFrame.minX + CGFloat(index) * width, y: cellFrame.minY, width: width, height: cellFrame.height)
            drawSegment(index, inFrame: frame, with: controlView, selectedOverride: index == selectedIndex)
        }
    }
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        drawSegment(segment, inFrame: frame, with: controlView, selectedOverride: isSelected(forSegment: segment))
    }
    private func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView, selectedOverride selected: Bool) {
        let label = (self.label(forSegment: segment) ?? "") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
            .foregroundColor: (controlView as? NSControl)?.isEnabled == false ? NSColor.disabledControlTextColor
                : (selected ? NSColor.white : NSColor.labelColor),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
    }
}
