# Changelog

## 0.2.0 — Source Preview — 2026-11-04

- Refined the sidebar and menu bar battery indicator, and shared the native full-width segmented controls between the app and Lab.
- Improved Overview with a daily charge chart that distinguishes gaps, a weekly capacity estimate based on recorded observations, and clearer power readings.
- Improved the quick Charge tab during refresh and separated the configured charge limit, diagnostic readback and editable draft.
- Added a first-run readiness checklist and an Updates screen for GitHub release discovery.

This release contains source for Apple silicon with macOS 26.0+ and full Xcode.
Automatic installation remains gated. Native charge, fan and closed-lid
controls require their separate device and recovery checks.

## 0.1.0-beta.2 — Sleep Controls Source Preview — 2026-11-02

- One-shot Sleep Timer with visible countdown, cancellation, pre-sleep preparation and an owned idle-sleep hold until expiry.
- Compact Timer/Awake controls with master switches, 36 pt presets, native Custom/Until wheels, explicit mode-replacement consent and exact-session action guards.
- Confirmed preset identity survives extensions; Timer Custom commits after native popover closure.
- A dedicated lid-only native backend, signed XPC boundary, durable journal, app lease and independent recovery guardian. Live admission is restricted to a separately signed trial capped at 120 seconds; physical behavior and restoration remain unqualified.
- Shared-source laboratory flavor with isolated data, injected fixture controls and source-bound local packaging. Experimental Studio artifacts remain private.
- Reproducible isolated trial preparation and stricter rejection of private laboratory paths in source exports.

This is source only. It includes no app/DMG, helper enrollment or hardware-support certification. The public binary profile remains helper-free monitoring; trusted signing, notarization and device gates are separate.

## 0.1.0-beta.1 — Source Preview — 2026-10-31

First source prerelease for Apple silicon and macOS 26.0+. This preview contains
source only; a signed, notarized Monitoring Preview DMG remains a separate release gate.

### Monitoring and reports

- Native menu bar panel and detail window for battery, charging, power, cooling information, application activity, history and diagnostics.
- Source-aware 115-field catalog with freshness, explicit unavailable values, exact raw counters, separate nominal/full-charge capacities and device-scoped inferred readings.
- Separate battery power, reported system load and adapter input/capability, with recorded sparklines and observation statistics.
- Searchable application activity with CPU-load filters, top-three/all views and ranking before display limits. CPU energy/power estimates are explicitly partial; total application consumption and live Energy Impact are not implemented.
- Local minute history, hourly summaries and CSV/JSON export with preview and identifier redaction. Collection gaps and battery boundaries remain visible.
- Read-only Sleep & drain reports for newly observed intervals and current sleep blockers, with incomplete evidence retained and process descriptions excluded from history.

### Native interface

- Refined native page layouts, Russian/English localization, configurable menu bar indicator and a quick-panel constructor with show/hide, drag and keyboard reorder.
- Overview, Charge, Modes and Awake quick-panel destinations; content-sized presentation, recorded last-hour chart and conservative discharge forecast.
- Dedicated Settings sections and Activity search/filter/sort controls. Passive historical native-session details live in Diagnostics; unresolved actions remain visible.
- Exact-bundle launching, running-app overwrite protection and fresh `.noindex` candidate destinations to keep inactive copies out of Spotlight.

### Development controls and safety

- Explicit Keep Mac Awake sessions with visible Stop and no automatic restart activation; disabled in simulation and Monitoring Preview.
- Durable Normal / Economy / Maximum autonomy plans with separate Save / Apply, action previews and partial outcomes; unqualified energy/display actions remain excluded.
- User-space native charge adapter with original-state journals, pending lower targets, external reconciliation and per-Mac admission. One-time full charging and physical cutoff retain separate validation gates.
- Privileged helper, peer authentication and recovery source/fixture coverage. Privileged charging, energy-mode and fan writes remain unqualified; fans default to System Auto.
- Clearly labeled DEMO simulation separate from live data/history; no administrator approval needed for monitoring.

### Source release preparation

- English/Russian project and installation guides, compatibility matrix and source-build instructions.
- Monitoring-only release configuration with a separate production identity/store, helper-free packaging and fail-closed signing/notarization checks.
- On-demand GitHub DMG download reporting with pagination, asset deduplication and explicit unavailable results; no in-app telemetry.
- GPL-3.0-only source, original artwork and documentation with preserved third-party notices.

See [testing and validation](docs/TESTING.md) for public coverage and evidence
boundaries, and Git history for earlier changes. Local ad-hoc TEST packages and
successful software tests do not establish trusted distribution or physical
hardware-control support.
