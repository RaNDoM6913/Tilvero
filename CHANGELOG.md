# Changelog

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
