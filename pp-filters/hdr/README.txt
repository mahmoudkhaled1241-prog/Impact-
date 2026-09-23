ST6IX PP FILTER V1.2 HDR
Photographic post-processing for Assetto Corsa on HDR displays

REQUIREMENTS
- Custom Shaders Patch (CSP)
- Pure Gamma (3.50)
- An HDR display

INSTALLATION
1. Copy the "assettocorsa" folder from this package into your Assetto Corsa
   root folder and allow it to merge. It adds:
     system/cfg/ppfilters/ST6IX_PP_V1.2_HDR.ini
     system/cfg/ppfilters/pure_scripts/ST6IX_PP_V1.2_HDR.lua
2. The .ini and .lua share a name so the filter loads its script
   automatically. Do not rename one without the other.

HDR SETUP (required, once)
1. Windows: Settings > System > Display > turn on "Use HDR".
2. Content Manager > Settings > Custom Shaders Patch > DXGI:
   - New DXGI flip model: Active
   - HDR support: Active
   - HDR support with YEBIS: keep "Force linear function for YEBIS" and
     "Final tonemapping" on (their defaults)
3. Assetto Corsa video settings: windowed or borderless, not fullscreen.
   (CSP's HDR output requires the DXGI flip model, which does not work in
   exclusive fullscreen.)
4. In the game, select the "ST6IX_PP_V1.2_HDR" filter.

HOW THE HDR VERSION WORKS
CSP performs the final HDR tone mapping for your display, so this filter runs
YEBIS in linear mode and shapes the image before it: exposure, bloom, glare,
colour, fog, sky and reflections all behave as in the SDR version. The
HDR Tone Mapping page keeps ST6IX's scene-aware response:
- Scene Aware HDR / HDR Adaptation Strength: master switch and amount
- HDR Highlight Protection: holds exposure back when sky, sun and reflections
  dominate, so highlights keep their detail
- HDR Shadow Lift: opens up dark scenes
- HDR Fog Contrast: stops dense fog flattening the picture
- HDR Brightness (stops), HDR Contrast, HDR Saturation: overall finish

TUNING BRIGHTNESS
- Start with HDR Brightness in the filter.
- If the whole picture or the menus are too bright or too dim, adjust
  "Final brightness", "Final gamma" and "UI brightness" in the CSP DXGI
  settings to suit your display.

The SDR tone curves (AgX, Uchimura, Lottes), Tonemap Gamma and Filmic Contrast
are not part of this version: in HDR mode CSP replaces them with its own
final HDR tone mapping, so they would have no effect.
