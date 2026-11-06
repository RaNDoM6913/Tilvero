// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

struct PopoverCloseIdentity: Equatable {
    let owner: ObjectIdentifier
    let presentation: UUID
}

/// SwiftUI's content disappearance can wait for an unrelated host update.
/// Match the owning native popover while its window is still attached, then
/// report AppKit's actual completed close, after the offscreen animation.
struct PopoverCloseObserver: NSViewRepresentable {
    let identity: PopoverCloseIdentity
    let onClose: () -> Void

    func makeNSView(context: Context) -> PopoverCloseView {
        PopoverCloseView(frame: .zero)
    }
    func updateNSView(_ view: PopoverCloseView, context: Context) {
        view.identity = identity
        view.onClose = onClose
    }
}

@MainActor final class PopoverCloseView: NSView {
    var onClose: () -> Void = {}
    var identity: PopoverCloseIdentity? {
        didSet {
            if identity != oldValue { closingCompletion = nil }
        }
    }
    private weak var closingPopover: NSPopover?
    private var closingCompletion: (() -> Void)?
    // SwiftUI may detach its content during the closing animation. The matched
    // will/did-close pair owns this short lifetime, independent of that content.
    private var retainedWhileClosing: PopoverCloseView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)),
            name: NSPopover.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didClose(_:)),
            name: NSPopover.didCloseNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func willClose(_ notification: Notification) {
        guard closingPopover == nil, let popover = notification.object as? NSPopover, let window,
              popover.contentViewController?.view.window === window else { return }
        closingPopover = popover
        closingCompletion = onClose
        retainedWhileClosing = self
    }

    @objc private func didClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === closingPopover else { return }
        let completion = closingCompletion
        closingCompletion = nil
        closingPopover = nil
        defer { retainedWhileClosing = nil }
        completion?()
    }
}
