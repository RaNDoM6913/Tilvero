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
    static let minimumSize = NSSize(width: 880, height: 560)
    static let frameName = "TilveroMainWindow.v2"

    static func makeWindow(model: TilveroModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        configure(window)
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = host
        window.setContentSize(defaultSize)
        window.contentMinSize = minimumSize
        window.center()
        window.setFrameAutosaveName(frameName)
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
