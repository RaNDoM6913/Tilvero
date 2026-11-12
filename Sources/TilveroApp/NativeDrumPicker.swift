// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// An isolated draft-value wheel. Its parent owns form submission and cancellation.
struct NativeDrumPicker: View {
    enum Style {
        case regular, compact, unified

        fileprivate var size: NSSize {
            switch self {
            case .regular: NSSize(width: 130, height: 210)
            case .compact, .unified: NSSize(width: 100, height: 126)
            }
        }
        fileprivate var numberFontSize: CGFloat { self == .regular ? 27 : 24 }
    }

    @Binding var selection: Int
    let range: ClosedRange<Int>
    let unit: String
    let accessibilityName: String
    var style: Style = .regular
    /// Column width; nil keeps the style's own (100 pt for the compact and unified wheels).
    var width: CGFloat? = nil
    /// A cyclic wheel: after the last value it continues with the first (and the other way round).
    var wraps = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        DrumSurface(selection: $selection, range: range, unit: unit, name: accessibilityName, style: style, wraps: wraps,
                    onSubmit: onSubmit, onCancel: onCancel)
            .frame(width: width ?? style.size.width, height: style.size.height)
    }
}

private struct DrumSurface: NSViewRepresentable {
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let unit: String
    let name: String
    let style: NativeDrumPicker.Style
    let wraps: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> DrumHost {
        let host = DrumHost(frame: NSRect(origin: .zero, size: style.size))
        updateNSView(host, context: context)
        return host
    }

    func updateNSView(_ host: DrumHost, context: Context) {
        host.style = style
        host.wheel.configure(value: selection, range: range, unit: unit, name: name,
                             numberFontSize: style.numberFontSize, showsUnit: style == .regular, wraps: wraps,
                             onSubmit: onSubmit, onCancel: onCancel) { selection = $0 }
    }

    static func dismantleNSView(_ host: DrumHost, coordinator: ()) {
        host.wheel.cancelPendingSnap()
    }
}

@MainActor
private final class DrumHost: NSView {
    let wheel = DrumScrollView(frame: .zero)
    var style: NativeDrumPicker.Style = .regular { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wheel.host = self
        addSubview(wheel)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        wheel.frame = bounds.insetBy(dx: 0, dy: 5)
        wheel.layoutSubtreeIfNeeded()
        wheel.updateDocumentGeometry()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The unified (capsule) wheels draw no focus block: clicking a wheel must not highlight it.
        // Keyboard input (arrows, Home/End, Return, Escape) still works through the first responder.
        if style == .unified { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        outline.fill()
        let band = NSRect(x: 5, y: (bounds.height - DrumScrollView.rowHeight) / 2,
                          width: max(0, bounds.width - 10), height: DrumScrollView.rowHeight)
        let bandPath = NSBezierPath(roundedRect: band, xRadius: 9, yRadius: 9)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        bandPath.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.24).setStroke()
        bandPath.lineWidth = 1
        bandPath.stroke()
        let focused = window?.firstResponder === wheel
        (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = focused ? 2 : 1
        outline.stroke()
    }
}

/// Both clip and document have top-origin coordinates. For a 200pt viewport,
/// 40pt rows have 80pt of actual blank document at each end. Row i has center
/// 100+i*40, so centering it means setting clip bounds origin to exactly i*40.
@MainActor
private final class DrumScrollView: NSScrollView {
    static let rowHeight: CGFloat = 40
    weak var host: DrumHost?
    private let rows = DrumDocument(frame: .zero)
    private var allowedRange = 0...0
    private var selectedValue = 0
    /// Cyclic wheels scroll a virtual range of `copies` repeats of the logical values; the selection is
    /// silently moved back to the middle repeat after each settle, so the wheel never ends.
    private var wraps = false
    private var span = 1
    private var logicalLower = 0
    private static let copies = 21
    private func display(_ virtual: Int) -> Int { wraps ? logicalLower + ((virtual % span) + span) % span : virtual }
    private var unit = ""
    private var numberFontSize: CGFloat = 27
    private var showsUnit = true
    private var onSelectionChanged: ((Int) -> Void)?
    private var onSubmit: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var isConfigured = false
    private var isUpdatingGeometry = false
    private var isUserScrolling = false
    private var lastViewportSize = NSSize.zero
    private var pointerOrigin: (windowY: CGFloat, offset: CGFloat, clickedValue: Int)?
    private var pointerMoved = false
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        lineScroll = Self.rowHeight
        let clip = DrumClipView(frame: .zero)
        clip.drawsBackground = false
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = NSEdgeInsetsZero
        contentView = clip
        rows.wheel = self
        documentView = rows
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }

    func configure(value: Int, range: ClosedRange<Int>, unit: String, name: String,
                   numberFontSize: CGFloat, showsUnit: Bool, wraps: Bool = false,
                   onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void,
                   onSelectionChanged: @escaping (Int) -> Void) {
        let nextValue: Int, changedRange: Bool, requiresCenter: Bool, effectiveRange: ClosedRange<Int>
        if wraps {
            let count = range.count
            effectiveRange = 0...(count * Self.copies - 1)
            let logical = min(max(value, range.lowerBound), range.upperBound)
            changedRange = allowedRange != effectiveRange || !self.wraps || logicalLower != range.lowerBound
            let keep = isConfigured && !changedRange && display(selectedValue) == logical
            nextValue = keep ? selectedValue : count * (Self.copies / 2) + (logical - range.lowerBound)
            requiresCenter = !keep
            self.span = count; self.logicalLower = range.lowerBound
        } else {
            effectiveRange = range
            nextValue = min(max(value, range.lowerBound), range.upperBound)
            changedRange = allowedRange != range || self.wraps
            requiresCenter = !isConfigured || changedRange || nextValue != selectedValue
        }
        self.wraps = wraps
        allowedRange = effectiveRange
        self.unit = unit
        self.numberFontSize = numberFontSize
        self.showsUnit = showsUnit
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onSelectionChanged = onSelectionChanged
        setAccessibilityLabel(name)
        selectedValue = nextValue
        isConfigured = true
        if changedRange { lastViewportSize = .zero }
        updateDocumentGeometry()
        if requiresCenter {
            cancelPendingSnap()
            isUserScrolling = false
            centerSelectedValue()
        }
        rows.needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateDocumentGeometry()
    }

    func updateDocumentGeometry() {
        guard isConfigured, !isUpdatingGeometry else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let padding = max(0, (viewport.height - Self.rowHeight) / 2)
        let documentSize = NSSize(width: viewport.width,
                                  height: CGFloat(allowedRange.count) * Self.rowHeight + 2 * padding)
        guard lastViewportSize != viewport || rows.frame.size != documentSize else { return }
        isUpdatingGeometry = true
        lastViewportSize = viewport
        rows.frame = NSRect(origin: .zero, size: documentSize)
        centerSelectedValue()
        isUpdatingGeometry = false
        rows.needsDisplay = true
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if isUserScrolling && !isUpdatingGeometry { mirrorVisibleCenter() }
        rows.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelPendingSnap()
        isUserScrolling = true
        super.scrollWheel(with: event)
        mirrorVisibleCenter()
        // Momentum stays native. Phase gestures schedule only at their end;
        // legacy mice receive one finite, per-control quiet timer.
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        let momentumEnded = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
        if momentumEnded || ended || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            perform(#selector(snapAfterWheel), with: nil, afterDelay: 0.14)
        }
    }

    func cancelPendingSnap() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(snapAfterWheel), object: nil)
    }

    @objc private func snapAfterWheel() {
        mirrorVisibleCenter()
        isUserScrolling = false
        centerSelectedValue()
        recenterIfNeeded()
    }

    /// Cyclic wheels: move to the identical row in the middle repeat once the selection nears either end.
    private func recenterIfNeeded() {
        guard wraps else { return }
        let target = span * (Self.copies / 2) + ((selectedValue % span) + span) % span
        guard abs(target - selectedValue) >= span * 2 else { return }
        selectedValue = target
        centerSelectedValue()
        rows.needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { host?.needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { host?.needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: step(-1)
        case 125: step(1)
        case 115: choose(wraps ? span * (Self.copies / 2) : allowedRange.lowerBound)
        case 119: choose(wraps ? span * (Self.copies / 2) + span - 1 : allowedRange.upperBound)
        case 36, 76: onSubmit?()
        case 53: onCancel?()
        default: nextResponder?.keyDown(with: event)
        }
    }

    func pointerDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelPendingSnap()
        isUserScrolling = false
        let location = rows.convert(event.locationInWindow, from: nil)
        let index = Int(floor((location.y - edgePadding) / Self.rowHeight))
        let value = min(max(allowedRange.lowerBound + index, allowedRange.lowerBound), allowedRange.upperBound)
        pointerOrigin = (event.locationInWindow.y, contentView.bounds.origin.y, value)
        pointerMoved = false
    }

    func pointerDragged(with event: NSEvent) {
        guard let origin = pointerOrigin else { return }
        let distance = event.locationInWindow.y - origin.windowY
        if abs(distance) > 3 { pointerMoved = true }
        guard pointerMoved else { return }
        scroll(to: origin.offset + distance)
        mirrorVisibleCenter()
    }

    func pointerUp(with event: NSEvent) {
        guard let origin = pointerOrigin else { return }
        pointerOrigin = nil
        if pointerMoved { mirrorVisibleCenter(); centerSelectedValue(); recenterIfNeeded() }
        else { choose(origin.clickedValue) }
        pointerMoved = false
    }

    private var edgePadding: CGFloat { max(0, (contentView.bounds.height - Self.rowHeight) / 2) }

    private func scroll(to offset: CGFloat) {
        let maximum = CGFloat(allowedRange.count - 1) * Self.rowHeight
        contentView.scroll(to: NSPoint(x: 0, y: min(max(offset, 0), maximum)))
        super.reflectScrolledClipView(contentView)
        rows.needsDisplay = true
    }

    private func centerSelectedValue() {
        scroll(to: CGFloat(selectedValue - allowedRange.lowerBound) * Self.rowHeight)
    }

    private func mirrorVisibleCenter() {
        guard isConfigured else { return }
        let index = Int((contentView.bounds.origin.y / Self.rowHeight).rounded())
        updateValue(min(max(allowedRange.lowerBound + index, allowedRange.lowerBound), allowedRange.upperBound))
    }

    private func updateValue(_ value: Int) {
        guard value != selectedValue else { return }
        selectedValue = value
        rows.needsDisplay = true
        onSelectionChanged?(display(value))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func choose(_ value: Int) {
        cancelPendingSnap()
        isUserScrolling = false
        updateValue(min(max(value, allowedRange.lowerBound), allowedRange.upperBound))
        // No synthetic animation; reduced-motion users retain native wheel input.
        centerSelectedValue()
        recenterIfNeeded()
    }

    private func step(_ delta: Int) {
        let (value, overflow) = selectedValue.addingReportingOverflow(delta)
        choose(overflow ? (delta > 0 ? allowedRange.upperBound : allowedRange.lowerBound) : value)
    }

    override func accessibilityValue() -> Any? { NSNumber(value: display(selectedValue)) }
    override func accessibilityValueDescription() -> String? { "\(display(selectedValue)) \(unit)" }
    override func accessibilityMinValue() -> Any? { NSNumber(value: wraps ? logicalLower : allowedRange.lowerBound) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: wraps ? logicalLower + span - 1 : allowedRange.upperBound) }
    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }

    func drawRows(in dirtyRect: NSRect) {
        guard isConfigured else { return }
        let first = max(0, Int(floor((dirtyRect.minY - edgePadding) / Self.rowHeight)))
        let last = min(allowedRange.count - 1, Int(ceil((dirtyRect.maxY - edgePadding) / Self.rowHeight)))
        guard first <= last else { return }
        for index in first...last {
            let value = allowedRange.lowerBound + index
            let distance = abs(value - selectedValue)
            let alpha: CGFloat = distance == 0 ? 1 : distance == 1 ? (showsUnit ? 0.70 : 0.42) : (showsUnit ? 0.35 : 0.2)
            let number = String(display(value)) as NSString
            let suffix = unit as NSString
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: numberFontSize, weight: distance == 0 ? (showsUnit ? .semibold : .regular) : (showsUnit ? .regular : .light))
            let unitFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: numberFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)
            ]
            let unitAttributes: [NSAttributedString.Key: Any] = [
                .font: unitFont, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha)
            ]
            let numberSize = number.size(withAttributes: numberAttributes)
            let unitSize = suffix.size(withAttributes: unitAttributes)
            let x = showsUnit ? (rows.bounds.width - numberSize.width - 4 - unitSize.width) / 2
                : (rows.bounds.width - numberSize.width) / 2
            let y = edgePadding + CGFloat(index) * Self.rowHeight + (Self.rowHeight - numberSize.height) / 2
            number.draw(at: NSPoint(x: x, y: y), withAttributes: numberAttributes)
            if showsUnit {
                suffix.draw(at: NSPoint(x: x + numberSize.width + 4, y: y + numberFont.ascender - unitFont.ascender),
                            withAttributes: unitAttributes)
            }
        }
    }
}

@MainActor
private final class DrumClipView: NSClipView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class DrumDocument: NSView {
    weak var wheel: DrumScrollView?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { wheel?.drawRows(in: dirtyRect) }
    override func mouseDown(with event: NSEvent) { wheel?.pointerDown(with: event) }
    override func mouseDragged(with event: NSEvent) { wheel?.pointerDragged(with: event) }
    override func mouseUp(with event: NSEvent) { wheel?.pointerUp(with: event) }
}
