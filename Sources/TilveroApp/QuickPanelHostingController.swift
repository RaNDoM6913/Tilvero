// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import Combine

#if TILVERO_LAB_STUDIO
@MainActor struct StudioQuickPanelRoot: View {
    var model: TilveroModel
    var maximumHeight: CGFloat
    var section: QuickPanelSection
    var onSizeChange: ((CGSize) -> Void)?
    var studio: LabStudioState?
    @ViewBuilder var body: some View {
        if let studio {
            QuickPanel(model: model, maximumHeight: maximumHeight, onSizeChange: onSizeChange, section: section)
                .studioRoot(studio, scope: "quick", registry: "popover")
        } else {
            QuickPanel(model: model, maximumHeight: maximumHeight, onSizeChange: onSizeChange, section: section)
        }
    }
}
typealias QuickPanelHostedRoot = StudioQuickPanelRoot
#else
typealias QuickPanelHostedRoot = QuickPanel
#endif

/// Keep one hosting controller and selected tab while resizing. Activation and
/// dismissal stay with the app delegate; SwiftUI reports bounded geometry.
@MainActor
final class QuickPanelHostingController: NSHostingController<QuickPanelHostedRoot> {
    var onSizeChange: ((NSSize) -> Void)?
    private var modelSubscription: AnyCancellable?
    private var lastReportedSize: NSSize?
    private var fitScheduled = false
    private var lastGeometryReport: CFAbsoluteTime = 0

    init(model: TilveroModel, maximumHeight: CGFloat, section: QuickPanelSection = .overview) {
        super.init(rootView: QuickPanelHostedRoot(model: model, maximumHeight: maximumHeight, section: section))
        sizingOptions = []   // sizes are reported explicitly (geometry); AppKit must not resize the popover itself
        rootView.onSizeChange = { [weak self] size in self?.contentSizeChanged(size) }
        // Published changes arrive before the new value. Measure on the next
        // main-actor turn, after SwiftUI can consume the updated model.
        // Safety net only: SwiftUI reports geometry changes itself. Coalesce the published bursts into one
        // measurement per turn, and skip it while geometry reports are already arriving (an animated resize).
        modelSubscription = model.objectWillChange.sink { [weak self] in
            guard let self, !self.fitScheduled else { return }
            self.fitScheduled = true
            Task { @MainActor [weak self] in self?.runScheduledFit() }
        }
        resizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:maximumHeight:)") }

    #if TILVERO_LAB_STUDIO
    func attachStudio(_ studio: LabStudioState) {
        rootView.studio = studio
        resizeToFit()
    }
    #endif

    func updateMaximumHeight(_ height: CGFloat) {
        rootView.maximumHeight = max(1, height)
        resizeToFit()
    }

    /// While geometry reports are arriving (an animated resize) the measurement waits for them to stop, then still
    /// runs once, so a published change SwiftUI never reports cannot leave the panel at a stale height.
    private func runScheduledFit() {
        let quiet = CFAbsoluteTimeGetCurrent() - lastGeometryReport
        if quiet > 0.5 { fitScheduled = false; resizeToFit(); return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((0.5 - quiet) * 1000) + 30))
            self?.runScheduledFit()
        }
    }

    func resizeToFit() {
        contentSizeChanged(sizeThatFits(in: NSSize(width: 360, height: rootView.maximumHeight)))
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.height.isFinite, size.height > 0 else { return }
        lastGeometryReport = CFAbsoluteTimeGetCurrent()
        let bounded = NSSize(width: 360, height: min(ceil(size.height), rootView.maximumHeight))
        // The owner applies the size first (without AppKit's window animation); the popover then already has it
        // when the preferred size is published.
        if lastReportedSize != bounded {
            lastReportedSize = bounded
            onSizeChange?(bounded)
        }
        if preferredContentSize != bounded { preferredContentSize = bounded }
    }
}

/// Resizes a shown popover without AppKit's own window animation. That animation runs a nested run loop inside the
/// SwiftUI update that reported the new size and follows a different curve than the content; the SwiftUI page
/// animation already produces every intermediate height, so each one is applied immediately.
@MainActor enum QuickPanelPopoverSizing {
    static func apply(_ size: NSSize, to popover: NSPopover) {
        guard popover.contentSize != size else { return }
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = size
        popover.animates = animates
    }
}
