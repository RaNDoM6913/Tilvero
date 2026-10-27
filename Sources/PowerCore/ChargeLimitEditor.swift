/// Whether lowering a ceiling below current charge may cause firmware-driven discharge.
public enum LoweringBehavior: String, Sendable, Equatable {
    case yes
    case no
    case unknown
}

public enum ChargeLimitDecision: Sendable, Equatable {
    case apply(target: Int)
    case pending(target: Int, effectiveTarget: Int?)
    case noChange
}

public enum ChargeLimitEditorError: Error, Sendable, Equatable {
    case invalidTargetSet
    case unsupportedTarget(Int)
    case invalidPercentage(Int)
    case noDraftTarget
    case staleDecision
}

/// Pure editing and decision logic. This type performs no I/O or hardware writes.
///
/// It is not a complete charging controller: ownership journals, authenticated IPC,
/// real readback, one-shot completion, scheduling, restoration, and automatic pending
/// activation belong to future layers. An Apply decision is an intention, not success.
public struct ChargeLimitEditor: Sendable, Equatable {
    public let acceptedTargets: [Int]
    public let loweringBehavior: LoweringBehavior
    public private(set) var draftTarget: Int?
    public private(set) var committedTarget: Int?
    public private(set) var effectiveTarget: Int?
    public private(set) var pendingTarget: Int?
    private var intentBeforePending: Int?

    public init(
        acceptedTargets: [Int],
        committedTarget: Int? = nil,
        effectiveTarget: Int? = nil,
        loweringBehavior: LoweringBehavior = .unknown
    ) throws {
        guard !acceptedTargets.isEmpty,
              acceptedTargets == acceptedTargets.sorted(),
              Set(acceptedTargets).count == acceptedTargets.count,
              acceptedTargets.allSatisfy({ (0...100).contains($0) }) else {
            throw ChargeLimitEditorError.invalidTargetSet
        }
        if let committedTarget, !acceptedTargets.contains(committedTarget) {
            throw ChargeLimitEditorError.unsupportedTarget(committedTarget)
        }
        if let effectiveTarget, !(0...100).contains(effectiveTarget) {
            throw ChargeLimitEditorError.invalidPercentage(effectiveTarget)
        }
        self.acceptedTargets = acceptedTargets
        self.loweringBehavior = loweringBehavior
        self.committedTarget = committedTarget
        self.effectiveTarget = effectiveTarget
        self.pendingTarget = nil
        self.intentBeforePending = nil
        self.draftTarget = committedTarget
            ?? effectiveTarget.flatMap { acceptedTargets.contains($0) ? $0 : nil }
            ?? acceptedTargets.first
    }

    public mutating func setDraftTarget(_ target: Int) throws {
        try validateAccepted(target)
        draftTarget = target
    }

    public mutating func discardDraft() {
        draftTarget = committedTarget
            ?? effectiveTarget.flatMap { acceptedTargets.contains($0) ? $0 : nil }
            ?? acceptedTargets.first
    }

    /// Computes a decision without committing intent or modifying effective state.
    /// Pass nil for unknown/stale current charge; it is handled conservatively.
    public func prepareApply(currentChargePercent: Int?) throws -> ChargeLimitDecision {
        guard let target = draftTarget else { throw ChargeLimitEditorError.noDraftTarget }
        try validateAccepted(target)
        if let currentChargePercent, !(0...100).contains(currentChargePercent) {
            throw ChargeLimitEditorError.invalidPercentage(currentChargePercent)
        }
        if target == committedTarget, target == effectiveTarget {
            return .noChange
        }

        let couldLowerBelowCharge = target < 100 && (currentChargePercent.map { $0 > target } ?? true)
        if loweringBehavior != .no, couldLowerBelowCharge {
            if pendingTarget == target, committedTarget == target { return .noChange }
            return .pending(target: target, effectiveTarget: effectiveTarget)
        }
        return .apply(target: target)
    }

    /// Records an accepted policy intention. It deliberately does not change readback.
    /// In this starter, the application calls this only in visibly labelled demo mode.
    public mutating func recordCommittedIntent(_ decision: ChargeLimitDecision) throws {
        switch decision {
        case .noChange:
            return
        case let .apply(target):
            try validateAccepted(target)
            guard draftTarget == target else { throw ChargeLimitEditorError.staleDecision }
            committedTarget = target
            pendingTarget = nil
            intentBeforePending = nil
        case let .pending(target, decisionEffectiveTarget):
            try validateAccepted(target)
            guard draftTarget == target, decisionEffectiveTarget == effectiveTarget else {
                throw ChargeLimitEditorError.staleDecision
            }
            if pendingTarget == nil { intentBeforePending = committedTarget }
            committedTarget = target
            pendingTarget = target
        }
    }

    /// Accepts a separately observed setting, not an optimistic copy of a request.
    /// A currently reported value may be outside the set of values we can write.
    public mutating func recordEffectiveTarget(_ target: Int?) throws {
        if let target, !(0...100).contains(target) {
            throw ChargeLimitEditorError.invalidPercentage(target)
        }
        effectiveTarget = target
        if let target, pendingTarget == target {
            pendingTarget = nil
            intentBeforePending = nil
        }
    }

    /// Cancels only the deferred intention. This does not restore hardware settings.
    public mutating func cancelPendingTarget() {
        guard pendingTarget != nil else { return }
        committedTarget = intentBeforePending
        pendingTarget = nil
        intentBeforePending = nil
        discardDraft()
    }

    private func validateAccepted(_ target: Int) throws {
        guard acceptedTargets.contains(target) else {
            throw ChargeLimitEditorError.unsupportedTarget(target)
        }
    }
}
