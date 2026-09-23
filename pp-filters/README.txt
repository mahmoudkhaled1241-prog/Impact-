ST6IX PP FILTER V1.1
Photographic post-processing for Assetto Corsa

WHICH VERSION TO USE
  ST6IX V1.1           Pure Gamma, normal (SDR) monitor
  ST6IX V1.1 HDR       Pure Gamma, HDR monitor
  ST6IX V1.1 LCS       Pure LCS, normal (SDR) monitor
  ST6IX V1.1 LCS HDR   Pure LCS, HDR monitor

REQUIREMENTS
- Custom Shaders Patch (CSP)
- Pure Gamma (3.50) for the Gamma versions, or Pure LCS for the LCS versions
- HDR versions: an HDR display, HDR turned on in Windows and HDR output turned
  on in the CSP graphics settings

INSTALLATION
1. Copy the "assettocorsa" folder from this package into your Assetto Corsa
   root folder and allow it to merge. It adds:
     system/cfg/ppfilters/ST6IX_PP_V1.1*.ini          (the four filters)
     system/cfg/ppfilters/pure_scripts/...             (Gamma scripts)
     system/cfg/ppfilters/purelcs_scripts/...          (LCS scripts)
2. In Content Manager or the CSP menu, pick the filter that matches your Pure
   edition and display from the list above.
3. Each filter loads its script automatically: the .ini and .lua share a name.
   Do not rename one without the other.

HDR SETUP
Open the Tone Mapping page and set:
- HDR Peak Brightness: your display's peak brightness in nits (e.g. 600, 1000)
- HDR Paper White: how bright menus and mid-tones should be (200-300 nits
  suits most rooms)
GT7 is the default tone curve on HDR and uses the full peak brightness.
Uchimura also uses it. AgX and Lottes stay paper-white referred.

CONTROL PAGES
Daytime Control, Nighttime Controls, Fog, Sky & Clouds, Bloom, Glare,
Exposure, Tone Mapping, Color Grading, Lens Effects, Reflections, Diagnostics.

FEATURES
- Four tone curves: AgX (signature ST6IX look), Uchimura, Lottes and GT7
  (Gran Turismo 7 style, true-hue highlights)
- Scene-aware tone mapping, highlight protection, shadow detail and fog
  contrast protection
- Color Grading: 9 day profiles (Neutral, Natural, Vivid, Cinematic, Warm
  Summer, Cool Winter, Film, GT Broadcast, Raw) and 7 night profiles
  (Neutral, Natural Night, Moonlight Blue, Sodium City, Neon, Cinematic Night,
  Noir), Grade Strength and manual Saturation, Contrast, Temperature, Tint,
  Vibrance, Fade and Sepia
- Adaptive exposure with metering modes, tunnel presets and exposure lock
- Automatic white balance with lock
- Reactive, source-aware bloom and glare with glare styles and Render Quality
- Sun Blinding, sun and moon godrays
- Weather-aware sky, clouds, fog, ambient light and wet-road reflections
- Lens profiles, vignette, chromatic aberration, distortion, depth of field
- Diagnostics page with live readings

TIPS
- Neutral colour profiles leave the image untouched. Choose a profile, then
  refine it with the manual grade sliders.
- Diagnostics page: enable it to see live exposure, highlight, fog and
  tunnel readings while you tune.
