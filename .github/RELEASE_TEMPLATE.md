# Tilvero {{VERSION}} — Monitoring Beta

<!-- Release-note template. Fill every token and verify every claim before creating a release draft. This file does not publish or authorize a binary release. -->

Native battery monitoring, local history and diagnostics for Apple silicon Macs running macOS26.0 or later.

## Download

- DMG: `{{DMG_NAME}}` — `{{DMG_SIZE}}`
- Source: `{{SOURCE_NAME}}`
- Verification: `SHA256SUMS`, `release.json`
- Source tag/commit: `{{TAG}}` / `{{FULL_PUBLIC_COMMIT}}`
- Signing/notarization: `{{VERIFIED_DISTRIBUTION_STATUS}}`

Use this beta for monitoring and explicitly labeled simulation. Physical charging, power-mode and fan controls are disabled; installing the monitoring app does not enroll a privileged service.

## Install

1. Download and open the DMG.
2. Drag Tilvero to Applications and eject the image.
3. Launch Tilvero from Applications. Its battery item appears in the menu bar.

## Changes

{{USER_VISIBLE_CHANGES}}

## Known limitations

{{VERSION_SPECIFIC_LIMITATIONS}}

Hardware control needs separate signed-runtime/device/restoration acceptance. Field availability depends on the Mac; missing readings stay unavailable. This beta makes no fixed battery-life or hardware-recovery guarantee.

## Updating and data

{{VERIFIED_UPGRADE_AND_MIGRATION_BEHAVIOR}}

Quit the previous version before replacement. Preserve local history and recovery records. Report migration or installation failure rather than deleting data or weakening macOS protections.

## Verification

After downloading the listed assets into one directory, verify their final checksums:

```sh
shasum -a 256 -c SHA256SUMS
```

Recorded release checks: `{{ACTUAL_TEST_BUILD_PACKAGE_INSTALL_RESULTS}}`.

Tilvero is GPL-3.0-only, Copyright(c)2026RaNDoM6913. Matching source and required third-party notices are included. Report bugs through the repository's issue templates with minimal redacted evidence.
