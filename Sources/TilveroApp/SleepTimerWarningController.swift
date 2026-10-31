import AppKit
import SwiftUI
import Combine
import PowerCore

/// One quiet, nonactivating warning; no notification permission, sound or global keys.
@MainActor final class SleepTimerWarningController {
    private let service: SleepTimerService
    private var subscription: AnyCancellable?
    private var panel: NSPanel?
    private var displayObserver: NSObjectProtocol?
    private var announcementKey: String?
    private let openDetails: @MainActor () -> Void
    init(service: SleepTimerService, openDetails: @escaping @MainActor () -> Void) {
        self.service = service; self.openDetails = openDetails
        subscription = Publishers.Merge(service.$phase.map { _ in () }, service.$needsHoldRelease.map { _ in () })
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.update() } }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPresentation() }
        }
    }
    func refreshPresentation() { if panel?.isVisible == true { update(announce: false) } }
    private func update(announce: Bool = true) {
        guard service.isWarning || service.needsHoldRelease || [.failed, .unconfirmed, .expired].contains(service.phase)
                || service.message == "Sleep timer cancelled because safe preparation could not be confirmed." else {
            panel?.orderOut(nil); announcementKey = nil; return
        }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            self.panel = panel
        }
        guard let panel else { return }
        let screen = targetScreen
        let width = min(440, max(1, (screen?.visibleFrame.width ?? 480) - 40))
        let host = NSHostingController(rootView: SleepTimerWarningContent(service: service, openDetails: { [weak self] in
            self?.openDetails(); self?.panel?.orderOut(nil)
        }, dismiss: { [weak self] in self?.panel?.orderOut(nil) })
            .frame(width: width).environment(\.locale, L10n.locale))
        panel.contentViewController = host
        panel.setContentSize(host.sizeThatFits(in: NSSize(width: width, height: 1000)))
        position(on: screen); panel.orderFrontRegardless()
        let key = "\(service.sessionID?.uuidString ?? "")/\(service.phase.rawValue)/\(service.needsHoldRelease)"
        if announce && announcementKey != key { NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: L10n.text(service.isWarning ? "Your Mac will sleep in one minute." : "The sleep timer needs attention."),
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]); announcementKey = key }
    }
    private func position(on screen: NSScreen?) {
        guard let panel else { return }
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - panel.frame.height - 20))
    }
    private var targetScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }
    func close() { panel?.orderOut(nil); subscription = nil }
    isolated deinit { if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) } }
}

@MainActor struct SleepTimerWarningContent: View {
    @ObservedObject var service: SleepTimerService
    var openDetails: @MainActor () -> Void
    var dismiss: @MainActor () -> Void = {}
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 8) {
                if service.isWarning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(L10n.text("Sleep in") + " " + KeepAwakePresentation.countdown(service.remainingSeconds))
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    }
                    Text(L10n.text("Tilvero’s sleep timer is ending. Add time if you’re still watching."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("+15 " + L10n.text("min")) { try? service.extend() }.buttonStyle(SleepTimerPrimaryStyle()).disabled(!service.canExtend)
                        Button(L10n.text("Cancel sleep")) { service.cancel() }
                    }.controlSize(.large)
                } else {
                    Text(L10n.text("The sleep timer needs attention.")).font(.system(size: 16, weight: .semibold))
                    if let message = service.message { Text(L10n.text(message)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if service.needsHoldRelease { Button(L10n.text("Release timer hold")) { service.cancel() } }
                    HStack {
                        Button(L10n.text("Open Tilvero")) { openDetails() }
                        Button(L10n.text("Dismiss")) { dismiss() }
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
    }
}
