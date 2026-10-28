import AppKit
import SwiftUI
import Combine

/// Keep one hosting controller and selected tab while resizing. Activation and
/// dismissal stay with the app delegate; SwiftUI reports bounded geometry.
@MainActor
final class QuickPanelHostingController: NSHostingController<QuickPanel> {
    var onSizeChange: ((NSSize) -> Void)?
    private var modelSubscription: AnyCancellable?
    private var lastReportedSize: NSSize?

    init(model: TilveroModel, maximumHeight: CGFloat, section: QuickPanelSection = .overview) {
        super.init(rootView: QuickPanel(model: model, maximumHeight: maximumHeight, section: section))
        sizingOptions = [.preferredContentSize]
        rootView.onSizeChange = { [weak self] size in self?.contentSizeChanged(size) }
        // Published changes arrive before the new value. Measure on the next
        // main-actor turn, after SwiftUI can consume the updated model.
        modelSubscription = model.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.resizeToFit() }
        }
        resizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:maximumHeight:)") }

    func updateMaximumHeight(_ height: CGFloat) {
        rootView.maximumHeight = max(1, height)
        resizeToFit()
    }

    func resizeToFit() {
        contentSizeChanged(sizeThatFits(in: NSSize(width: 360, height: rootView.maximumHeight)))
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.height.isFinite, size.height > 0 else { return }
        let bounded = NSSize(width: 360, height: min(ceil(size.height), rootView.maximumHeight))
        if preferredContentSize != bounded { preferredContentSize = bounded }
        guard lastReportedSize != bounded else { return }
        lastReportedSize = bounded
        onSizeChange?(bounded)
    }
}
