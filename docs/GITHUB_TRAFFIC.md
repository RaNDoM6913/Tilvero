# Tilvero GitHub traffic

Snapshot collected on 6 November 2026 UTC from the GitHub API.

| Metric | Value | Scope |
| --- | ---: | --- |
| Git clones | 720 | GitHub Traffic window, 23 October through 5 November 2026 UTC |
| Unique cloners | 246 | GitHub's `uniques` value for the same window |
| Source ZIP downloads | 6 | All four published custom source ZIPs |
| Source ZIP downloads excluding verification | 5 | The six reported downloads minus one project verification download |
| Downloads of uploaded release assets | 17 | Six source ZIP downloads, five manifest downloads and six checksum downloads |

The repository was created on 27 October. GitHub returned zero clones for
23–26 October and the following counts for 27 October through 5 November.

| Date (UTC) | Clones | Unique cloners that day |
| --- | ---: | ---: |
| 27 October | 20 | 11 |
| 28 October | 35 | 15 |
| 29 October | 56 | 26 |
| 30 October | 62 | 32 |
| 31 October | 33 | 16 |
| 1 November | 30 | 16 |
| 2 November | 33 | 17 |
| 3 November | 66 | 36 |
| 4 November | 297 | 74 |
| 5 November | 88 | 32 |

Use the API's window-level `uniques` for the whole period. Adding daily
unique counts can count the same client on more than one day. Clone traffic can
include automation, and GitHub reports these counts without identifying people.

| Release | Source ZIP | Manifest | Checksums |
| --- | ---: | ---: | ---: |
| `v0.1.0-beta.1` | 2 | 2 | 2 |
| `v0.1.0-beta.2` | 3 | 2 | 2 |
| `v0.2.0` | 1 | 1 | 2 |
| `v0.3.0-beta.1` | 0 | 0 | 0 |

The `v0.2.0` source ZIP count includes the download used to check the published
archive; the `v0.3.0-beta.1` counters were still zero a few minutes after publication, and GitHub may update them with a delay. The releases contain source and metadata. GitHub lists no uploaded app
or DMG for this snapshot, and the asset counts exclude GitHub's generated source
archives. Successful installations are unmeasured.

For a README badge, label the metric and date. The same client may download a ZIP
and clone the repository, and release downloads and clone traffic cover different
periods.

[GitHub clone traffic API](https://docs.github.com/en/rest/metrics/traffic#get-repository-clones) ·
[GitHub release asset API](https://docs.github.com/en/rest/releases/assets#list-release-assets) ·
[Tilvero releases](https://github.com/RaNDoM6913/Tilvero/releases)
