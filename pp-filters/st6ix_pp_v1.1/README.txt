ST6IX V1.3
Photographic post-processing for Assetto Corsa

The ST6IX V1.2 engine (weather-adaptive lighting, sky, fog, bloom, glare,
exposure and reflections) with ST6IX skydomes, HDR & Clarity and film grain,
in a fully restyled menu.

WHICH VERSION TO USE
  ST6IX_PP_V1.3       normal (SDR) monitor
  ST6IX_PP_V1.3_HDR   HDR monitor with CSP HDR output

REQUIREMENTS
- Custom Shaders Patch (CSP)
- Pure Gamma (3.50)
- Skydomes: the ST6IX skydome textures in
  system/cfg/ppfilters/pure_scripts/textures/
    ST6IX Nebula.dds, ST6IX MADARA.dds, ST6IX blackhole.dds,
    ST6IX black-matter.dds, Black matter Colored.dds
- HDR version: an HDR display (see HDR SETUP)

INSTALLATION
1. Copy the "assettocorsa" folder from this package into your Assetto Corsa
   root folder and allow it to merge. It adds:
     system/cfg/ppfilters/ST6IX_PP_V1.3.ini
     system/cfg/ppfilters/ST6IX_PP_V1.3_HDR.ini
     system/cfg/ppfilters/pure_scripts/ST6IX_PP_V1.3.lua
     system/cfg/ppfilters/pure_scripts/ST6IX_PP_V1.3_HDR.lua
2. Pick the filter for your display in Content Manager or the CSP menu. The
   .ini and .lua share a name so the script loads automatically. Do not rename
   one without the other.

THE TABS
  🎯Guide         signature looks and tips
  ☀️Daytime       overall look, morning looks, sunlight, ambient, colour,
                  white balance, car lights and screens
  🌙Night         night looks, light pollution, moon and stars, colour
  🌤️Sky&Clouds    sky looks, sky colour, clouds, sun and moon size
  🌌Skydomes      ST6IX cosmic skies: Nebula, Madara, Black Hole, Black
                  Matter, Black Matter Colour
  🌫️Fog           fog fine tuning, fog colour, backlight and horizon
  ✴️Bloom         bloom
  💫Glare         glare styles, reactive glare, sun blinding, star glare,
                  lens artifacts
  📷Exposure      tunnels, smart exposure, auto exposure, compensation
  🎨Tonemap       tone curves and scene-aware tone (HDR: HDR Tonemap)
  🔍HDR&Clarity   sharpness, clarity, micro contrast, brightness boost,
                  vibrance, highlight recovery
  📹LensFX        lens profiles, god rays, vignette, chromatic aberration,
                  lens distortion, film grain, film contrast, depth of field
  ✨Reflections   reflection looks, wet weather, detail, ambient occlusion
  🔧Diagnostics   live scene readings and warnings

TONE CURVES
  🎞️ Silver Screen   filmic (AgX): soft highlights, natural colour
  🏁 Grand Tour      broadcast (Uchimura, the Gran Turismo tonemapper)
  ⚡ Neon Punch      bold contrast and colour (Lottes)

HDR & CLARITY PRESETS
  Off, Subtle HDR🌤️, Full HDR☀️, Ultra HDR🔥, Cinematic Sharp🎥, Manual⚙️
  Presets set sharpness, clarity, micro contrast, brightness boost, vibrance
  and highlight recovery; Manual lets you set each one. Sharpening eases off
  at night and in the cockpit to keep noise down.

NOTES
- With Skydomes Off, HDR & Clarity Off and Film Grain off, the picture is
  exactly ST6IX V1.2.
- Bloom and glare sampling runs at High quality.

HDR SETUP (HDR version, once)
1. Windows: Settings > System > Display > turn on "Use HDR".
2. Content Manager > Settings > Custom Shaders Patch > DXGI:
   - New DXGI flip model: Active
   - HDR support: Active
   - HDR support with YEBIS: keep "Force linear function for YEBIS" and
     "Final tonemapping" on (their defaults)
3. Assetto Corsa video settings: windowed or borderless, not fullscreen.
4. Select the "ST6IX_PP_V1.3_HDR" filter.
CSP performs the final HDR tone mapping for your display, so the HDR version
runs YEBIS linear with neutral gamma. The HDR Tonemap tab shapes the scene
before that: Scene Aware HDR, Highlight Protection, Shadow Lift, Fog Contrast,
HDR Brightness (stops), HDR Contrast and HDR Saturation. If the picture or
the menus are too bright or too dim overall, adjust "Final brightness",
"Final gamma" and "UI brightness" in the CSP DXGI settings.

FOR DEVELOPERS
Rebuild with python3 build/build.py. Checks: luajit ../tests/v13_check.lua
and luajit ../tests/audit.lua ST6IX_PP_V1.3.lua
