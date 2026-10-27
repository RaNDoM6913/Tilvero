#!/bin/bash
set -euo pipefail
source_file= output_directory=
while (($#)); do
  case "$1" in
    --source) source_file="$2"; shift 2;;
    --output) output_directory="$2"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -f "$source_file" && -n "$output_directory" && ! -e "$output_directory" ]] || { echo 'Supply a 1024px PNG and a new output directory.' >&2; exit 2; }
[[ "$(sips -g pixelWidth "$source_file" | awk '/pixelWidth/{print $2}')" == 1024 && "$(sips -g pixelHeight "$source_file" | awk '/pixelHeight/{print $2}')" == 1024 ]] || { echo 'Source must be 1024 x 1024.' >&2; exit 2; }
mkdir -p "$output_directory/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_file" --out "$output_directory/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$source_file" --out "$output_directory/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$output_directory/AppIcon.iconset" -o "$output_directory/AppIcon.icns"
