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

    /// Native NSSegmentedControl behaviour (select-one tracking, VoiceOver, arrow keys, target/action) with a
    /// layer-composited look. The pill and its label mask move with a Core Animation spring, so the render server
    /// animates them and a busy main thread cannot stall the slide; nothing is redrawn per frame.
    @MainActor final class FullWidthControl: NSSegmentedControl {
        override class var cellClass: AnyClass? {
            get { CapsuleSegmentedCell.self }
            set {}
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: max(super.intrinsicContentSize.height, CapsuleSegmentedCell.height))
        }

        private let trackLayer = CALayer()
        private let labelsLayer = CALayer()      // labels in the primary text colour, under the pill
        private let pillLayer = CALayer()
        private let pillLabelsLayer = CALayer()  // the same labels in white, visible only through the pill mask
        private let pillMask = CALayer()
        private var labelLayers: [CATextLayer] = []
        private var pillLabelLayers: [CATextLayer] = []
        private var laidOutSize: NSSize = .zero
        private var laidOutLabels: [String] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureLayers()
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private func configureLayers() {
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            focusRingType = .none
            guard let root = layer else { return }
            root.masksToBounds = false
            for sublayer in [trackLayer, labelsLayer, pillLayer, pillLabelsLayer] {
                sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
                root.addSublayer(sublayer)
            }
            pillMask.backgroundColor = NSColor.black.cgColor
            pillMask.actions = pillLayer.actions
            pillLabelsLayer.mask = pillMask
        }

        override var selectedSegment: Int {
            didSet { if selectedSegment != oldValue { updateGeometry(animated: window != nil) } }
        }
        override func setLabel(_ label: String, forSegment segment: Int) {
            super.setLabel(label, forSegment: segment)
            needsLayout = true
        }
        override var isEnabled: Bool {
            didSet { if isEnabled != oldValue { refreshColors() } }
        }
        // A press selects the segment under the pointer on release (the same segment must be under the press and the
        // release). No modal tracking loop: the pill slide is a layer animation and needs nothing from the pointer.
        private var pressedSegment: Int?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func segment(at event: NSEvent) -> Int? {
            guard segmentCount > 0, bounds.width > 0 else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return nil }
            return min(segmentCount - 1, max(0, Int(point.x / (bounds.width / CGFloat(segmentCount)))))
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            pressedSegment = segment(at: event)
        }
        override func mouseUp(with event: NSEvent) {
            defer { pressedSegment = nil }
            guard isEnabled, let pressed = pressedSegment, segment(at: event) == pressed else { return }
            if selectedSegment != pressed { selectedSegment = pressed }
            _ = sendAction(action, to: target)
        }

        /// Native selection (arrow keys, VoiceOver) goes through the cell and does not call the control's
        /// property setter, so the pill is moved here, just before the action is delivered.
        override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
            updateGeometry(animated: window != nil)
            return super.sendAction(action, to: target)
        }
        override func layout() {
            super.layout()
            updateGeometry(animated: false)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshColors()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2
            for layer in [trackLayer, labelsLayer, pillLayer, pillLabelsLayer, pillMask] { layer.contentsScale = scale }
            for layer in labelLayers + pillLabelLayers { layer.contentsScale = scale }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeBackingProperties()
            refreshColors()
            updateGeometry(animated: false)
            NotificationCenter.default.removeObserver(self, name: NSColor.systemColorsDidChangeNotification, object: nil)
            if window != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(accentChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
            }
        }
        @objc private func accentChanged() { refreshColors() }

        private var segmentWidth: CGFloat { segmentCount > 0 ? bounds.width / CGFloat(segmentCount) : 0 }
        private func pillFrame(forIndex index: Int) -> CGRect {
            CGRect(x: CGFloat(index) * segmentWidth + 2, y: 2, width: max(0, segmentWidth - 4), height: max(0, bounds.height - 4))
        }

        private func refreshColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
                pillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
                pillLayer.opacity = isEnabled ? 1 : 0.45
                let primary = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
                for layer in labelLayers { layer.foregroundColor = primary.cgColor }
                for layer in pillLabelLayers { layer.foregroundColor = NSColor.white.cgColor }
            }
        }

        private func rebuildLabelLayersIfNeeded() {
            let labels = (0..<segmentCount).map { label(forSegment: $0) ?? "" }
            guard labels != laidOutLabels || labelLayers.count != segmentCount else { return }
            laidOutLabels = labels
            for layer in labelLayers + pillLabelLayers { layer.removeFromSuperlayer() }
            func make(_ text: String) -> CATextLayer {
                let layer = CATextLayer()
                layer.string = text
                layer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                layer.fontSize = 13
                layer.alignmentMode = .center
                layer.truncationMode = .end
                layer.isWrapped = false
                layer.contentsScale = window?.backingScaleFactor ?? 2
                layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "foregroundColor": NSNull()]
                return layer
            }
            labelLayers = labels.map(make)
            pillLabelLayers = labels.map(make)
            for layer in labelLayers { labelsLayer.addSublayer(layer) }
            for layer in pillLabelLayers { pillLabelsLayer.addSublayer(layer) }
            refreshColors()
        }

        private var lastPillIndex: Int?
        /// True while the pill's slide runs as a Core Animation spring (render-server side).
        var isPillSliding: Bool { pillLayer.animation(forKey: "slide") != nil }
        var pillTargetFrame: CGRect { pillLayer.frame }

        private func updateGeometry(animated: Bool) {
            guard segmentCount > 0, bounds.width > 0 else { return }
            let sizeChanged = laidOutSize != bounds.size
            rebuildLabelLayersIfNeeded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [trackLayer, labelsLayer, pillLabelsLayer] { layer.frame = bounds }
            trackLayer.cornerRadius = bounds.height / 2
            let lineHeight = ceil(NSFont.systemFont(ofSize: 13, weight: .medium).boundingRectForFont.height)
            for index in 0..<segmentCount {
                let frame = CGRect(x: CGFloat(index) * segmentWidth + 4, y: (bounds.height - lineHeight) / 2 + 1,
                                   width: max(0, segmentWidth - 8), height: lineHeight)
                labelLayers[index].frame = frame
                pillLabelLayers[index].frame = frame
            }
            let target = max(0, selectedSegment)
            let rect = pillFrame(forIndex: target)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let shouldAnimate = animated && !reduceMotion && !sizeChanged && lastPillIndex != nil && lastPillIndex != target
            let fromX = pillLayer.presentation()?.position.x
            for layer in [pillLayer, pillMask] {
                layer.bounds = CGRect(origin: .zero, size: rect.size)
                layer.cornerRadius = rect.height / 2
                layer.position = CGPoint(x: rect.midX, y: rect.midY)
            }
            CATransaction.commit()
            if shouldAnimate, let fromX {
                // Retargets from the on-screen position, so an interrupted slide continues instead of jumping.
                for layer in [pillLayer, pillMask] {
                    let spring = CASpringAnimation(perceptualDuration: 0.32, bounce: 0)
                    spring.keyPath = "position.x"
                    spring.fromValue = fromX
                    spring.toValue = rect.midX
                    spring.duration = spring.settlingDuration
                    layer.add(spring, forKey: "slide")
                }
            } else if !shouldAnimate && (sizeChanged || lastPillIndex != target) {
                pillLayer.removeAnimation(forKey: "slide"); pillMask.removeAnimation(forKey: "slide")
            }
            lastPillIndex = target
            laidOutSize = bounds.size
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

/// The cell keeps AppKit's select-one tracking, accessibility and keyboard handling; the look is composited from
/// layers by `FullWidthControl`, so the cell itself draws nothing.
final class CapsuleSegmentedCell: NSSegmentedCell {
    static let height: CGFloat = 30
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {}
    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {}
}
