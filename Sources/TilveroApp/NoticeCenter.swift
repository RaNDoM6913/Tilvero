// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Observation

/// Who raised a notice. Every source owns one slot, so a later notice from one feature never erases another feature's
/// message, and a feature that resolves its own problem clears only its own line.
enum NoticeSource: CaseIterable, Sendable {
    /// A control could not be made safe before sleep or quit ("Recovery required"). A later control result (a successful
    /// restore, another apply) replaces it, as the single notice line did.
    case recovery
    /// A Keep Awake session ended with a failure. Stays on every page until Keep Awake reports something newer.
    case keepAwake
    /// The result of a control action: charge limit, helper, fans, profiles and schedules, the simulation's actions.
    case control
    /// "Simulation only — your Mac settings are unchanged." after a simulated action.
    case simulation
    /// Export, diagnostics report and login-item results.
    case data

    /// Sources that describe the state of the controls: a newer one replaces the others (a new apply outdates the
    /// previous failure or a recovery warning).
    var group: Set<NoticeSource> {
        switch self {
        case .recovery, .control, .simulation: [.recovery, .control, .simulation]
        default: [self]
        }
    }
    var lifetime: Notice.Lifetime { self == .keepAwake ? .untilResolved : .page }
}

struct Notice: Equatable, Sendable {
    enum Lifetime: Equatable, Sendable {
        /// Goes when the user leaves the page it was raised on, at the start of the next action, or when its source
        /// clears it.
        case page
        /// Stays on every page until its source clears it.
        case untilResolved
    }
    let text: String
    let source: NoticeSource
    /// Posting order; the newest notice is the one shown.
    let sequence: UInt64
    var lifetime: Lifetime { source.lifetime }
}

/// The notices of every feature, one slot per source. Surfaces show the newest (`current(excluding:)`); when it is
/// cleared, an older notice that is still valid shows again instead of being lost.
@MainActor @Observable final class NoticeCenter {
    private(set) var notices: [NoticeSource: Notice] = [:]
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var expiries: [NoticeSource: Task<Void, Never>] = [:]

    /// Shows `text` for `source`, replacing that source's (and its group's) earlier notice. With `expiresAfter` the
    /// notice removes itself unless something newer replaced it meanwhile.
    func post(_ text: String, from source: NoticeSource, expiresAfter: Duration? = nil) {
        clear(source.group)
        sequence &+= 1
        let notice = Notice(text: text, source: source, sequence: sequence)
        notices[source] = notice
        guard let expiresAfter else { return }
        expiries[source] = Task { [weak self] in
            try? await Task.sleep(for: expiresAfter)
            guard !Task.isCancelled, let self, self.notices[source] == notice else { return }
            self.notices[source] = nil
            self.expiries[source] = nil
        }
    }

    func clear(_ source: NoticeSource) { clear([source]) }

    func clear(_ sources: Set<NoticeSource>) {
        for source in sources {
            expiries.removeValue(forKey: source)?.cancel()
            if notices[source] != nil { notices[source] = nil }
        }
    }

    /// The user left the page, or a new action starts: every page notice goes; one that waits for its source stays.
    func clearPageNotices() {
        clear(Set(notices.values.filter { $0.lifetime == .page }.map(\.source)))
    }

    /// The notice to show: the newest one, or nothing when the newest comes from an excluded source (a surface that
    /// leaves out, say, the Charge page's own status line shows nothing then, never an older line it was hiding).
    func current(excluding excluded: Set<NoticeSource> = []) -> Notice? {
        guard let newest = notices.values.max(by: { $0.sequence < $1.sequence }), !excluded.contains(newest.source) else { return nil }
        return newest
    }

    /// Stops pending expiries (the model is stopping).
    func cancelExpiries() {
        expiries.values.forEach { $0.cancel() }
        expiries = [:]
    }
}
