# Tilvero publication graphics

Both language versions of the README open with `cover.png`: the owner-selected
dark energy-wave banner, generated with the built-in ImageGen tool on 2026-10-31
and selected on 2026-11-01. It uses the current wave identity from
[`Assets/AppIcon.png`](../../Assets/AppIcon.png). The original 1983 × 793 PNG is
retained without edits; see [its prompt, copy and SHA-256](COVER_PROMPT.md).
Its three information pills read **Swift 6**, **macOS 26+** and **Apple silicon**;
availability is **Source preview**. This is brand artwork, not an app screenshot
or a claim of hardware support or release qualification. The app icon files are
unchanged by this README refresh.

The README badge row uses Shields' `for-the-badge` style: 28 px high, Verdana
uppercase type, dark pine labels (`#172A22`) and green values (`#2F6E4B`).
Source Downloads shows the dated GitHub snapshot explained in both READMEs.
It counts custom source ZIP downloads across releases and excludes the
project’s verification download. Stars come from the repository count.

The bilingual gallery in `screenshots/` renders actual SwiftUI views using isolated synthetic fixtures; every frame visibly identifies demo data. It is not owner telemetry or binary/hardware acceptance.

The power-loop vector artwork below was composed for this repository on
2026-10-27 and is retained as earlier publication artwork. It is not the current
wave identity used by the README.
These are publication graphics, not app screenshots, hardware readings, or a replacement application icon.

| Asset | Canvas | Use |
| --- | --- | --- |
| `hero.svg` | 1280 × 480 | Earlier README banner |
| `mark.svg` | 256 × 256 | Standalone publication brand mark |
| `social-preview.svg` | 1280 × 640 | Editable source for the social preview |
| `social-preview.png` | 1280 × 640 | GitHub social preview upload |

## Source and typography

The square power-loop and composition were drawn as original SVG geometry; no external illustration, Apple logo, SF Symbol, or app screenshot was copied.
Typography was rendered from the macOS system-installed Avenir Next family with CoreText and converted to glyph outlines. Font files are not embedded or distributed. Each outlined text element retains its copy in `data-copy` and `aria-label` attributes; the SVG title and description provide an accessible text equivalent.

The vectors have an opaque warm light background so their contrast remains stable in GitHub light and dark themes. Palette: paper `#F6F7F1`, ink `#26362F`, muted text `#5A6B60`, green `#A6D883`, rule `#D9E2D5`.

## Re-render

With an existing librsvg installation, from the repository root:

```sh
rsvg-convert .github/assets/social-preview.svg -o .github/assets/social-preview.png
```

The exported PNG was rendered and visually inspected at its native size and at 640 × 320. No telemetry, hardware-control acceptance, or product release status is represented by this artwork. Repository licensing applies to the original composition; this is not a grant of rights to the underlying typeface software.
