# Compatibility and current support

Tilvero is a source preview for Apple silicon Macs running **macOS 26.0+**.
Its first public binary scope is the planned read-only **Monitoring Preview**.
A source prerelease and a trusted Mac download are separate deliverables.

## System requirements

| Requirement | Supported development route |
| --- | --- |
| Mac | Apple silicon / arm64; Intel is not a supported target |
| OS | macOS 26.0 or later |
| Build tools | Full Xcode with a compatible macOS SDK and Swift 6; Command Line Tools alone are not the validated route |
| Interface | Native SwiftUI and AppKit; Russian and English |
| Connectivity | No account, cloud service or internet connection required by the app |
| Monitoring | Runs without administrator approval or helper enrollment |

The deployment target does not prove every model/OS combination has been tested.
Recorded actual monitoring/UI observations include MacBook Air M5 / Mac17,3 on
macOS 26.6.2. MacBook Air is fanless; a Pro simulator cannot qualify Pro hardware.

## Capability matrix

| Capability | Current source | Important limit |
| --- | --- | --- |
| Battery and adapter readings | Implemented; actual local app observations | The 115-field catalog is a schema, not a promise of 115 available measurements |
| Menu bar and detail window | Implemented; native UI, keyboard and appearance checks recorded | Full VoiceOver speech acceptance remains open |
| Local history and CSV/JSON export | Implemented and fixture-tested; actual history observed | Gaps stay visible; no invented samples; preview exports before sharing |
| Application activity | Read-only process counters, search, filtering and ranking | CPU energy/power estimates cover CPU activity only; accessible processes may be a partial set |
| Sleep & drain | Read-only observation and fixture coverage | New app-observed intervals only; completed real sleep/wake validation remains a device gate |
| Keep Mac Awake | Explicit source-build sessions with visible Stop | Disabled in DEMO and Monitoring Preview; does not override lid, forced or low-battery sleep |
| Saved modes | Separate Save / Apply, action previews and per-action outcomes | Saving never applies; unqualified energy/display actions are excluded |
| Native charge controller | User-space PowerUI adapter with a recovery journal | Requires admission on the exact Mac/OS/ABI; cutoff and one-time-full-charge behavior have separate gates |
| Privileged helper and recovery | Source and fixture implementation | Trusted signing, OS enrollment, lifecycle and device acceptance remain open |
| Privileged charge, energy modes and fans | Physical writes disabled by qualification gates | No generally qualified physical-write set; Pro cooling needs real sensor/RPM/Auto/recovery evidence |
| Extended/sub-80% limits and forced discharge | Unavailable | Require independent supported contracts and hardware validation |

Live macOS **Energy Impact is not implemented**. CPU watts are not total
application watts; GPU/other-device consumption and historical per-app sleep
energy attribution are not established by the current collector.

Sleep reports require history collection and observed sleep/wake boundaries.
A before/after charge change does not establish battery-only operation or exact
time asleep. Internal wake counts/reasons are unavailable; current blockers
describe now. Sleep records follow detailed-history retention and erasure, but
are not included in ordinary CSV/JSON exports. Process names/assertion descriptions
are not persisted in battery history.

## Development source and Monitoring Preview

A default `build-local-app.sh` build uses the development identity. It includes
control-related code and a bundled, unregistered helper. Native charge admission
is a separate normal-user route: a bounded setting/readback/restoration check
never enables helper or fan control. Targets may remain pending until natural
discharge; a pending target is not active. Fans default to System Auto.

The release configuration selects **monitoring** mode. Its future DMG contains no
privileged helper or service registration and disables control actions, keyboard
backlight writes and Keep Mac Awake. These release restrictions should not be
inferred from the behavior of an ordinary source build.

A readable key, model name, successful test/build or simulator result never
qualifies a hardware write. There is no UI or environment override for the
privileged qualification gate. See the [helper architecture](../Helper/README.md).

## Validation and distribution

The latest recorded stable app milestone ran **362 tests with zero failures**,
built SwiftPM Release and Xcode Debug bundles, and verified local ad-hoc signature
integrity. These results apply to the recorded source milestone, not automatically
to a later release commit. [Testing and validation](TESTING.md) summarizes public coverage and its limits.

**Implemented** means code exists. **Fixture-tested** means deterministic inputs
exercise a contract. **Observed** means actual app/device behavior was inspected.
Hardware control additionally needs baseline, bounded mutation, readback, physical
behavior and restoration. Each status is recorded separately.

A trusted downloadable app still requires Developer ID signing, notarization and
an actual quarantined-download/install check. Local ad-hoc **TEST** packages are
internal artifacts. Source availability does not establish trusted distribution.
Signed lifecycle/launch-at-login behavior, physical unplug/sleep transitions and
remaining accessibility checks retain their own acceptance gates.

Local machine snapshots and owner telemetry are not public qualification data.
README gallery captures, when supplied, use explicitly labeled demo data and do
not certify a release binary or physical hardware controls.

[Build and run](../README.md#build-and-run) · [Installation](INSTALL.md) ·
[Release preparation](RELEASING.md) · [Roadmap](../ROADMAP.md)
