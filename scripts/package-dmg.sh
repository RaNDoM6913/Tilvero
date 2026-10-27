#!/bin/bash
# Native UDZO packaging only. Signing/notarization/verification are coordinated by release.py.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app= metadata= output= signing_mode=
while (($#)); do
  case "$1" in
    --app) app="$2"; shift 2;;
    --metadata) metadata="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    --signing-mode) signing_mode="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ -d "$app" && -f "$metadata" && -n "$output" && ! -e "$output" ]] || { echo 'Supply a staged app, metadata and a new output path.' >&2; exit 2; }
[[ "$signing_mode" == adhoc || "$signing_mode" == developer-id ]] || exit 2
python3 - "$project_root" "$app" "$metadata" "$signing_mode" <<'PY'
import sys,json,importlib.util
from pathlib import Path
root,app,metadata,mode=map(str,sys.argv[1:])
s=importlib.util.spec_from_file_location('release',Path(root)/'scripts/release.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
c=m.load_config(Path(root)/'Config/Release.json');data=json.loads(Path(metadata).read_text())
if data.get('signingMode')!=mode:raise SystemExit('Signing mode metadata mismatch')
m.validate_app(Path(app),c,data,mode=='developer-id')
PY
staging="$(mktemp -d "${TMPDIR:-/tmp}/tilvero-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/payload"
ditto "$app" "$staging/payload/Tilvero.app"
ln -s /Applications "$staging/payload/Applications"
ditto "$app/Contents/Resources/Legal" "$staging/payload/Legal"
cp "$project_root/Assets/DMG/VolumeIcon.icns" "$staging/payload/.VolumeIcon.icns"
cp "$project_root/Assets/DMG/INSTALL.txt" "$staging/payload/INSTALL.txt"
volume='Tilvero Monitoring'
if [[ "$signing_mode" == adhoc ]]; then
  volume='Tilvero TEST - Not Notarized'
  { echo 'LOCAL AD-HOC TEST ONLY. NOT A TRUSTED PUBLIC DOWNLOAD.'; echo; cat "$staging/payload/INSTALL.txt"; } > "$staging/install-test.txt"
  mv "$staging/install-test.txt" "$staging/payload/INSTALL.txt"
fi
# Mark the source folder with the documented custom-icon bit before hdiutil snapshots it.
source "$project_root/scripts/toolchain.sh"
xcrun SetFile -a C "$staging/payload"
hdiutil create -quiet -format UDZO -fs HFS+ -volname "$volume" -srcfolder "$staging/payload" "$staging/image.dmg"
# output is intentionally an unverified name; the coordinator promotes only after inspection.
mv "$staging/image.dmg" "$output"
