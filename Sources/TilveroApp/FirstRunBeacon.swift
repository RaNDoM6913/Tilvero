// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import QuartzCore

/// A ring that pulses around the menu bar icon after the first run, while the quick menu is not open: the one visible
/// pointer to "this is where the app lives". Click-through, no activation, never in the way of the real icon.
@MainActor final class FirstRunBeacon {
    static let margin: CGFloat = 5
    /// Ring frame around the icon; testable without a window.
    static func ringFrame(around button: NSRect) -> NSRect { button.insetBy(dx: -margin, dy: -margin) }

    private(set) var window: NSWindow?
    var isShown: Bool { window?.isVisible == true }

    func show(around button: NSRect, reduceMotion: Bool) {
        let frame = Self.ringFrame(around: button)
        let panel = window ?? makeWindow()
        window = panel
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        if let layer = panel.contentView?.layer { configure(layer, size: frame.size, reduceMotion: reduceMotion) }
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.contentView?.layer?.removeAllAnimations()
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private func configure(_ layer: CALayer, size: NSSize, reduceMotion: Bool) {
        layer.removeAllAnimations()
        layer.cornerRadius = min(size.height / 2, 9)
        layer.borderWidth = 2
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        guard !reduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "beacon")
    }
}
