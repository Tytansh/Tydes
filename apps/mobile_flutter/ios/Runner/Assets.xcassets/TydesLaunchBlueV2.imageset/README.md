# Launch Screen Assets

These launch images are generated from the approved blue-wave artwork at
`assets/branding/tydes-wave-blue.png`. Do not redraw or substitute the old wave.

From the Flutter project, regenerate only these images with:

`dart run tool/generate_brand_assets.dart --launch-only`

The versioned image-set and `TydesLaunchScreenV2` storyboard names also prevent
iOS from reusing a launch snapshot generated for the retired launch resources.
A native rebuild and cold launch are required; Flutter hot reload does not
replace the compiled iOS launch screen. Never uninstall or clear account data
just to update this artwork.
