#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

# Restores the history copy Tilvero writes before a schema upgrade (History.pre-vN.sqlite), for a rollback to the
# previous app version. Quit Tilvero first: the script refuses while it runs. Nothing is deleted; the current store
# files are moved aside as History.vN-<timestamp>.sqlite{,-wal,-shm}.
#
#   bash scripts/restore-history-backup.sh [path/to/History.sqlite]
#
# Default: the production store, ~/Library/Application Support/Tilvero/Production/History.sqlite.
set -euo pipefail

store="${1:-$HOME/Library/Application Support/Tilvero/Production/History.sqlite}"
pgrep_tool="${TILVERO_PGREP:-/usr/bin/pgrep}"

echo "Quit Tilvero before restoring its history backup (menu bar battery → Quit)."
if "$pgrep_tool" -x TilveroApp >/dev/null 2>&1; then
  echo "Tilvero is running. Quit it, then run this script again." >&2
  exit 1
fi

directory="$(dirname "$store")"
base="$(basename "$store" .sqlite)"
backup=""
for candidate in "$directory/$base".pre-v*.sqlite; do
  [[ -f "$candidate" ]] && backup="$candidate"
done
if [[ -z "$backup" ]]; then
  echo "No backup ($base.pre-vN.sqlite) next to $store." >&2
  exit 1
fi
version="${backup##*.pre-v}"
version="${version%.sqlite}"
stamp="$(date +%Y%m%d-%H%M%S)"
aside="$directory/$base.v$version-$stamp.sqlite"

for suffix in "" "-wal" "-shm"; do
  if [[ -e "$aside$suffix" ]]; then
    echo "$aside$suffix already exists; nothing was changed." >&2
    exit 1
  fi
done
for suffix in "" "-wal" "-shm"; do
  if [[ -e "$store$suffix" ]]; then mv "$store$suffix" "$aside$suffix"; fi
done
if [[ -e "$store" ]]; then
  echo "Could not move $store aside; nothing was restored." >&2
  exit 1
fi
cp -p "$backup" "$store"
chmod 600 "$store"
echo "Restored $(basename "$backup") as $(basename "$store")."
echo "The upgraded store was kept as $(basename "$aside")*; the backup itself is unchanged."
