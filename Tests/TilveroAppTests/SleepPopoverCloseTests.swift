import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class SleepPopoverCloseTests: XCTestCase {
    func testControlledRebindingAndDetachPreserveCompletionThroughActualNativeClose() async throws {
        let state = try await closeWithRebinding(.callback)
        XCTAssertTrue(state.retainedAfterDetach, "The pending native close owns the detached observer until completion.")
        XCTAssertEqual(state.originalDispatches, 1, "Rebinding while closing must not replace the frozen completion.")
        XCTAssertEqual(state.reboundDispatches, 0)
    }

    func testControlledOwnerOrPresentationReplacementInvalidatesClosingCompletion() async throws {
        for replacement in [CloseReplacement.owner, .presentation] {
            let state = try await closeWithRebinding(replacement)
            XCTAssertTrue(state.retainedAfterDetach)
            XCTAssertEqual(state.originalDispatches, 0, "An obsolete owner/presentation cannot receive the old completion.")
            XCTAssertEqual(state.reboundDispatches, 0, "An old close cannot invoke the replacement owner's completion.")
        }
    }

    private func closeWithRebinding(_ replacement: CloseReplacement) async throws -> CloseRebindingState {
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = anchor; window.orderFront(nil)
        let popover = NSPopover()
        popover.animates = false
        let state = CloseRebindingState(popover: popover)
        let identity = PopoverCloseIdentity(owner: ObjectIdentifier(window), presentation: UUID())
        switch replacement {
        case .callback: break
        case .owner: state.replacementIdentity = .init(owner: ObjectIdentifier(anchor), presentation: identity.presentation)
        case .presentation: state.replacementIdentity = .init(owner: identity.owner, presentation: UUID())
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 236))
        do {
            let probe = PopoverCloseView(frame: container.bounds)
            probe.identity = identity
            probe.onClose = { state.originalDispatches += 1 }
            state.probe = probe; state.weakProbe = probe
            container.addSubview(probe)
        }
        let controller = NSViewController(); controller.view = container
        popover.contentViewController = controller
        defer { popover.close(); window.orderOut(nil) }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        XCTAssertTrue(popover.isShown)
        XCTAssertNotNil(state.weakProbe?.window)
        // Control the interleaving at the public notification boundary. AppKit's
        // animated display link can stall in this XCTest process. The final
        // did-close below still comes from the actual nonanimated native close.
        NotificationCenter.default.post(name: NSPopover.willCloseNotification, object: popover)
        if let replacement = state.replacementIdentity { state.probe?.identity = replacement }
        state.probe?.onClose = { state.reboundDispatches += 1 }
        state.probe?.removeFromSuperview()
        state.probe = nil
        state.retainedAfterDetach = state.weakProbe != nil
        // The real close emits will-close again, then the actual did-close.
        // No layout, synthetic input or host update is injected after this call.
        popover.close()
        try await wait { state.didClose && state.weakProbe == nil }
        return state
    }

    func testActualNativeCloseDeliversOnceAfterDismissalAndIgnoresAnotherPopover() async throws {
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = anchor
        window.orderFront(nil)
        let owned = NSPopover(), other = NSPopover()
        owned.animates = false; other.animates = false
        defer { owned.close(); other.close(); window.orderOut(nil) }
        var closeCount = 0
        var wasShownAtDispatch: Bool?
        let identity = PopoverCloseIdentity(owner: ObjectIdentifier(window), presentation: UUID())
        let host = NSHostingController(rootView: SleepWheelPicker(mode: .duration, initialMinutes: 31,
            initialDate: Date().addingTimeInterval(1860), onCommit: { _ in }, onCancel: {})
            .background {
                PopoverCloseObserver(identity: identity) {
                    closeCount += 1
                    wasShownAtDispatch = owned.isShown
                }.allowsHitTesting(false)
            })
        owned.contentViewController = host
        other.contentViewController = NSHostingController(rootView: Text("Unrelated popup"))
        owned.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        host.view.layoutSubtreeIfNeeded()
        other.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        other.close()
        XCTAssertEqual(closeCount, 0)
        XCTAssertTrue(owned.isShown)
        // No layout, synthetic input or host state change after the real close.
        owned.close()
        try await wait { closeCount == 1 }
        XCTAssertEqual(wasShownAtDispatch, false)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: owned)
        XCTAssertEqual(closeCount, 1, "A duplicate close notification cannot dispatch a second commit.")
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The actual native close did not dispatch without another host event.")
    }
}
private enum CloseReplacement { case callback, owner, presentation }

@MainActor private final class CloseRebindingState: NSObject {
    var probe: PopoverCloseView?
    weak var weakProbe: PopoverCloseView?
    var replacementIdentity: PopoverCloseIdentity?
    var originalDispatches = 0, reboundDispatches = 0
    var didClose = false
    var retainedAfterDetach = false
    init(popover: NSPopover) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(closed(_:)), name: NSPopover.didCloseNotification, object: popover)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func closed(_ note: Notification) { didClose = true }
}
