# Tilvero publication graphics

Both READMEs open with the approved 1983 × 793 Midnight energy banner.
The 2026-11-18 revision uses a solid green fill for the small wave and smooths
the tips of both waves. Its three pills read **Swift 6**, **macOS 26+** and
**Apple silicon**. [Artwork provenance and checksum](COVER_PROMPT.md).

The README badge row uses Shields' `for-the-badge` style: 28 px high, Verdana
uppercase type, dark pine labels (`#172A22`) and green values (`#2F6E4B`).
The ZIP • CLONES • UNIQUE badge shows three separate values from the dated
snapshot in [GitHub traffic](../../docs/GITHUB_TRAFFIC.md). ZIP counts
source downloads excluding the verification download. CLONES counts all
reported clone events, and UNIQUE uses GitHub’s period-level unique count.
The row contains Source Preview, traffic and license badges.

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
