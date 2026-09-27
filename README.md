Oilify - Painterly Strokes v19 (optimized)
================
Optimization goals:
- Keep the supplied original Oilify/Kuwahara math intact.
- Remove the extra full-screen Capture pass.
- Replace the v9 5x5 x 2 stroke searches with one 3x3 search.
- Sample Anisotropy once per brush pixel instead of once per candidate stroke.
- Remove per-candidate sin/cos and use cheap hash/polynomial shape functions.
- Use one coherent stroke-color sample per pixel.
- Keep Paint Drag axial and optional.
- Add larger-scale bristle grooves, paint-load variation, stroke scatter, controllable direction jitter, edge wear, dry-brush breakup and paint relief.
- Give each stroke an independent temporal phase, speed, direction wobble, and breathing rate.
- Use smoothed triangle waves for more organic continuous motion.
- Protect strong silhouettes using derivative-based edge detection (no extra texture fetches).
- Add subtle per-stroke pigment variation and one-sided paint pooling with math only.
- Add shape-adaptive stroke sizing: broad calm regions use longer strokes while complex structure uses shorter, more controlled strokes.
- Add stroke clumping: nearby strokes can share a gentle directional family and partially shared temporal motion.
- Add contour flow: optional tendency for strokes to follow strong local silhouette flow without extra texture fetches.
- Add shape-adaptive motion: calm regions drift farther while detailed edges remain steadier, without synchronizing strokes globally.
- Keep the new controls math-only so these features do not add texture fetches.
- Optimize stroke search with one seed hash per candidate and a cheap coarse cull.
- Precompute per-pixel form/motion factors outside the 3x3 candidate loop.
- Compute contour-following tangent once per pixel and reuse it for all candidates.
- Skip the final paint color fetch entirely when the pixel is outside all stroke coverage.

The expensive original part is intentionally preserved so Sharpness / Scale /
Tuning retain the behavior of the supplied Oilify.fx.

Ganossa Motion Focus - Modern Edition
=================
 Original concept: Ganossa (mediehawk@gmail.com)  
 Original port credit: IDDQD 
 
 Modern additions:
 - Resolution-independent motion analysis (fixed 32x18 grid).
 - Frame-time-aware temporal persistence.
 - Independent motion fisheye.
 - Independent motion chromatic aberration.
 - Independent edge Gaussian blur.
 - Separate deadzone + persistence for every motion-driven effect.
 - Each optional effect has its own checkbox + collapsible UI category.
 - Idle figure-eight head sway integrated into Motion Focus/Zoom framing.
   
 Head Sway V3: continuous speed reduction instead of hard idle stop.  
 Fisheye V4: accumulated attack + persistence release, with a more sensitive.
 
 Target:
 ReShade 6.x / current ReShade FX
------------

ReShade FX shaders
==================

This repository aims to collect post-processing shaders written in the ReShade FX shader language.

Installation
------------

1. [Download](https://github.com/crosire/reshade-shaders/archive/master.zip) this repository
2. Extract the downloaded archive file somewhere
3. Start your game, open the ReShade in-game menu and switch to the "Settings" tab
4. Add the path to the extracted [Shaders](/Shaders) folder to "Effect Search Paths"
5. Add the path to the extracted [Textures](/Textures) folder to "Texture Search Paths"
6. Switch back to the "Home" tab and click on "Reload" to load the shaders

Contributing
------------

Check out [the language reference document](REFERENCE.md) to get started on how to write your own!
