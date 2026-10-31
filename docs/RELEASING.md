# Releasing Tilvero

Tilvero has two distinct distribution routes: the first **Source Preview** and a future trusted **Monitoring Preview** Mac download. A source release does not establish that a prebuilt app is ready for public distribution.

## Source Preview

The first source prerelease uses `v0.1.0-beta.1`. It targets developers building on Apple silicon with macOS 26 or later and a compatible full Xcode installation. It includes no `.app`, helper executable or DMG. Its source tree contains gated development controls as well as monitoring; a normal development build is distinct from the future monitoring-only package.

The source profile's exact upload allowlist is:

- `Tilvero-0.1.0-beta.1-source.zip`
- `source-release.json`
- `SHA256SUMS`

Prepare only after every public source, document and media asset is committed and the tracked checkout is clean:

```sh
python3 scripts/source_release.py prepare --commit <full-current-commit>
python3 scripts/source_release.py verify \
  --manifest build/source-releases/v0.1.0-beta.1/source-release.json
```

The tool requires an exact 40-character current commit, matching committed configuration, an unused local tag and the admitted public ancestry. The coordinator must also check the remote tag/release state. It exports the full committed tree, rejects private/runtime/signing files and verifies ZIP entries, raw blobs, permissions, CRC, commit identity and final checksums. Untracked and ignored local inputs never become release source. Existing output is never replaced; failed work remains `.incomplete` for inspection.

`source-release.json` has a separate source-only schema: `artifactType=source-preview`, `binaryIncluded=false`, `requiresBuild=true`, exact commit/tag/version and source-ZIP size/hash. It has no app-signing, notarization or binary-readiness claim. The existing development bundle is fingerprinted before and after preparation.

Before publishing:

1. Review the exact public source/media/doc changes, build requirements, legal notices and capability wording.
2. Prepare and verify the three files from the final clean commit.
3. Create a non-reused tag bound to that exact commit; verify local and remote targets.
4. Create a GitHub prerelease draft and upload only the allowlisted assets.
5. Check draft title/body, asset names/sizes and source-only status, then publish under the owner's release authorization.
6. Download every published asset again and compare its bytes/checksums and committed source. Verify the actual GitHub README/release rendering and final links.

Never upload the whole work directory or substitute a local TEST DMG. Published tags/assets should not be replaced; a corrected package receives a fresh version. GitHub's latest-full-release route excludes prereleases, so use the explicit tag for beta links. Source-download counts are not app installations or users.

## Future Monitoring Preview DMG

The configured package uses the production identifier `io.github.random6913.tilvero`, arm64, macOS 26.0+ and `mode=monitoring`. Monitoring/history/diagnostics need no administrator approval. This profile disables Keep Mac Awake, keyboard-backlight actions, native charge writes and privileged helper enrollment. It contains no helper executable, launch job or helper-trust enrollment metadata. Its behavior must not be inferred from the normal development bundle.

A trusted public DMG requires an owner-controlled Developer ID Application identity, matching Team ID, Hardened Runtime, notarization and actual quarantined downloaded-install acceptance. Missing credentials are a blocker, never an automatic downgrade to ad hoc. No enrollment, purchase, password collection, fake Team ID or security-protection bypass belongs to the release process. A Developer ID Installer certificate is not required for the planned drag-and-drop image.

After a source-only beta uses its tag, select a fresh beta tag and monotonically higher build for a later binary release. Commit the new configuration before source admission. Do not reuse the source prerelease's tag to attach a later, differently qualified binary.

The binary pipeline remains `scripts/release.py`:

```sh
python3 scripts/release.py preflight --commit <full-commit> \
  --signing-mode developer-id --identity '<Developer ID Application identity>'
python3 scripts/release.py prepare --commit <full-commit> \
  --signing-mode developer-id --identity '<Developer ID Application identity>' \
  --notary-profile '<existing-Keychain-profile>'
```

Only Keychain references are passed to the tool; credentials are not committed. Build an isolated export of the admitted commit in fresh DerivedData. Do not alter the running development app. Verify architecture, minimum OS, production identity, original icon, licenses and helper-free contents. Sign executable code inside-out and the app with Hardened Runtime; package a read-only DMG with the Applications shortcut and installation/legal information, then sign the DMG.

Submit the outer DMG with `notarytool`; require Accepted, inspect the log, staple and validate the ticket. Check the actual quarantined download, mounted copy, Applications installation, relaunch/update and relevant offline behavior. Local image creation or an ad-hoc signature does not prove that path. Compute final hashes after signing/stapling and verify corresponding source from the same commit. Only then may a matching Download for Mac action appear.

`release.py` keeps its separate DMG/source manifest and fail-closed publication gates. Local `--signing-mode adhoc` output is an internal TEST artifact, not an upload candidate. Its integrity verification does not confer public distribution trust.

## Data continuity and updates

Prototype and production stores have separate identities and must not be mutated concurrently. Production startup deliberately pairs allowlisted preferences, identity salt and history; failed migration cannot masquerade as successful empty history. Preserve the original data and verify the resulting records/settings.

The first update route is manual. A version owning hardware settings requires verified restoration and compatible controller/helper/journal state before replacement. Never infer that replacing an app updates a running helper. Sparkle, Homebrew and automatic updates are outside this release.

## Repository presentation

Keep EN/RU parity, the retained shipping logo, an honest source/download action, readable capabilities, explicit limits and useful support links. The gallery must contain actual native views with visibly labeled demo data or independently reviewed redacted captures. Generated decorative images are labeled illustrations; they must not imitate telemetry or qualification evidence. Preserve GPL/authorship and third-party notices. Do not add invented download numbers, unearned CI badges or screenshots implying unqualified control.

See [testing](TESTING.md), [installation](INSTALL.md), [compatibility](COMPATIBILITY.md), [changelog](../CHANGELOG.md) and the [roadmap](../ROADMAP.md).

## Primary references

- [Apple: packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple: notarization prerequisites](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub: releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub: immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
