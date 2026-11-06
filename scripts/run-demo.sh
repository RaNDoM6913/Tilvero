#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
echo 'Quit the live Tilvero instance first. A running instance is reopened, never silently switched into simulation.'
bash scripts/build-local-app.sh
open -n "$project_root/build/Tilvero.app" --args --demo
