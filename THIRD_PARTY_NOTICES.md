# Third-party provenance

The starter was authored for this project. The current application has no third-party runtime package or bundled SMC/fan-control binary. The implemented control adapters include MIT-attributed researched ABI/key layouts as documented below.

Apple platform frameworks are referenced through public SDK APIs for observation/UI. Private charge/fan adapter provenance and complete notices are recorded below; consulted-only telemetry sources are listed at the end of this document.

The optional PNG concept references described in `Design/` were generated as original illustrative UI concepts using the built-in image generation tool. They contain demo readings and the owner-confirmed Tilvero identity. They are design references, not extracted Apple system assets or runtime screenshots. Production menu-bar artwork is drawn by code.

Before reusing external source, preserve applicable notices and record the exact source/revision. In particular, do not assume the battery project's bundled GPL SMC binary is covered by its main MIT license, and do not copy unlicensed GlassFan code.

The original Tilvero source, documentation and repository artwork are licensed under GNU GPL version3 only (`GPL-3.0-only`), Copyright (c) 2026 RaNDoM6913. See [LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT). The third-party MIT notices below remain applicable to their respective material.

## Implemented control adapter provenance (2026-10-27)

The local native/SMC adapters contain researched ABI/key layouts adapted with MIT attribution. Full immutable references, affected local scope and complete notices are retained in [Helper/THIRD_PARTY_NOTICES.md](Helper/THIRD_PARTY_NOTICES.md). Those notices must travel with any redistributed app/source. No GPL smc binary or unlicensed GlassFan implementation is bundled.

Telemetry normalization was independently implemented from installed IOPS headers and source contracts. Consulted-only sources include Apple PowerManagement `d415e45501842834a280930c3eed9186544a67f0`, Apple XNU `IOPMPowerSource.h`, Ampere `843498d7beb711c0e1b18e48c8520debe67f6e3f`, and Stats `5cf09a8cb0561ff24c28be4e5374d579d0601818`. Source-qualified encodings do not establish sensor calibration or physical hardware-control support.
