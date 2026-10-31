# Release-note routes

For the first **Source Preview**, use [the source release notes](../docs/releases/v0.1.0-beta.1.md). Convert repository-relative links to absolute URLs pinned to the release tag before copying them into a GitHub release body. Upload only the source ZIP, `source-release.json` and `SHA256SUMS`; no app or DMG is included.

The template below is reserved for a future trusted binary release with its own fresh tag and completed distribution checks. Follow [the release guide](../docs/RELEASING.md).

---

# Tilvero {{VERSION}} — Monitoring Preview

<!-- Release-note template for a separately authorized public prerelease. Fill every token and verify every claim before creating a release draft. No draft, tag, upload or publication is authorized by this file. Never use this public template for an internal ad-hoc TEST package. -->

Native battery monitoring, local history and diagnostics for Apple silicon (arm64) Macs running macOS 26.0 or later. This is a prerelease.

## Download

- DMG: [{{DMG_NAME}}]({{EXACT_TAG_DMG_URL}}) — `{{DMG_SIZE}}`
- Source: [{{SOURCE_NAME}}]({{EXACT_TAG_SOURCE_URL}})
- Verification: [SHA256SUMS]({{EXACT_TAG_CHECKSUMS_URL}}), [release.json]({{EXACT_TAG_MANIFEST_URL}})
- Source tag/commit: `{{TAG}}` / `{{FULL_PUBLIC_COMMIT}}`
- Signing/notarization: `{{VERIFIED_DISTRIBUTION_STATUS}}`

Use this preview for monitoring and explicitly labeled simulation. Physical charging, power-mode and fan controls are disabled; installing the monitoring app does not enroll a privileged service. The package contains no root helper or launch jobs. Developer source-build helper commands are not installation steps.

## Install

1. Download the listed assets, verify `SHA256SUMS`, then open the DMG.
2. Drag Tilvero to Applications and eject the image.
3. Launch Tilvero from Applications. Its battery item appears in the menu bar.

[Installation guide / инструкция по установке]({{SOURCE_BOUND_INSTALL_GUIDE_URL}}). If macOS rejects the download, report the failure; do not bypass Gatekeeper or remove quarantine.

## Changes

{{USER_VISIBLE_CHANGES}}

## Known limitations

{{VERSION_SPECIFIC_LIMITATIONS}}

Hardware control needs separate signed-runtime/device/restoration acceptance. Field availability depends on the Mac; missing readings stay unavailable. This preview makes no fixed battery-life or hardware-recovery guarantee.

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
