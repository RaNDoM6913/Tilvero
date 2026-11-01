#!/bin/bash
# Build the complete editable Studio from current application sources.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --application-only ]]; then
  shift
  exec bash "$project_root/scripts/build-local-app.sh" --laboratory "$@"
fi
studio_builder="$project_root/local-lab/studio/build.py"
[[ -f "$studio_builder" ]] || { echo 'Local Studio sources are required. Use --application-only for the plain shared application candidate.' >&2; exit 2; }
exec python3 "$studio_builder" "$@"
