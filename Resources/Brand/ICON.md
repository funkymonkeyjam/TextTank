# Production icon source

`carbon-caret-app-square.svg` is the single production source of truth. It is the reviewed, original Carbon Caret unmasked square: carbon background, citrus left T, paper right T, and negative-space caret. Its SHA-256 is `5cf284f6f2438e672faaaf50106d4f301a63be80696c3392f70482712f0acbb1`.

Run `./scripts/build-icon.sh` from the repository. The script uses only the installed macOS Swift/AppKit/CoreGraphics/ImageIO frameworks. It strictly renders the source's M/H/V/Z paths and solid rectangle, preserving geometry. It creates conventional `Resources/TextTank.icns` with all ten standard 1×/2× representations (16, 32, 128, 256 and 512 logical pixels, up to 1024 physical pixels). Explicit 72/144 DPI distinguishes Retina entries. Temporary iconsets and the compiler cache are under ignored `.build/icon-tool/`.

The application plist should use `CFBundleIconFile = TextTank`. No rounded presentation raster or competing asset catalog is a production source. This is a deliberate conventional square legacy fallback for the macOS 14 target. Icon Composer and newer appearance variants are not packaged or validated; older-system and actual Dock appearance still require runtime verification.

Observed 14 November 2026: generation succeeded; `iconutil -c iconset` decoded all ten representations from the ICNS; chunk structure includes `ic10` through `ic14`; the 512-pixel source raster and decoded 1024-pixel representation were visually inspected and preserve the reviewed geometry and colors. The generated ICNS SHA-256 is `ad63b96ce98fbac1d6acb0c4156323c16b76f0cd061aee8e7341a204ce7ea3c9`. This does not certify Dock/older-OS appearance.

The TT/caret symbol is original TextTank project artwork. The separate outlined wordmark derives from Space Grotesk; retain its OFL notice. Inter's accompanying OFL notice is likewise retained. Native controls use system fonts; no font rendering is needed to generate the symbol icon.
