# Native energy artwork

`Sources/TilveroApp/Resources/BatteryAssembly.png` is original schematic artwork generated for Tilvero with the built-in OpenAI image-generation tool in October2026. Its visual references were the project's previously generated Circuit and Glass Core proposals. No third-party screenshot or manufacturer photograph was copied into the shipped asset.

The image is an illustrative graphite battery enclosure with an optical-glass cover. It contains no telemetry, charge-level fill, manufacturer marks or device identifiers. It must not be used to infer a Mac's physical cell layout. The application displays the reported charge separately in text and an exact progress bar.

`AdapterIllustration.png` and `MacIllustration.png` in the same resource directory were generated in the same workflow as original unbranded schematic product illustrations. They do not identify a detected device model, adapter rating or hardware capability. Source connection and numeric measurements are presented independently of those images. All three source images have alpha transparency and are cached once when first used.

`RestIllustration.png` is original transparent artwork generated with the built-in tool on2026-10-29 for the Sleep & drain header. The closed unbranded notebook and sculptural moon are decorative, not evidence of a detected model or sleep state. The exact prompt is retained in `planning/docs/full-product-ui-20261029/ARTWORK_PROMPT.md`.

The energy-line branding mark is an original code-native path in `TilveroEnergyMark`, shared with the application/Dock icon. It is not an activity chart. The icon is rendered deterministically with AppKit from the same curve, with a green line on a softly shaded neutral tile; no external icon or font is copied.
