// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

/// Test-only body-evaluation counter. A few key views call `RenderProbe.hit(_:)` from `body`; debug builds count
/// while a test has switched it on (`RenderInvalidationTests`), release builds compile it to nothing. It measures what
/// SwiftUI actually re-rendered after one model or service change, the cost the state split is meant to cut.
@MainActor enum RenderProbe {
    #if DEBUG
    static var isEnabled = false
    private(set) static var counts: [String: Int] = [:]
    /// The last text each `StudioText` id drew while enabled: a render test reads what is on screen, not a helper's result.
    private(set) static var texts: [String: String] = [:]
    static func reset() { counts = [:]; texts = [:] }
    #endif

    @inline(__always) static func hit(_ name: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        counts[name(), default: 0] += 1
        #endif
    }

    @inline(__always) static func text(_ id: @autoclosure () -> String, _ value: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        texts[id()] = value()
        #endif
    }
}
