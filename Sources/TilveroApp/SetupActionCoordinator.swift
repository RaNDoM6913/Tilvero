// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

/// Explicit setup commands. Construction and refresh perform no consent or control action.
@MainActor final class SetupActionCoordinator {
    struct Ports {
        /// Refresh service facts using read-only discovery. Missing facts must stay unknown.
        /// This must never register, change settings, or run physical qualification.
        let readInputs: @MainActor () async -> SetupReadinessInputs
        let viewRequirements: @MainActor (SetupFeature) async throws -> Void
        let openApprovalSettings: @MainActor (SetupFeature) async throws -> Void
        /// Owning services must recheck their own admission at the operation boundary.
        let registerHelper: @MainActor () async throws -> Void
        /// Set enabled explicitly; never connect this port to a toggle.
        let enableLogin: @MainActor () async throws -> Void
        let setHistoryEnabled: @MainActor (Bool) async throws -> Void
        /// Uses the existing safe gate and restoration contract, never a raw hardware setter.
        let requestNativeChargeValidation: @MainActor () async throws -> Void
    }

    enum Outcome: Equatable, Sendable {
        /// The command returned; only refreshed readiness describes actual authority/status.
        case performed
        case alreadySatisfied, unavailable, busy
        case failed(String)
    }

    struct Result: Equatable, Sendable {
        let outcome: Outcome
        let readiness: SetupReadiness
    }

    private let ports: Ports
    private var actionInFlight = false

    init(ports: Ports) { self.ports = ports }

    func refresh() async -> SetupReadiness {
        SetupReadiness(inputs: await ports.readInputs())
    }

    func perform(_ action: SetupAction) async -> Result {
        // Claim the slot before the asynchronous read, which may yield to another click.
        let wasBusy = actionInFlight
        if !wasBusy { actionInFlight = true }
        let readiness = await refresh()
        guard !wasBusy else { return Result(outcome: .busy, readiness: readiness) }
        defer { actionInFlight = false }

        if action == .enableLogin, readiness.inputs.login == .enabled {
            return Result(outcome: .alreadySatisfied, readiness: readiness)
        }
        if case .setHistoryEnabled(let enabled) = action,
           readiness.inputs.historyEnabled == enabled {
            return Result(outcome: .alreadySatisfied, readiness: readiness)
        }
        guard readiness.items.contains(where: { $0.actions.contains(action) }) else {
            return Result(outcome: .unavailable, readiness: readiness)
        }

        // Navigation and read-only refresh have distinct ports from consent/control.
        // In particular, no helper or closed-lid qualification port exists here.
        do {
            switch action {
            case .refresh:
                return Result(outcome: .performed, readiness: readiness)
            case .viewRequirements(let feature):
                try await ports.viewRequirements(feature)
            case .openApprovalSettings(let feature):
                try await ports.openApprovalSettings(feature)
            case .registerHelper:
                try await ports.registerHelper()
            case .enableLogin:
                try await ports.enableLogin()
            case .setHistoryEnabled(let enabled):
                try await ports.setHistoryEnabled(enabled)
            case .requestValidation(.nativeCharging):
                try await ports.requestNativeChargeValidation()
            case .requestValidation:
                return Result(outcome: .unavailable, readiness: readiness)
            }
            return Result(outcome: .performed, readiness: await refresh())
        } catch {
            return Result(outcome: .failed(String(describing: error)), readiness: await refresh())
        }
    }
}
