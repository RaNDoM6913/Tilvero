#!/bin/bash
# Build the complete current app into a fresh hidden laboratory candidate.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$project_root/scripts/build-local-app.sh" --laboratory "$@"
