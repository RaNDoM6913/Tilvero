#!/usr/bin/env python3
"""On-demand GitHub DMG download observations. Never contacts Tilvero users."""

import argparse
from datetime import datetime, timezone
import json
import re
import subprocess


ASSET_PATTERN = re.compile(r"Tilvero-.+-arm64\.dmg\Z")
REPO_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
CHANNELS = ("all", "beta", "stable")
SCOPE_NOTE = ("Currently visible published uploaded Tilvero-*-arm64.dmg assets only; "
              "downloads can include repeat, bot and test requests. Not people, installations or active users.")


class StatsError(Exception):
    """The observation cannot be completed honestly."""


class GhAPI:
    """Use the owner's existing gh authorization; GET requests only, no login changes."""

    def get_json(self, endpoint):
        try:
            result = subprocess.run(
                ["gh", "api", "--method", "GET", "--hostname", "github.com",
                 "-H", "Accept: application/vnd.github+json",
                 "-H", "X-GitHub-Api-Version: 2022-11-28", endpoint],
                capture_output=True, text=True, timeout=30, check=False,
            )
        except FileNotFoundError as exc:
            raise StatsError("GitHub CLI unavailable; install gh and authorize it separately.") from exc
        except subprocess.TimeoutExpired as exc:
            raise StatsError("GitHub request timed out.") from exc
        if result.returncode:
            # Do not echo arbitrary external stderr (may contain credentials or private paths).
            if "rate limit" in result.stderr.lower():
                reason = "GitHub API rate limit reached."
            else:
                status = re.search(r"HTTP (\d{3})", result.stderr)
                reason = f"GitHub API HTTP {status.group(1)}." if status else "GitHub request failed; check gh access separately."
            raise StatsError(reason)
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError) as exc:
            raise StatsError("GitHub returned invalid JSON.") from exc


def _positive_id(value, kind):
    if type(value) is not int or value <= 0:
        raise StatsError(f"Invalid {kind} ID.")
    return value


def _selected_releases(releases, channel):
    if channel not in CHANNELS or not isinstance(releases, list):
        raise StatsError("Invalid channel or releases response.")
    selected = {}
    for item in releases:
        if not isinstance(item, dict) or type(item.get("draft")) is not bool:
            raise StatsError("Invalid release metadata.")
        if item["draft"]:
            continue
        if type(item.get("prerelease")) is not bool:
            raise StatsError("Invalid release channel.")
        if not item.get("published_at"):
            continue
        if not isinstance(item["published_at"], str) or not isinstance(item.get("tag_name"), str) or not item["tag_name"]:
            raise StatsError("Invalid published release metadata.")
        if channel != "all" and item["prerelease"] != (channel == "beta"):
            continue
        identifier = _positive_id(item.get("id"), "release")
        metadata = {key: item[key] for key in ("id", "tag_name", "prerelease", "published_at")}
        if identifier in selected and selected[identifier] != metadata:
            raise StatsError("Release changed during pagination; retry for a fresh observation.")
        selected[identifier] = metadata
    return selected


def collect_downloads(releases, asset_pages, channel):
    """Pure aggregation. asset_pages maps release IDs to complete lists of asset pages.

    Inline release.assets is intentionally ignored: it may be truncated. Missing
    pages or conflicting duplicate IDs are errors, never plausible partial totals.
    """
    selected = _selected_releases(releases, channel)
    per_release, per_asset, seen = [], [], {}
    for release_id, item in selected.items():
        if release_id not in asset_pages or not isinstance(asset_pages[release_id], list) or not asset_pages[release_id]:
            raise StatsError("Missing asset pages for a selected release.")
        total = 0
        counted = 0
        for page in asset_pages[release_id]:
            if not isinstance(page, list):
                raise StatsError("Invalid assets response.")
            for asset in page:
                if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
                    raise StatsError("Invalid asset metadata.")
                asset_id = _positive_id(asset.get("id"), "asset")
                identity = (release_id, asset["name"], asset.get("state"), asset.get("download_count"))
                if asset_id in seen:
                    if seen[asset_id] != identity:
                        raise StatsError("Asset changed during pagination; retry for a fresh observation.")
                    continue
                seen[asset_id] = identity
                if asset.get("state") != "uploaded" or not ASSET_PATTERN.fullmatch(asset["name"]):
                    continue
                count = asset.get("download_count")
                if type(count) is not int or count < 0:
                    raise StatsError("Invalid DMG download count.")
                record = {"releaseId": release_id, "tag": item["tag_name"],
                          "channel": "beta" if item["prerelease"] else "stable",
                          "assetId": asset_id, "name": asset["name"], "downloadCount": count}
                per_asset.append(record)
                total += count
                counted += 1
        per_release.append({"releaseId": release_id, "tag": item["tag_name"],
                            "channel": "beta" if item["prerelease"] else "stable",
                            "dmgDownloads": total, "dmgAssets": counted})
    return {"dmgDownloads": sum(item["dmgDownloads"] for item in per_release),
            "perRelease": per_release, "perAsset": per_asset}


def _pages(api, endpoint):
    pages, page = [], 1
    while True:
        response = api.get_json(f"{endpoint}?per_page=100&page={page}")
        if not isinstance(response, list) or len(response) > 100:
            raise StatsError("Invalid paginated GitHub response.")
        pages.append(response)
        if len(response) < 100:
            return pages
        page += 1


def fetch_report(repo, channel, api, *, now=None):
    """Observe once. A failed page discards partial totals; no cache timestamp refresh."""
    if not isinstance(repo, str) or not REPO_PATTERN.fullmatch(repo):
        raise StatsError("Repository must be owner/name on github.com.")
    if channel not in CHANNELS:
        raise StatsError("Channel must be all, beta or stable.")
    timestamp = now or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    report = {"availability": "unavailable", "retrievedAt": None, "attemptedAt": timestamp,
              "scope": {"repository": repo, "channel": channel, "note": SCOPE_NOTE},
              "dmgDownloads": None, "perRelease": [], "perAsset": []}
    try:
        releases = [item for page in _pages(api, f"repos/{repo}/releases") for item in page]
        selected = _selected_releases(releases, channel)
        asset_pages = {identifier: _pages(api, f"repos/{repo}/releases/{identifier}/assets")
                       for identifier in selected}
        report.update(collect_downloads(releases, asset_pages, channel))
        report.update(availability="available", retrievedAt=timestamp)
    except (StatsError, TimeoutError, OSError) as exc:
        report["error"] = str(exc) if isinstance(exc, StatsError) else "GitHub transport unavailable."
    return report


def render_table(report):
    lines = [f"Repository: {report['scope']['repository']} | channel: {report['scope']['channel']}"]
    if report["availability"] != "available":
        lines.extend([f"Attempted at: {report['attemptedAt']}", f"Unavailable: {report['error']}"])
    else:
        lines.extend([f"Retrieved at: {report['retrievedAt']}", f"DMG downloads: {report['dmgDownloads']}"])
        if not report["perAsset"]:
            lines.append("No published DMGs in this scope.")
        else:
            lines.extend(["Tag\tChannel\tAsset\tDownloads"] +
                         [f"{a['tag']}\t{a['channel']}\t{a['name']}\t{a['downloadCount']}" for a in report["perAsset"]])
    lines.append(report["scope"]["note"])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/name on github.com")
    parser.add_argument("--channel", choices=CHANNELS, default="all")
    parser.add_argument("--format", choices=("json", "table"), default="table")
    args = parser.parse_args(argv)
    try:
        report = fetch_report(args.repo, args.channel, GhAPI())
    except StatsError as exc:
        parser.error(str(exc))
    print(json.dumps(report, indent=2) if args.format == "json" else render_table(report))
    return 0 if report["availability"] == "available" else 2


if __name__ == "__main__":
    raise SystemExit(main())
