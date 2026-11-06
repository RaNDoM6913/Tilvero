#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
configuration=Debug
derived_data="$project_root/build/Xcode.noindex"
output= release_config= app_info= helper_info=
while (($#)); do
  case "$1" in
    --configuration) configuration="$2"; shift 2;;
    --derived-data) derived_data="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    --release-config) release_config="$2"; shift 2;;
    --app-info) app_info="$2"; shift 2;;
    --helper-info) helper_info="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ "$configuration" == Debug || "$configuration" == Release ]] || exit 2
if [[ -n "$release_config" && ( -n "$app_info" || -n "$helper_info" ) ]]; then
  echo 'Explicit local metadata cannot be combined with release configuration.' >&2; exit 2
fi
for metadata in "$app_info" "$helper_info"; do
  [[ -z "$metadata" || ( -f "$metadata" && ! -L "$metadata" ) ]] || { echo 'Metadata must be an existing regular plist.' >&2; exit 2; }
done
if [[ -n "$release_config" ]]; then
  [[ "$configuration" == Release && -n "$output" && ! -e "$output" && ! -e "$derived_data" ]] || { echo 'Release requires fresh explicit output/DerivedData.' >&2; exit 2; }
  [[ -n "${TILVERO_RELEASE_COMMIT:-}" ]] || { echo 'Use release.py for source-bound release builds.' >&2; exit 2; }
  python3 - "$release_config" <<'PY'
import json,plistlib,sys
from pathlib import Path
c=json.loads(Path(sys.argv[1]).read_text())
p=plistlib.loads(Path('Config/Info.plist').read_bytes())
p.update(CFBundleIdentifier=c['bundleID'],CFBundleShortVersionString=c['version'],CFBundleVersion=c['build'],LSMinimumSystemVersion=c['minimumOS'],TilveroDataScope='production',TilveroReleaseMode=c['mode'])
Path('Config/ReleaseInfo.plist').write_bytes(plistlib.dumps(p))
PY
  python3 scripts/generate-xcode-project.py --release-config "$release_config"
fi
updater_info="$derived_data/UpdaterInfo.plist"
mkdir -p "$derived_data"
if [[ -n "$release_config" ]]; then
  cp Config/ReleaseInfo.plist "$updater_info"
elif [[ -n "$app_info" ]]; then
  cp "$app_info" "$updater_info"
else
  cp Config/Info.plist "$updater_info"
fi
python3 scripts/updater_package.py configure --info "$updater_info" --config Config/Updater.json
set -- xcodebuild -project Tilvero.xcodeproj -scheme Tilvero -configuration "$configuration" -derivedDataPath "$derived_data" build CODE_SIGN_IDENTITY=- "TILVERO_APP_INFO_PLIST=$updater_info"
if [[ -n "$helper_info" ]]; then set -- "$@" "TILVERO_HELPER_INFO_PLIST=$helper_info"; fi
"$@"
if [[ -n "$output" ]]; then
  [[ ! -e "$output" ]] || exit 2
  mkdir -p "$(dirname "$output")"
  ditto "$derived_data/Build/Products/$configuration/Tilvero.app" "$output"
fi
