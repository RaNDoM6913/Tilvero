#!/bin/bash
set -euo pipefail
[[ "$#" == 0 ]] || { echo 'Usage: run-local.sh' >&2; exit 2; }
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_directory="$project_root/build/Tilvero.app"
[[ -d "$app_directory" ]] || { echo 'Build the local app first with scripts/build-local-app.sh.' >&2; exit 1; }
# Launch this exact bundle so its instance guard, rather than LaunchServices'
# ambiguous bundle-ID resolution, handles any already running development copy.
open -n "$app_directory"
