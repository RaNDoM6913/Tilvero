#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
[[ "$(uname -s)" == Darwin ]] || { echo 'Building Tilvero requires macOS.' >&2; exit 1; }
app_directory="$project_root/build/Tilvero.app"
laboratory=false
studio=false
explicit_output=false
while (($#)); do
  case "$1" in
    --laboratory)
      [[ "$laboratory" == false ]] || { echo 'Duplicate --laboratory option.' >&2; exit 2; }
      laboratory=true
      shift
      ;;
    --studio) studio=true; shift ;;
    --output)
      [[ "$#" -ge 2 && "$explicit_output" == false ]] || { echo 'Usage: build-local-app.sh [--laboratory] [--output <new-app-path>]' >&2; exit 2; }
      app_directory="$2"
      explicit_output=true
      shift 2
      ;;
    *) echo 'Usage: build-local-app.sh [--laboratory] [--output <new-app-path>]' >&2; exit 2 ;;
  esac
done
if [[ "$studio" == true ]]; then
  [[ "$laboratory" == true && -f Config/StudioBuild.json ]] || { echo 'Studio requires an explicit hidden source snapshot and laboratory packaging.' >&2; exit 2; }
  python3 - <<'PY_STUDIO'
import json
from pathlib import Path
p=json.loads(Path('Config/StudioBuild.json').read_text())
assert p['kind']=='tilvero-studio-source-snapshot' and p['compileDefine']=='TILVERO_LAB_STUDIO'
assert p['studioSources'] and all(Path(name).is_file() for name in p['studioSources'])
PY_STUDIO
fi
swift_build() {
  if [[ "$studio" == true ]]; then
    swift build -Xswiftc -DTILVERO_LAB_STUDIO "$@"
  else
    swift build "$@"
  fi
}
if [[ "$laboratory" == true ]]; then
  lab_arguments=(prepare --project-root "$project_root")
  [[ "$explicit_output" == false ]] || lab_arguments+=(--app "$app_directory")
  app_directory="$(python3 "$project_root/scripts/local_app_package.py" "${lab_arguments[@]}")"
elif [[ "$explicit_output" == true ]]; then
  [[ "$app_directory" == /* ]] || app_directory="$project_root/$app_directory"
  [[ ! -e "$app_directory" && ! -L "$app_directory" ]] || { echo 'Output already exists; preserve it and choose a fresh path.' >&2; exit 2; }
  if [[ "$app_directory" == "$project_root/build/"* && "$app_directory" != "$project_root/build/Tilvero.app" && "$app_directory" != *".noindex/"* ]]; then
    echo 'Development candidates inside build/ must use a .noindex folder, such as build/dev-candidates.noindex/example/Tilvero.app, to keep duplicate apps out of macOS search.' >&2
    exit 2
  fi
fi
# Never overwrite executable/resources under a live process. Use a fresh candidate
# or quit normally first, so restoration and history shutdown can complete.
# Laboratory preparation has already atomically reserved a fresh empty app.
if [[ "$laboratory" == false && -e "$app_directory" ]]; then
python3 - "$app_directory" <<'PY_PREFLIGHT'
from pathlib import Path
import subprocess, sys
executable = (Path(sys.argv[1]) / 'Contents/MacOS/TilveroApp').resolve()
result = subprocess.run(['/bin/ps', '-axo', 'comm='], check=True, capture_output=True, text=True)
if any(Path(line.strip()).resolve() == executable for line in result.stdout.splitlines() if line.strip()):
    raise SystemExit('Output app is running. Quit Tilvero normally or use --output with a fresh candidate path.')
PY_PREFLIGHT
fi
swift_build -c release --product TilveroApp
swift_build -c release --product TilveroHelper
swift_build -c release --product TilveroLidHelper
binary_directory="$(swift_build -c release --show-bin-path)"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Library/HelperTools" "$app_directory/Contents/Library/LaunchDaemons"
cp "$binary_directory/TilveroApp" "$app_directory/Contents/MacOS/TilveroApp"
cp "$binary_directory/TilveroHelper" "$app_directory/Contents/Library/HelperTools/TilveroHelper"
cp "$binary_directory/TilveroLidHelper" "$app_directory/Contents/Library/HelperTools/TilveroLidHelper"
cp "$project_root/Config/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Config/LaunchDaemons/"*.plist "$app_directory/Contents/Library/LaunchDaemons/"
cp "$project_root/Sources/TilveroApp/Resources/Localizable.xcstrings" "$app_directory/Contents/Resources/"
mkdir -p "$app_directory/Contents/Resources/Legal/Helper"
cp "$project_root/LICENSE" "$project_root/COPYRIGHT" "$project_root/THIRD_PARTY_NOTICES.md" "$app_directory/Contents/Resources/Legal/"
cp "$project_root/Helper/THIRD_PARTY_NOTICES.md" "$app_directory/Contents/Resources/Legal/Helper/"
cp "$project_root/Assets/AppIcon.icns" "$app_directory/Contents/Resources/"
# SwiftPM searches the application resource directory before its command-line fallback.
while IFS= read -r -d '' resource; do
  ditto "$resource" "$app_directory/Contents/Resources/$(basename "$resource")"
done < <(find "$binary_directory" -maxdepth 1 -type d -name '*TilveroApp*.bundle' -print0)
if [[ "$laboratory" == true ]]; then
  python3 "$project_root/scripts/local_app_package.py" capture --project-root "$project_root" --app "$app_directory" --binary-directory "$binary_directory"
fi
plutil -lint "$app_directory/Contents/Info.plist"
codesign --force --sign - "$app_directory/Contents/Library/HelperTools/TilveroHelper"
codesign --force --sign - "$app_directory/Contents/Library/HelperTools/TilveroLidHelper"
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
if [[ "$laboratory" == true ]]; then
  python3 "$project_root/scripts/local_app_package.py" finish --project-root "$project_root" --app "$app_directory"
  echo "Built hidden shared-source laboratory candidate: $app_directory"
  echo "Local provenance receipt: $(dirname "$app_directory")/build-receipt.json"
  echo 'Promotion and native acceptance are separate; this builder never launches or replaces an app.'
  exit 0
fi
echo "Built local ad-hoc app: $app_directory"
echo 'The helper is bundled but not registered; signing and hardware gates remain closed.'
