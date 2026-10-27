# Release and download delivery proposal

Status: proposed process,2026-10-27. There are currently no published binary releases. This document describes the preparation and acceptance required before a Download button becomes available; it is not an installation claim.

## First release

Recommended scope: **Monitoring Beta**, tag `v0.1.0-beta.1`, macOS26.0+, Apple silicon/arm64. Monitoring, history and diagnostics work without administrator approval. Physical control remains disabled. The beta is a GitHub prerelease; broader control support requires independent device/trust/restoration validation. A monitoring-only stable release can be considered separately after its own acceptance.

Ad-hoc builds remain explicitly labeled internal development artifacts. The recommended public DMG requires an owner-controlled Developer ID Application identity, Hardened Runtime, notarization and a real downloaded-install check. Missing signing credentials must produce a clear blocked result, never an automatic downgrade to ad hoc. A Developer ID Installer certificate is not required for the proposed drag-and-drop DMG.

## What the user receives

- `Tilvero-0.1.0-beta.1-arm64.dmg`: a read-only disk image with Tilvero.app, an Applications shortcut and concise installation/legal information.
- `Tilvero-0.1.0-beta.1-source.zip`: corresponding source from the exact public release commit, with build scripts, original assets and licenses.
- `SHA256SUMS`: hashes of the finalized distributable files.
- `release.json`: version/build/tag/commit, channel, minimum OS, architecture, bundle identifiers, toolchain, signing/notarization result and final asset names/sizes/hashes. No credentials or private paths.
- Release notes: supported features, limitations, installation/update steps, source link and verification instructions.

The signed app includes LICENSE, COPYRIGHT and both root/helper third-party notices under a stable resource directory. Third-party authorship remains intact. DMG, source archive and metadata must refer to the same public commit; local private history is never a release source.

## Installation and update

The intended first-run sequence is Download → open DMG → drag Tilvero to Applications → eject DMG → launch from Applications. Copying the monitoring app must not install or register a privileged service. Launching from the mounted image must not silently perform installation or enrollment.

Use a permanent production app identifier before distribution and migrate allowlisted presentation/privacy/history settings and identity salt deliberately. The prototype and production version must not concurrently mutate the same history store. Preserve original data; a failed migration cannot masquerade as a successful empty history.

The first update route is manual. Quit the old app, replace it with the verified new bundle and preserve history/preferences. Future updates of a version with hardware ownership require verified restoration and signed helper/protocol/journal compatibility. Replacement of an app is not proof that a running helper was updated. Sparkle automatic updates, Homebrew and a dedicated website are later, separately scoped work.

## Release pipeline

1. Select a clean public commit and a not-yet-used tag; finalize version and monotonically increasing build number before signing. Build only from an isolated export of that exact committed tree, excluding local untracked/ignored inputs; use the same tree for corresponding source.
2. Build in an isolated destination. Do not mutate or package the running development bundle. Verify arm64/minimum OS, icon, legal resources, monitoring-only contents and source metadata.
3. Sign supplied executable code inside-out, then the app. No debug entitlement, fake Team ID or helper-trust bypass.
4. Create the final read-only DMG with its original volume icon and Applications shortcut; sign the DMG.
5. Submit the outermost DMG through `notarytool`, require Accepted and inspect the notary log; staple and validate the DMG ticket. A separate mandatory second app submission is not part of this route.
6. Test the actual quarantined download, mounted copy, Applications installation, relaunch/update and relevant offline behavior. A locally created image alone does not prove downloaded Gatekeeper acceptance.
7. Compute final checksums after signing/stapling. Verify the source archive and release manifest, then prepare a draft release with all assets.
8. Publish only the admitted release after final review. Prefer GitHub immutable releases so published tags/assets cannot be replaced; a packaging defect gets a new version.
9. Enable the matching Download button, release notes and metric badge only after the asset exists and its link is verified.

For a prerelease, link to its explicit tag/asset. GitHub's latest-full-release endpoint excludes prereleases and drafts; a generic latest link is not the beta download route.

## Download counts without in-app tracking

GitHub exposes `download_count` for each release asset. Report DMG downloads by summing only matching published Tilvero DMGs, with beta/stable scope and retrieval time. Do not count checksums, manifests or source ZIPs as application downloads. Exclude drafts; API failure is unavailable, not zero. Repeated requests, automation and validation downloads may affect the count: it is not unique people, installations or active users.

Use an on-demand read-only report initially. No app telemetry or scheduled collection is required. GitHub repository Traffic separately reports views/clones over a limited14-day window; these do not measure DMG installations. A Shields all-assets total must be labeled as such, not as app users; prefer the current DMG's exact-asset badge.

## GitHub presentation

Keep a compact brand header, then one primary Download for Mac action with Beta/arm64/macOS26+ context, version and size. Follow it with real, redacted screenshots or clearly labeled demo captures, a three-step installation guide, current capability matrix, changelog and support links. Preserve EN/RU parity and the GPL/authorship section. Do not add a disabled-looking fake download link, artificial download numbers, unearned CI badges or screenshots that imply unqualified hardware control.

The separate Social preview graphic is ready; its Settings upload still needs a normal authenticated browser session. It is independent of the README banner already published.

The following is a hierarchy proposal for after a qualified beta exists, not a current download page:

![Proposed README download area, after the beta release](design/release-readme-preview.svg)

## Primary references

- [Apple: packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple: notarization prerequisites](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub: releases API and latest semantics](https://docs.github.com/en/rest/releases/releases)
- [GitHub: immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub: repository traffic](https://docs.github.com/en/repositories/viewing-activity-and-data-for-your-repository/viewing-traffic-to-a-repository)
- [Shields: all-assets downloads scope](https://shields.io/badges/git-hub-downloads-all-assets-all-releases)

See [compatibility](COMPATIBILITY.md) and the [product roadmap](../ROADMAP.md) for current support and proposed product capabilities.
