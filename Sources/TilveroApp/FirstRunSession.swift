// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// Observable wrapper around the pure `FirstRunFlow`: views read it and send events; effects go to the coordinator.
@MainActor final class FirstRunSession: ObservableObject {
    @Published var flow = FirstRunFlow()
    /// Start of the current step (the success check draws from here).
    @Published private(set) var sceneStart = Date()
    /// Debug: playback speed (preview only).
    @Published var speed = 1.0
    /// Debug: force Reduce Motion (preview only).
    @Published var forceReduceMotion = false
    /// The exact text Terminal runs, shown behind "Show command" while the window waits for Terminal.
    @Published var commandText: String?
    @Published var showsCommand = false
    /// The coach on the real Charge tab after the quick menu opened.
    @Published var coachVisible = false
    @Published private(set) var coachStart = Date()
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
    func coachTime(at date: Date) -> Double { frozenTime ?? max(0, date.timeIntervalSince(coachStart)) * speed }

    func send(_ event: FirstRunEvent) {
        let before = flow.step
        let effects = flow.handle(event)
        if flow.step != before { sceneStart = Date(); if !flow.isWaiting { showsCommand = false } }
        effects.forEach(perform)
    }

    func showCoach(_ visible: Bool) {
        if visible { coachStart = Date() }
        coachVisible = visible
    }

    /// Debug and renders: put the flow into any step with plausible choices (no effects run).
    nonisolated static func flow(at step: FirstRunStep, locked: Bool = true) -> FirstRunFlow {
        var flow = FirstRunFlow()
        func go(_ events: [FirstRunEvent]) { events.forEach { flow.handle($0) } }
        if locked && step != .choosing { flow.choices.lidClosed = true; flow.choices.chargeByTime = true }
        switch step {
        case .choosing: break
        case .applying: go([.start])
        case .waitingSystem: go([.start, .everydayApplied(.enabled)])
        case .waitingTerminal: go([.useTerminal, .everydayApplied(.enabled)])
        case .enablingLid: go([.start, .everydayApplied(.enabled), .permissionFinished(.succeeded([.lidClosed, .chargeByTime]))])
        case .declined: go([.start, .everydayApplied(.enabled), .permissionFinished(.cancelled)])
        case .failed: go([.start, .everydayApplied(.enabled), .permissionFinished(.failed(7))])
        case .timedOut: go([.useTerminal, .everydayApplied(.enabled), .permissionFinished(.timedOut)])
        case .attention: go([.start, .everydayApplied(.requiresApproval)])
            if flow.step != .attention { go([.permissionFinished(.succeeded([.lidClosed, .chargeByTime])), .lidTurnedOn(true)]) }
        case .done: go([.start, .everydayApplied(.enabled), .permissionFinished(.succeeded([.lidClosed, .chargeByTime])), .lidTurnedOn(true)])
        case .iconHidden: go([.skip, .iconHidden])
        case .finished: go([.skip, .revealed])
        }
        return flow
    }

    /// Debug: jump to a step (the coordinator runs what that step needs).
    func jump(to step: FirstRunStep) {
        flow = Self.flow(at: step)
        sceneStart = Date(); showsCommand = false
    }
}

// MARK: Frames of the coach target inside the quick panel

struct FirstRunFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func firstRunFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: FirstRunFrameKey.self, value: [id: proxy.frame(in: .named(FirstRunCoachLayer.space))])
        })
    }
}
