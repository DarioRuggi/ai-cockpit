Splash image library
====================
Drop PNG/SVG here (Installs/splash/images/) and name the file in a card's
"image" field in features.json. Guidelines:

  * Under ~80 KB each. The splash is inlined as data: URIs so it works from
    file:// with no network — every KB is paid at every start.
  * Roughly 3:2, shown at 56x38 CSS px. Legible at that size or leave it out.
  * A card with no image shows its inline SVG icon instead. That is the default
    and looks deliberate; a bad image is worse than no image.

Regenerate both splashes after any change:  bash Installs/build_splash.sh
