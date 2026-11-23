// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import PowerCore

/// Creates the redesigned main window (behind `FeatureFlags.newWindow`). The configuration is the one the lab renders
/// proved on macOS 27.2: full-size content, a unified `NSToolbar`, transparent title bar and the hosting view as
/// content, so SwiftUI `navigationTitle` and `.toolbar` reach the window. No forced appearance: light and dark follow
/// the system.
@MainActor enum MainWindowController {
    static let defaultSize = NSSize(width: 1000, height: 720)
    /// 940 pt wide: the five Settings tabs in Russian (570 pt) fit in the toolbar beside the open column and title.
    static let minimumSize = NSSize(width: 940, height: 560)
    static let frameName = "TilveroMainWindow.v2"

    /// - remembersFrame: false in tests, so no window frame is written to the test runner's defaults.
    static func makeWindow(model: TilveroModel, remembersFrame: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        configure(window)
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.sceneBridgingOptions = [.title, .toolbars]
        // No min/ideal/max sizing from SwiftUI: those three extra passes over the whole page on every frame made the
        // sidebar animation and window resizing stutter. The window's minimum is set directly below.
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(defaultSize)
        window.contentMinSize = minimumSize
        window.center()
        if remembersFrame { window.setFrameAutosaveName(frameName) }
        return window
    }

    /// Window chrome shared by the app and the render tests.
    static func configure(_ window: NSWindow) {
        window.title = AppIdentity.displayName
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "TilveroMainWindow")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.appearance = nil
    }
}
