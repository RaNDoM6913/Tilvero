#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
[[ "$(uname -s)" == Darwin ]] || { echo 'Building Tilvero requires macOS.' >&2; exit 1; }
swift build -c release --product TilveroApp
swift build -c release --product TilveroHelper
binary_directory="$(swift build -c release --show-bin-path)"
app_directory="$project_root/build/Tilvero.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Library/HelperTools" "$app_directory/Contents/Library/LaunchDaemons"
cp "$binary_directory/TilveroApp" "$app_directory/Contents/MacOS/TilveroApp"
cp "$binary_directory/TilveroHelper" "$app_directory/Contents/Library/HelperTools/TilveroHelper"
cp "$project_root/Config/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Config/LaunchDaemons/"*.plist "$app_directory/Contents/Library/LaunchDaemons/"
cp "$project_root/Sources/TilveroApp/Resources/Localizable.xcstrings" "$app_directory/Contents/Resources/"
cp "$project_root/Helper/THIRD_PARTY_NOTICES.md" "$app_directory/Contents/Resources/THIRD_PARTY_NOTICES.md"
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
