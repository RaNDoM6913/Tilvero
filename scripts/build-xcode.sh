#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
xcodebuild -project Tilvero.xcodeproj -scheme Tilvero -configuration Debug -derivedDataPath build/Xcode build CODE_SIGN_IDENTITY=-
