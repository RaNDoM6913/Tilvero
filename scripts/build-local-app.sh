#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
[[ "$(uname -s)" == Darwin ]] || { echo 'Building Tilvero requires macOS.' >&2; exit 1; }
app_directory="$project_root/build/Tilvero.app"
if (($#)); then
  [[ "$#" == 2 && "$1" == --output ]] || { echo 'Usage: build-local-app.sh [--output <new-app-path>]' >&2; exit 2; }
  app_directory="$2"
  [[ "$app_directory" == /* ]] || app_directory="$project_root/$app_directory"
  [[ ! -e "$app_directory" && ! -L "$app_directory" ]] || { echo 'Output already exists; preserve it and choose a fresh path.' >&2; exit 2; }
fi
swift build -c release --product TilveroApp
swift build -c release --product TilveroHelper
binary_directory="$(swift build -c release --show-bin-path)"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Library/HelperTools" "$app_directory/Contents/Library/LaunchDaemons"
cp "$binary_directory/TilveroApp" "$app_directory/Contents/MacOS/TilveroApp"
cp "$binary_directory/TilveroHelper" "$app_directory/Contents/Library/HelperTools/TilveroHelper"
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
plutil -lint "$app_directory/Contents/Info.plist"
codesign --force --sign - "$app_directory/Contents/Library/HelperTools/TilveroHelper"
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
echo "Built local ad-hoc app: $app_directory"
echo 'The helper is bundled but not registered; signing and hardware gates remain closed.'
