#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"
command -v swift >/dev/null || { echo "A Swift 6+ toolchain is required." >&2; exit 1; }
swift test "$@"
