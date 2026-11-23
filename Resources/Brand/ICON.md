# Production icon source

`carbon-caret-app-square.svg` is the single production source of truth. It is the reviewed, original Carbon Caret unmasked square: carbon background, citrus left T, paper right T, and negative-space caret. Its SHA-256 is `5cf284f6f2438e672faaaf50106d4f301a63be80696c3392f70482712f0acbb1`.

Run `./scripts/build-icon.sh` from the repository. The script uses only the installed macOS Swift/AppKit/CoreGraphics/ImageIO frameworks. It strictly renders the source's M/H/V/Z paths and solid rectangle, preserving geometry. It creates conventional `Resources/TextTank.icns` with all ten standard 1×/2× representations (16, 32, 128, 256 and 512 logical pixels, up to 1024 physical pixels). Explicit 72/144 DPI distinguishes Retina entries. Temporary iconsets and the compiler cache are under ignored `.build/icon-tool/`.

The application plist should use `CFBundleIconFile = TextTank`. No rounded presentation raster or competing asset catalog is a production source. This conventional square icon was chosen for the earlier macOS 14 target and is retained unchanged at the macOS 27.0 minimum. Icon Composer and newer appearance variants are not packaged or validated; actual Dock appearance still requires runtime verification.

Observed 15 November 2026: the renderer checks exact opaque interior pixels against the parsed source in all ten rasters: carbon #15201F (21, 32, 31), citrus #C7F45B (199, 244, 91), paper #F4F6F0 (244, 246, 240). The Generic RGB initializer failed this guard before the explicit sRGB correction. The generated ICNS SHA-256 is `a915d3c6ef9800dbbb0d8ccddd5d409f95d1e6630ee18e66f208f55b1903e0c1`. Geometry and 72/144 DPI tagging are unchanged. Actual Dock/older-OS appearance remains unverified.

The TT/caret symbol is original TextTank project artwork. The separate outlined wordmark derives from Space Grotesk; retain its OFL notice. Inter's accompanying OFL notice is likewise retained. Native controls use system fonts; no font rendering is needed to generate the symbol icon.
