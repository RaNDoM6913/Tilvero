# Tilvero roadmap

Tilvero focuses on battery, charging, power and cooling in a native, offline macOS app. This roadmap describes proposed directions, not release promises or a statement that hardware controls already work.

## Current foundation

Live monitoring, a compact menu bar panel, searchable readings, local history, redacted exports, Russian/English UI and explicit simulation are available in source builds. Control policies and recovery boundaries have software coverage; live writes remain disabled pending the [compatibility gates](docs/COMPATIBILITY.md).

## Next proposed milestones

| Order | User outcome | What must be demonstrated |
|---|---|---|
| 1. Understand sleep loss | See whether the Mac is allowed to idle-sleep, which apps are blocking it, and how charge changed across an observed sleep interval | Read-only collection, honest incomplete/mixed sessions, no sampling wakeups or fabricated energy values |
| 2. Economy profiles | Choose Standard, Economy or Maximum autonomy with a visible list of changes | Per-setting capability checks, partial results, manual override and restoration; actual saving measured rather than advertised in advance |
| 3. Charge for departure | Request a target charge by a chosen time and see a realistic preparation window | Local charging observations, uncertainty, adapter/temperature constraints, cancellation and conservative return to the previous policy |
| 4. Qualified sleep execution | Optionally allow one owned wake for an explicitly authorized charging plan | Trusted helper, finite sleep-plan authority, real OS wake/sleep/lid behavior and recovery; preserve all unrelated scheduled events |
| 5. Personal energy budget | Estimate whether the battery can last to a chosen time with a reserve, and compare similar sessions | Adequate observations, clear uncertainty and no false per-app watt attribution |

Work mode, sleep preference and a departure charging plan should be independent. A user can save energy while preserving background jobs, or choose a quieter sleep policy with an explicit exception for a charging wake.

## Design commitments

- Preserve background jobs and connectivity by default. No automatic force-quit, process suspension or system-service disabling.
- Use supported macOS Low Power Mode and independently qualified settings. Maximum autonomy is a transparent combination of actions, not an invented extra CPU power mode.
- Show requested, applied and observed state separately. A pending lower charge target is not an active ceiling.
- Keep wake-for-charging opt-in. A timer cannot execute while the process is suspended, and a scheduled event is not proof that charging happened.
- Protect the existing recovery contract. Sleep-aware control needs its own bounded authorization; it must not remove heartbeat expiry or weaken XPC trust.
- Keep telemetry and history local. No account, cloud prediction service or network dependency for core functionality.
- Exclude forced discharge cycles, legacy “deep sleep” recipes, arbitrary hardware writes and fixed savings promises from these milestones.

Real Pro cooling, signed distribution and model-specific controls remain separate validation work. Contributions should target a coherent outcome and preserve the current working monitor. Discuss a proposal through a [feature request](https://github.com/RaNDoM6913/Tilvero/issues/new?template=feature_request.yml) before implementing a new control boundary.
