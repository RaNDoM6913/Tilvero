# Application and disk-image artwork

Original Tilvero artwork, Copyright (c) 2026 RaNDoM6913, GPL-3.0-only.

The default light icon uses the outline of the small wave in the approved
README banner. The wave has a uniform green fill (`#17AA50`).
`AppIcon.svg` is the editable master. `AppIcon.png` and `AppIcon-1024.png`
are the approved 1024 px raster. Xcode uses the ten macOS renditions in
`Config/Assets.xcassets/AppIcon.appiconset`. SwiftPM packaging uses
`AppIcon.icns`.

To export the master, install librsvg and ImageMagick and run from the repository:

```sh
swift scripts/render-app-icon.swift /tmp/Tilvero-Light.png
bash scripts/generate-app-icons.sh --source /tmp/Tilvero-Light.png --output /tmp/Tilvero-Light-export
```

`IconVariants/Tilvero-Night` and `IconVariants/Tilvero-Mono` preserve the
approved alternatives for a future Settings selector. Each contains an SVG
master, a 1024 px PNG and a macOS ICNS. Both use the light icon's wave outline.

The disk-image volume has separate artwork in `DMG/VolumeIcon.icns`.
