# Compatibility and current support

Tilvero is a development preview for Apple silicon Macs running macOS26.0 or later. It is useful as a local monitor today; the source also contains control policies whose physical operations remain disabled until their independent validation gates are met.

## Build environment

- Native Swift6, AppKit and SwiftUI; a Swift package plus Xcode app/helper targets.
- Full Xcode with a compatible macOS SDK is required. Command Line Tools alone are not the validated build route.
- Recorded development environment: Xcode27.1, Swift6.4, macOS SDK27.0, deployment target26.0.
- Local SwiftPM and Xcode builds succeeded; the latest recorded default suite contains123 passing tests. These are local results, not a GitHub Actions badge or a guarantee for every compiler version.
- Local app bundles are ad-hoc signed for development. There is no signed/notarized download or generally supported helper installation yet.

## Capability matrix

| Capability | Current status | Boundary |
|---|---|---|
| Battery and adapter monitoring | Implemented; actual app observations on MacBook Air M5 / Mac17,3, macOS26.6.2 | Every field has availability and freshness; other models may expose different fields |
| Menu bar and detail UI | Implemented; actual UI, keyboard and appearance checks | Russian/English; icon and percentage sizing; complete VoiceOver speech acceptance remains open |
| History and export | Implemented and fixture-tested; real local history observed | SQLite history begins with collection; no invented samples across gaps; exports preview and redact identifiers |
| Charge-policy logic | Implemented and fixture-tested | Pending lower targets, explicit Apply, one-shot return/cancel and stale-generation handling; no qualified physical writes |
| Power profiles and local schedules | Implemented in source/fixtures | Awake scheduling is distinct from charging by a deadline or executing while asleep |
| Privileged helper and recovery | Implemented and fixture-tested | Trusted signed OS XPC/enrollment/denial/update/removal acceptance remains open |
| Native charge control | Disabled in the live build | Requires trusted helper, accepted-target discovery, real cutoff/recharge behavior and verified restoration |
| Energy-mode control | Disabled in the live build | Requires independent battery/adapter qualification and restoration |
| MacBook Pro cooling control | Disabled in the live build | Requires a named real Pro, qualified sensors, actual RPM response and Auto/recovery evidence |
| Extended charge bands, sub80 and forced discharge | Unavailable | Each needs its own supported contract and hardware validation |

The shipped physical-write qualification set is empty. A readable registry/SMC key, matching model name, successful build or simulator result does not enable a write. There is no UI or environment override for this gate.

MacBook Air is fanless; a Pro simulator does not certify Pro hardware. Model-specific behavior must be demonstrated on the actual OS/firmware combination before a support claim is added.

## What the evidence means

**Implemented** means the code path exists. **Fixture-tested** means deterministic or injected tests exercise the contract. **Observed** means the actual app or device behavior was inspected. Hardware control additionally requires baseline capture, bounded mutation, readback, physical behavior and restoration. These states are recorded separately.

Local execution journals, private machine snapshots and owner screenshots are not published with the source. Contributors should provide minimal redacted evidence for the behavior they change. Public support claims must not rely on unspecified private success or turn an unobserved hardware path into a PASS.

## Current practical limits

Use source builds for monitoring and explicitly labeled simulation. Monitoring requires no administrator approval. Launch-at-login from an installed bundle, signed lifecycle behavior, physical unplug/sleep transitions and remaining accessibility acceptance still need their relevant real-environment checks.

Economy/Maximum autonomy modes, sleep-loss reporting and deadline charging are proposals described in the [roadmap](../ROADMAP.md), not enabled capabilities of this preview. No fixed runtime extension, sleep consumption or asleep charging deadline is promised.

See the [README](../README.md) for build/run commands and the [helper architecture](../Helper/README.md) for the trust and recovery contract.
