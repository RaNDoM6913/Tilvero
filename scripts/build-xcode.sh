#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
configuration=Debug
derived_data="$project_root/build/Xcode"
output= release_config=
while (($#)); do
  case "$1" in
    --configuration) configuration="$2"; shift 2;;
    --derived-data) derived_data="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    --release-config) release_config="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ "$configuration" == Debug || "$configuration" == Release ]] || exit 2
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
xcodebuild -project Tilvero.xcodeproj -scheme Tilvero -configuration "$configuration" -derivedDataPath "$derived_data" build CODE_SIGN_IDENTITY=-
if [[ -n "$output" ]]; then
  [[ ! -e "$output" ]] || exit 2
  mkdir -p "$(dirname "$output")"
  ditto "$derived_data/Build/Products/$configuration/Tilvero.app" "$output"
fi
