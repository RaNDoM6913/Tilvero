#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

# Build "Tilvero First Run.app": the first-run flow as its own app, for playing it safely.
# Own bundle identifier, name and data scope, so it never competes with an installed Tilvero
# (the second-copy guard keys on the bundle identifier). Isolated preferences, fake privileged prompt.
# Usage: build-first-run-preview.sh [<output folder>]   (default: build/dev-candidates.noindex/first-run-preview)
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
folder="${1:-$project_root/build/dev-candidates.noindex/first-run-preview}"
[[ "$folder" == /* ]] || folder="$project_root/$folder"
[[ "$folder" == *.noindex* || "$folder" != "$project_root/build/"* ]] || { echo 'Use a .noindex folder inside build/.' >&2; exit 2; }
app="$folder/Tilvero First Run.app"
[[ ! -e "$app" && ! -L "$app" ]] || { echo "Output exists: $app. Choose a fresh folder." >&2; exit 2; }
mkdir -p "$folder"
bash "$project_root/scripts/build-local-app.sh" --output "$app"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.tilvero.firstrun "$plist"
plutil -replace CFBundleName -string 'Tilvero First Run' "$plist"
plutil -replace CFBundleDisplayName -string 'Tilvero First Run' "$plist"
plutil -replace TilveroDataScope -string first-run-preview "$plist"
plutil -lint "$plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built: $app"
echo "Open it like any app (double-click or: open \"$app\"). It is always a preview: it never touches Tilvero's settings, history or helpers."
