// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// "Charge to 100% once" on the user-space native charge path: the limit is lifted to 100 through the same verified
/// apply the slider uses, and the level the user had is put back when the charge is over. The intent is just that
/// remembered level; it is dropped the moment the limit no longer reads 100 (the user changed it in macOS), so it
/// never overwrites a choice made elsewhere.
enum ChargeOnceRule {
    enum Decision: Equatable {
        case keep
        /// The one-time charge is over: apply the remembered limit again.
        case restore(Int)
        /// Someone else changed the limit: forget the intent and write nothing.
        case drop
    }

    static func decide(previous: Int, observedTarget: Int?, percent: Int?, isCharging: Bool?, externalPower: Bool?) -> Decision {
        if let observedTarget, observedTarget != NativeChargeAdmission.unlimitedTarget { return .drop }
        if externalPower == false { return .restore(previous) }
        if let percent, percent >= 100, isCharging == false { return .restore(previous) }
        return .keep
    }
}

/// The remembered limit, kept across relaunches (a quit in the middle must not forget what to put back).
@MainActor final class ChargeOnceStore: ObservableObject {
    private static let key = "chargeOncePreviousTarget"
    private let preferences: UserDefaults
    @Published private(set) var previousTarget: Int?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        let saved = preferences.object(forKey: Self.key) as? Int
        previousTarget = saved.flatMap { NativeChargeAdmission.persistentTargets.contains($0) && $0 != NativeChargeAdmission.unlimitedTarget ? $0 : nil }
    }
    var isActive: Bool { previousTarget != nil }
    func begin(previous: Int) { previousTarget = previous; preferences.set(previous, forKey: Self.key) }
    func clear() { previousTarget = nil; preferences.removeObject(forKey: Self.key) }
}
