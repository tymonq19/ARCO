# Design sources

`icon-source.png` — 2048×2048, the master the app icon is generated from. Every
size in `ios/Runner/Assets.xcassets/AppIcon.appiconset`, every
`android/app/src/main/res/mipmap-*` launcher icon and both launch screens come
from this one file.

To regenerate after changing it, resize it into each slot listed in the iOS
`Contents.json`, into the five Android densities, and into the adaptive
foreground. The foreground drops the flat `#070B1A` backdrop and is scaled to
62% of its canvas, because the launcher masks an adaptive icon down to an inner
circle and a full-bleed ring would have its edges shaved off.

The launch screens use the same artwork on `#070B1A`, which is the game's own
background, so there is no white flash before the first frame.
