#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

# Build Tilvero from this checkout and install it into Applications in one step.
# Safe for people and AI agents to run unattended: it checks requirements first,
# never replaces a running copy or a team-signed install, keeps the previous
# copy for rollback, and changes no charging, fan, power or sleep setting.

set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/toolchain.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [--applications-dir <dir>] [--with-tests] [--no-launch] [--check] [--replace-signed]

  --applications-dir <dir>  Install into <dir> instead of /Applications (e.g. ~/Applications).
  --with-tests              Run the automated test suite before building (several minutes).
  --no-launch               Install without opening Tilvero afterwards.
  --check                   Only check the requirements, then exit.
  --replace-signed          Allow replacing an existing Developer ID / team-signed Tilvero.
USAGE
}

applications_dir=/Applications
with_tests=false
launch=true
check_only=false
replace_signed=false
while (($#)); do
  case "$1" in
    --applications-dir)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      applications_dir="$2"; shift 2 ;;
    --with-tests) with_tests=true; shift ;;
    --no-launch) launch=false; shift ;;
    --check) check_only=true; shift ;;
    --replace-signed) replace_signed=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fail() { echo "Tilvero install: $1" >&2; exit 1; }
step() { echo "==> $1"; }

step 'Checking requirements'
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
[[ "$(uname -m)" == arm64 ]] || fail 'an Apple silicon Mac (arm64) is required.'
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 26 ]] \
  || fail "macOS 26.0 or later is required (this Mac runs $(sw_vers -productVersion))."
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ -z "$developer_dir" || "$developer_dir" == *CommandLineTools* ]] \
  || ! xcodebuild -version >/dev/null 2>&1; then
  fail 'a full Xcode installation is required (Command Line Tools alone are not enough). Install Xcode from the App Store, open it once, then run this script again.'
fi
command -v swift >/dev/null 2>&1 || fail 'swift was not found in the selected Xcode.'
echo "    macOS $(sw_vers -productVersion), $(xcodebuild -version | head -1), $(uname -m)"
if [[ "$check_only" == true ]]; then
  echo 'All requirements are met.'
  exit 0
fi

[[ -d "$applications_dir" ]] || fail "$applications_dir does not exist."
applications_dir="$(cd "$applications_dir" && pwd)"
[[ -w "$applications_dir" ]] \
  || fail "$applications_dir is not writable by this user. Use --applications-dir ~/Applications instead."
target="$applications_dir/Tilvero.app"

if [[ -e "$target" ]]; then
  running_executable="$(cd "$target/Contents/MacOS" 2>/dev/null && pwd -P || true)/TilveroApp"
  if /bin/ps -axo comm= | grep -Fxq "$running_executable"; then
    fail 'Tilvero is running from that location. Quit it from its menu (Quit Tilvero), then run this script again.'
  fi
  signature="$(codesign -dv "$target" 2>&1 || true)"
  if ! grep -q 'Signature=adhoc' <<<"$signature" && [[ "$replace_signed" == false ]]; then
    fail "$target is a signed build, not a local source build. Keep it, install elsewhere with --applications-dir, or pass --replace-signed."
  fi
fi

if [[ "$with_tests" == true ]]; then
  step 'Running the automated tests (they never change charging, fan, power or sleep settings)'
  bash "$project_root/scripts/test.sh"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
staging_root="$project_root/build/install.noindex/$stamp"
mkdir -p "$staging_root"
step 'Building Tilvero (the first build downloads Sparkle and takes a few minutes)'
bash "$project_root/scripts/build-local-app.sh" --output "$staging_root/Tilvero.app"

if [[ -e "$target" ]]; then
  step "Keeping the previous copy in build/install.noindex/$stamp/previous/"
  mkdir -p "$staging_root/previous"
  mv "$target" "$staging_root/previous/Tilvero.app"
fi
step "Installing to $target"
ditto "$staging_root/Tilvero.app" "$target"
codesign --verify --strict "$target"
# The installed copy is the build; keep only the rollback copies of the last three installs.
rm -rf "$staging_root/Tilvero.app"
rmdir "$staging_root" 2>/dev/null || true
{ ls -1d "$project_root/build/install.noindex"/*/ 2>/dev/null || true; } | sort -r | tail -n +4 | while IFS= read -r old; do
  rm -rf "$old"
done

echo
echo "Tilvero is installed at $target."
echo 'It lives in the menu bar: click the battery icon for the quick menu.'
echo 'Your history and settings stay on this Mac. To remove Tilvero, quit it and move the app to the Trash.'
if [[ "$launch" == true ]]; then
  open "$target"
fi
