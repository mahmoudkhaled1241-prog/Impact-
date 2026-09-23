ST6IX HAT-TRICK V2.0
The HAT-TRICK filter with a fixed line-up:
  Exposure        ST6IX V1.2 adaptive exposure
  Bloom / Glare   ST6IX V1.2 reactive bloom and glare
  Sky             ST6IX V1.5 sky presets (the ST6IX_PP_V1.1 file; its code
                  header calls itself V1.5)
  Fog             both systems, chosen on the Fog page:
                    ST6IX FOG 1 = V1.2 Pure weather tuning (default)
                    ST6IX FOG 2 = V1.5 atmospheric (None / Immersive /
                                  Realistic + ground fog)
Lighting, reflections and colour stay selectable (V1.2 or V1.5) on the
Engines page, and every tone curve is available. The controls of the systems
V2 does not use (V1.2 sky, V1.5 exposure, V1.5 bloom/glare) are not shown.

WHICH VERSION TO USE
  ST6IX_HatTrick_V2.0       normal (SDR) monitor
  ST6IX_HatTrick_V2.0_HDR   HDR monitor with CSP HDR output

REQUIREMENTS
- Custom Shaders Patch (CSP)
- Pure Gamma (3.50)
- Skydomes: the ST6IX skydome textures from the V1.5 package must stay in
  system/cfg/ppfilters/pure_scripts/textures/ (the filter uses the same paths)
- HDR version: an HDR display (see HDR SETUP)

INSTALLATION
1. Copy the "assettocorsa" folder from this package into your Assetto Corsa
   root folder and allow it to merge. It adds:
     system/cfg/ppfilters/ST6IX_HatTrick_V2.0.ini
     system/cfg/ppfilters/ST6IX_HatTrick_V2.0_HDR.ini
     system/cfg/ppfilters/pure_scripts/ST6IX_HatTrick_V2.0.lua
     system/cfg/ppfilters/pure_scripts/ST6IX_HatTrick_V2.0_HDR.lua
2. Pick the filter for your display in Content Manager or the CSP menu. The
   .ini and .lua share a name so the script loads automatically. Do not rename
   one without the other.

ENGINES PAGE (defaults in brackets)
  Lighting Engine    [V1.2 Photographic]            / V1.5 Presets
  Reflection Engine  [V1.2 Adaptive]                / V1.5 Presets
  Color Engine       [V1.2 Adaptive White Balance]  / V1.5 Day-Dusk-Night
  Fog (Fog page)     [ST6IX FOG 1]                  / ST6IX FOG 2
  Tone Curve (Tone Mapping page): AgX, Uchimura, Lottes (V1.2) or
  Neon Noir, ST6IX Dusk, [Hyperchrome], Retrograde, BABAYAGA, ST6IX Lottes (V1.5)
Pages show both engines' controls where you can choose; the selected
engine's controls are live. After switching an engine or fog system, restart
the session (or reload the filter) for a fully clean state.

ACTIVE WITH EVERY ENGINE
- Finishing profile (V1.5) and Overall Mode (V1.2)
- Day/Night Color Saturation and Contrast (combined with the V1.5 finish)
- HDR & Clarity: sharpness, clarity, micro contrast, brightness, vibrance and
  highlight recovery
- Lens: god rays, vignette, chromatic aberration, lens distortion, Dashcam,
  depth of field, film grain
- Skydomes, Sun Effects, Render Quality, Status page

WHAT CHANGED COMPARED WITH V1.2 AND V1.5
- V1.5 presets now select the preset you click. Pure radio buttons count from
  1, but V1.5 counted from 0, so every V1.5 preset list picked the option
  after the one you clicked.
- V1.5 tone curves now match their names. V1.5's "Hyperchrome" button
  actually ran the Retrograde curve, "Retrograde" ran BABAYAGA (ACES) and
  "BABAYAGA" ran the Lottes curve. Each name now runs its own curve; the
  Lottes curve is now its own choice, "ST6IX Lottes". If you liked the look
  your old "Hyperchrome" button gave you, choose Retrograde.
- Sun Effects > Allow Manual Control now works: on = the V1.5 manual sun
  blinding sliders, off = V1.2's automatic weather-aware Sun Blinding and
  Sun Blinding Iris.
- HDR & Clarity > Highlight Recovery now works: it lowers exposure slightly
  when bright highlights dominate.
- God Ray Length (Lens page) also sets the length of the V1.2 YEBIS god rays
  (10 = unchanged, 0 = off).
- Tonemap Gamma trims every tone curve (1.10 = unchanged).
- Vignette: the V1.5 finishing base is scaled by the V1.2 Vignette Strength,
  lens profile and field-of-view response (V1.2 strength 0.01 = unchanged).
- Dashcam lens distortion overrides the regular lens distortion while on.

HDR SETUP (HDR version, once)
1. Windows: Settings > System > Display > turn on "Use HDR".
2. Content Manager > Settings > Custom Shaders Patch > DXGI:
   - New DXGI flip model: Active
   - HDR support: Active
   - HDR support with YEBIS: keep "Force linear function for YEBIS" and
     "Final tonemapping" on (their defaults)
3. Assetto Corsa video settings: windowed or borderless, not fullscreen.
4. Select the "ST6IX_HatTrick_V2.0_HDR" filter.

HOW THE HDR VERSION WORKS
CSP performs the final HDR tone mapping for your display, so the HDR version
runs YEBIS in linear mode with neutral gamma. The HDR Tone Mapping page
replaces the SDR tone curves and shapes the scene before CSP's mapping:
- Scene Aware HDR / HDR Adaptation Strength: master switch and amount
- HDR Highlight Protection: holds exposure back when sky, sun and reflections
  dominate, so highlights keep their detail
- HDR Shadow Lift: opens up dark scenes
- HDR Fog Contrast: stops dense fog flattening the picture
- HDR Brightness (stops), HDR Contrast, HDR Saturation: overall finish
These work with every engine choice.
Everything else (engines, presets, bloom, fog, sky, reflections, lens,
skydomes, clarity) works as in the SDR version. The SDR tone curves, Tonemap
Gamma, Filmic Contrast and the V1.5 curve sliders are not in the HDR version:
CSP's HDR output replaces them, so they would do nothing.
If the picture or the menus are too bright or too dim overall, adjust "Final
brightness", "Final gamma" and "UI brightness" in the CSP DXGI settings.

FOR DEVELOPERS
Rebuild with python3 build/assemble.py --v2 (add --hdr for the HDR build).
Checks: luajit ../tests/hattrick_check.lua
