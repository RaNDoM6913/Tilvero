// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// Observable wrapper around the pure `FirstRunFlow`: views read it and send events; effects go to the coordinator.
@MainActor final class FirstRunSession: ObservableObject {
    @Published var flow = FirstRunFlow()
    /// Start of the current scene (resets when the step changes).
    @Published private(set) var sceneStart = Date()
    /// Debug: playback speed (preview only).
    @Published var speed = 1.0
    /// Debug: force Reduce Motion (preview only).
    @Published var forceReduceMotion = false
    /// Any click on the window scene jumps to its final frame.
    @Published var jumpedToEnd = false
    /// The guide cursor stops once the pointer moves over the card; it never comes back for that scene.
    @Published var guideDismissed = false
    /// The first-run window is on screen and not covered: timelines pause otherwise.
    @Published var windowOnScreen = true
    /// The card's "Check" asks the quick panel to open the Charge tab (no write happens there by itself).
    @Published var requestedSection: QuickPanelSection?
    let isPreview: Bool
    var perform: (FirstRunEffect) -> Void = { _ in }

    init(isPreview: Bool, flow: FirstRunFlow = FirstRunFlow()) {
        self.isPreview = isPreview
        self.flow = flow
    }

    var reduceMotion: Bool { forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var step: FirstRunStep { flow.step }

    /// Renders hold one frame (snapshot tests); nil in the app.
    var frozenTime: Double?

    func time(at date: Date) -> Double { frozenTime ?? max(0, date.timeIntervalSince(sceneStart)) * speed }

    func send(_ event: FirstRunEvent) {
        let before = flow.step
        let effects = flow.handle(event)
        if flow.step != before { restartScene() }
        effects.forEach(perform)
    }

    func restartScene() {
        sceneStart = Date(); jumpedToEnd = false; guideDismissed = false
    }

    /// Debug: put the flow into any step with plausible choices.
    func jump(to step: FirstRunStep) {
        var flow = FirstRunFlow()
        func go(_ events: [FirstRunEvent]) { events.forEach { flow.handle($0) } }
        switch step {
        case .iconFill: break
        case .whereIcon: go([.iconFilled])
        case .hiddenIcon: go([.iconFilled, .showHidden])
        case .card: go([.iconFilled, .statusItemClicked])
        case .confirmPreview, .systemPrompt, .declined:
            go([.iconFilled, .statusItemClicked])
            flow.choices.moreExpanded = true; flow.choices.lidClosed = true; flow.choices.chargeByTime = true
            go([.done])
            if step != .confirmPreview { go([.previewFinished]) }
            if step == .declined { go([.promptFinished(.cancelled)]) }
        case .done:
            go([.iconFilled, .statusItemClicked])
            flow.choices.chargeLimit = true; flow.choices.lidClosed = true; flow.choices.chargeByTime = true
            go([.done, .previewFinished, .promptFinished(.success([.lidClosed, .chargeByTime])), .loginFinished(.enabled)])
        case .bubble: go([.iconFilled, .skip])
        case .finished: go([.iconFilled, .skip, .bubbleFinished])
        }
        self.flow = flow
        restartScene()
    }
}

// MARK: Frames of the guide targets inside the quick panel

struct FirstRunFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func firstRunFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: FirstRunFrameKey.self, value: [id: proxy.frame(in: .named(FirstRunGuideLayer.space))])
        })
    }
}
