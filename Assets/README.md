# Application and disk-image artwork

Original Tilvero artwork, Copyright (c) 2026 RaNDoM6913, GPL-3.0-only.
`AppIcon.svg` is the editable vector composition; `scripts/render-app-icon.swift`
exports its AppKit geometry at exactly 1024 pixels (independent of display scale).
No third-party artwork, fonts or Apple system icons are copied.

Regenerate on macOS using the selected full Xcode toolchain:

```sh
source scripts/toolchain.sh
swift scripts/render-app-icon.swift Assets/AppIcon-1024.png
bash scripts/generate-app-icons.sh --source Assets/AppIcon-1024.png --output /new/export/directory
```

The resulting ICNS is checked in as `AppIcon.icns` and `DMG/VolumeIcon.icns`;
PNG sizes and Contents.json in Config/Assets.xcassets/AppIcon.appiconset are the
corresponding macOS asset catalog. The volume uses the same original mark.
The initial DMG deliberately uses native Finder layout without a background or
third-party layout dependency. Finder/Dock and trusted installed UI acceptance
remain distinct from inspecting these exported pixels.
