"""Page layout and main loop for ST6IX HAT-TRICK.

Control declarations are copied from the source files by name so defaults,
ranges and tooltips stay exactly as authored (V1.5 radio defaults become 1-based).
"""
import re

def index_controls(lines):
    found = {}
    pat = re.compile(r"""(?:pure\.script\.ui\.)?(?:addSliderFloat|addSliderInteger|addCheckbox|addRadioButtons|slider|sliderInt)\(\s*["']([^"']+)["']""")
    for line in lines:
        if line.strip().startswith('--'):
            continue
        m = pat.search(line)
        if m and m.group(1) not in found:
            found[m.group(1)] = line.strip()
    return found

V15_RADIO_DEFAULTS = {
    'st6ix_profile': 1, 'lighting_preset': 7, 'night_preset': 1, 'reflections_preset': 7,
    'sky_preset': 4, 'FOG Type': 3, 'ini_eye_preset_v2': 1, 'hdr_clarity_preset': 2,
    'Skydome Preset': 1, 'Tunnel Blinding Presets': 2,
}

TONEMAP_LITERALS = {
    'tonemap__custom.values.P': '2.00', 'tonemap__custom.values.a': '1.00',
    'tonemap__custom.values.m': '0.29', 'tonemap__custom.values.l': '0.40',
    'tonemap__custom.values.c': '1.00', 'tonemap__custom.values.b': '0.00',
    'tonemap__custom.values.gain': '1.00', 'tonemap__custom.values.agx_mix': '0.85',
    'tonemap__custom.values.agx_mix_exp': '0.40', 'tonemap__custom.values.agx_slope': '1.25',
    'tonemap__custom.values.agx_power': '1.75', 'tonemap__custom.values.agx_sat': '0.99',
}

def build_main(v12_lines, v15_lines, hdr=False):
    c12 = index_controls(v12_lines)
    c15 = index_controls(v15_lines)
    used = set()
    body = []

    def add(raw):
        body.append('    ' + raw)

    def t(text):
        add("pure.script.ui.addText(%s)" % lua_str(text))

    def sep():
        add('pure.script.ui.addSeparator()')

    def page(name):
        body.append('')
        add("pure.script.ui.addPage(%s)" % lua_str(name))

    def v12(*names):
        for n in names:
            assert n in c12, ('missing V1.2 control', n)
            add(c12[n]); used.add(('12', n))

    def v15(*names):
        for n in names:
            assert n in c15, ('missing V1.5 control', n)
            line = c15[n]
            if n in V15_RADIO_DEFAULTS:
                line = re.sub(r'(addRadioButtons\(\s*"[^"]+"\s*,\s*)[^,]+,',
                              lambda m: m.group(1) + str(V15_RADIO_DEFAULTS[n]) + ',', line, count=1)
            for k in sorted(TONEMAP_LITERALS, key=len, reverse=True):
                line = re.sub(re.escape(k) + r'\b', TONEMAP_LITERALS[k], line)
            add(line); used.add(('15', n))

    def radio(name, default, options, tip=None):
        add("pure.script.ui.addRadioButtons(%s, %d, %s)" % (lua_str(name), default, lua_str(options)))

    # ------------------------------------------------------------- pages
    page('🎯Guide')
    t('ST6IX HAT-TRICK V1.0%s - two ST6IX engines in one filter.' % (' HDR' if hdr else ''))
    if hdr:
        t('HDR build: CSP performs the final HDR tone mapping for your display.')
        t('Setup: Windows HDR on; CSP DXGI flip model + HDR support; AC windowed/borderless.')
    t('Engines page: pick which engine drives each area. Only the selected one')
    t('writes to the game, so the two never fight. Controls are grouped by engine.')
    sep()
    t('Recipes: "Sky V1.5: Natural" = Sky Engine V1.5 + sky preset Natural.')
    t('🌅 MORNING CLEAR - Tone Curve: Hyperchrome | Sky: V1.5 Natural' if not hdr else '🌅 MORNING CLEAR - Sky: V1.5 Natural | HDR Brightness 0')
    t('   Daytime V1.5: Crisp Clear | Bloom V1.5: Crisp Clear | Fog V1.5: None')
    t('🌫️ MORNING HAZY - Fog V1.5: Realistic (amount 0.08, thickness 0.02)')
    t('   Sky V1.5: Overcast Soft | Bloom V1.5: Subtle')
    t('🌇 DUSK / DAWN - Daytime V1.5: Golden Hour | Sky V1.5: Golden Hour')
    t('   Tone Curve: Retrograde | Reflections V1.5: Cinematic' if not hdr else '   Reflections V1.5: Cinematic | HDR Saturation 1.05')
    t('🌙 NIGHT CLEAR - Night V1.5: Bright Night | Bloom V1.5: Subtle')
    t('🌃 NIGHT CITY - Night V1.5: Neon City | Bloom V1.5: City Lights')
    t('   Sky V1.5: Smog / City Haze | Reflections V1.5: Magical Shimmer')
    t('🌧️ WET DAY / NIGHT - V1.2 engines: Lighting, Reflections and Fog adapt')
    t('   to rain, wet roads and standing water automatically.')
    sep()
    t('Mix freely: e.g. V1.5 Hyperchrome look with V1.2 adaptive sky and fog.' if not hdr else 'Mix freely: e.g. V1.5 lighting presets with V1.2 adaptive sky and fog.')

    page('⚙️Engines')
    t('Choose the engine for each area. Pages show both engines\' controls;')
    t('only the controls of the selected engine are active.')
    radio('Lighting Engine', 1, 'V1.2 Photographic,V1.5 Presets')
    radio('Sky Engine', 1, 'V1.2 Adaptive Sky,V1.5 Sky Presets')
    radio('Fog Engine', 1, 'V1.2 Pure Weather Tuning,V1.5 Atmospheric')
    radio('Reflection Engine', 1, 'V1.2 Adaptive,V1.5 Presets')
    radio('Bloom Engine', 2, 'V1.2 Reactive,V1.5 INI-Matched')
    radio('Exposure Engine', 2, 'V1.2 Adaptive,V1.5 ST6IX Custom,Pure Native')
    radio('Color Engine', 1, 'V1.2 Adaptive White Balance,V1.5 Day-Dusk-Night')
    t('Tone Curve (Tone Mapping page) picks a V1.2 or a V1.5 curve.' if not hdr else 'Tone mapping: CSP HDR output (HDR Tone Mapping page shapes the scene).')
    t('After switching an engine, restart the session for a fully clean state.')
    sep()
    t('Overall look (V1.2)')
    v12('Overall Mode')
    t('Finishing profile (V1.5): sharpness, clarity, vignette and grain')
    v15('st6ix_profile')
    t('Photoreal Drive: neutral, clean and driver-focused')
    t('Photoreal Cinema: restrained camera depth | Photoreal Photo: detailed')
    t('Manual: individual finishing sliders stay authoritative')
    v15('weather_realism_v15')

    page('☀️Daytime')
    t('V1.2 PHOTOGRAPHIC ENGINE')
    v12('Morning Preset', 'Morning Preset Strength', 'Daylight Multiplier', 'Day Sun Level',
        'Day Sun Saturation', 'Day Sun Speculars', 'Day Ambient Level', 'Day Sky Level',
        'Day Advanced Ambient', 'Spectrum Adaptation', 'Lambert Gamma', 'Day CSP Light Bounce',
        'Day CSP Light Emissive', 'Day Display Brightness')
    t('Ambient light model')
    v12('Ambient V2 Sun', 'Ambient V2 Sky', 'Ambient V2 Clouds', 'Weather Ambient Balance')
    sep()
    t('V1.5 PRESETS ENGINE')
    v15('lighting_preset', 'lighting_affects_bloom', 'daylight_multiplier', 'sun_level',
        'sun_speculars', 'ambient_level', 'advanced_ambient_light', 'advanced_ambient_lightV2_sun',
        'sky_level', 'csp_lights_bounce', 'csp_lights_emissive', 'spectrum_adaption')
    sep()
    t('COLOUR FINISH (both engines)')
    v12('Day Color Saturation', 'Day Contrast')

    page('🌙Night')
    t('V1.2 PHOTOGRAPHIC ENGINE')
    v12('Night Preset', 'Night Light Pollution Level', 'Night Light Pollution Density',
        'Night Lowest Ambient', 'Moon Light', 'Moon Appearance', 'Stars Appearance',
        'Stars Brightness', 'Stars Saturation', 'Stars Exponent', 'Night CSP Light Bounce',
        'Night CSP Light Emissive', 'Night Display Brightness', 'Adaptive Celestial Rendering',
        'Celestial Weather Extinction', 'Moon Elevation Response', 'Moon Star Suppression',
        'Deep Sky Visibility')
    sep()
    t('V1.5 PRESETS ENGINE')
    v15('night_preset', 'nlp_level', 'nlp_density', 'nlp_lowest_ambient', 'moon_light',
        'moon_appearance', 'stars_appearance', 'stars_dynamic_adaption',
        'night_csp_lights_bounce', 'night_csp_lights_emissive')
    sep()
    t('COLOUR FINISH (both engines)')
    v12('Night Color Saturation', 'Night Contrast')

    page('🌤️Sky & Clouds')
    t('V1.2 ADAPTIVE SKY ENGINE')
    v12('Sky Preset', 'Sky Preset Strength', 'Sky Weather Response', 'Sky Transition Speed',
        'Day Sky Brightness', 'Day Sky Saturation', 'Twilight Sky Brightness',
        'Twilight Sky Saturation', 'Night Sky Brightness', 'Night Sky Saturation',
        'Day Cloud Brightness', 'Day Cloud Contrast', 'Day Cloud Softness',
        'Twilight Cloud Brightness', 'Twilight Cloud Contrast', 'Twilight Cloud Softness',
        'Night Cloud Brightness', 'Night Cloud Contrast', 'Night Cloud Softness',
        'Sun Apparent Size', 'Moon Apparent Size')
    sep()
    t('V1.5 SKY PRESETS ENGINE')
    v15('sky_preset', 'sky_light_level', 'sun.sun_moon_size', 'Daytime Clouds Brightness',
        'Daytime Clouds Contrast', 'Nighttime Clouds Brightness', 'Nighttime Clouds Contrast',
        'Daytime Sky Level', 'Duskdawn Sky Level', 'Daytime Sky Saturation', 'sunset_sun_sat')

    page('🌫️Fog')
    t('V1.2 PURE WEATHER TUNING ENGINE (scales Pure\'s live weather fog)')
    v12('Enable Fog Fine Tuning', 'Custom Fog Color', 'Fog Color Preset',
        'Adaptive Fog Color Strength', 'Fog Color Red', 'Fog Color Green', 'Fog Color Blue',
        'Fog Color Mix', 'Fog Density', 'Fog Distance', 'Fog Blend', 'Fog Height', 'Fog Exponent',
        'Fog Backlight', 'Horizon Fog', 'Fog Cubemap Visibility')
    sep()
    t('V1.5 ATMOSPHERIC ENGINE (None / Immersive / Realistic + ground fog)')
    v15('FOG Type', 'Fog amount', 'Fog Thickness', 'Fog Color mixer')

    page('✴️Bloom & Glare')
    v12('Render Quality')
    t('Render Quality refines bloom and glare sampling in both engines.')
    sep()
    t('V1.2 REACTIVE ENGINE')
    v12('Bloom Enabled', 'Bloom Strength', 'Bloom Threshold', 'Bloom Radius', 'Bloom Levels',
        'Bloom Gamma', 'Bloom Filter Threshold', 'Glare Enabled', 'Glare Style',
        'Glare Style Strength', 'Reactive Glare', 'Reactive Glare Strength', 'Night Light Emphasis',
        'Source Aware Glare', 'Sun Glare Response', 'Headlight Glare Response',
        'Emissive Color Protection', 'Glare Master', 'Star Strength', 'Star Length', 'Star Streaks',
        'Star Softness', 'Star Filter Threshold', 'Ghost Strength', 'Afterimage Strength',
        'Afterimage Length', 'Anamorphic Glare')
    sep()
    t('V1.5 INI-MATCHED ENGINE')
    v15('ini_eye_preset_v2', 'ini_eye_bloom_enabled_v2', 'ini_eye_bloom_strength_v2',
        'ini_eye_bloom_threshold_v2', 'ini_eye_bloom_radius_v2', 'ini_eye_bloom_levels_v2',
        'ini_eye_bloom_gamma_v2', 'ini_eye_glare_enabled_v2', 'ini_eye_glare_brightness_v2',
        'ini_eye_glare_length_v2', 'ini_eye_glare_streaks_v2', 'ini_eye_glare_threshold_v2',
        'ini_eye_glare_softness_v2')

    page('🌞Sun Effects')
    t('Works when sun blinding is enabled in CSP settings.')
    v15('sunblinding_active', 'sunblinding_allow_control', 'sunblinding_sensitivity',
        'sunblinding_time_up', 'sunblinding_time_down')
    t('Manual control ON: the sliders below drive the sun blinding.')
    v15('sunblinding_cover', 'sunblinding_blinding', 'sunblinding_iris',
        'sunblinding_star_opacity', 'sunblinding_star_size', 'sunblinding_star_blur')
    sep()
    t('Manual control OFF: automatic weather-aware sun blinding (V1.2)')
    v12('Sun Blinding', 'Sun Blinding Iris')

    page('📷Exposure')
    t('V1.2 ADAPTIVE ENGINE')
    v12('Tunnel Preset')
    t('Normal is neutral. Other modes adapt inside the tunnel and recover at the exit.')
    v12('Tunnel Interior Lift', 'Tunnel Opening Protection', 'Tunnel Recovery Speed',
        'Adaptive Scene Exposure', 'Exposure Metering', 'Per Camera Exposure Memory',
        'Adaptation Strength', 'Highlight Protection', 'Interior Metering Bias',
        'Maximum Target Shift', 'Camera Style Response', 'CBE Mix', 'CBE Target', 'CBE Sensitivity',
        'Minimum Exposure', 'Maximum Exposure', 'Dark Adaptation Speed', 'Bright Adaptation Speed',
        'YEBIS Target', 'Exposure Compensation EV', 'Cockpit Compensation EV', 'Lock Exposure')
    sep()
    t('V1.5 ST6IX CUSTOM ENGINE')
    add('pure.script.ui.addStateFloat("Final Exposure", 0)')
    add('pure.script.ui.addStateFloat("Occlusion", 0)')
    v15('Day Target Exposure', 'Day Exposure Sensitivity', 'AE Day Target', 'Day AE Mix',
        'Night Target Exposure', 'Night Exposure Sensitivity', 'AE Night Target', 'Night AE Mix',
        'Day Interior Exposure', 'Night Interior Exposure', 'AE Interior Day Target',
        'AE Interior Night Target', 'Tunnel Blinding Presets', 'Tunnel Blinding Strength')

    if hdr:
        page('🎨HDR Tone Mapping')
        t('CSP performs the final HDR tone mapping for your display.')
        t('In CSP video settings enable DXGI flip model and HDR support; run AC windowed or borderless.')
        add("pure.script.ui.addCheckbox('Scene Aware HDR', true, 'Adapt exposure and contrast to highlights, darkness and fog')")
        add("slider('HDR Adaptation Strength', 0.45, 0.00, 1.00, 'Strength of the scene-aware HDR response')")
        add("slider('HDR Highlight Protection', 0.55, 0.00, 1.00, 'Hold exposure back when bright sky, sun and reflections dominate')")
        add("slider('HDR Shadow Lift', 0.35, 0.00, 1.00, 'Open up detail in dark scenes')")
        add("slider('HDR Fog Contrast', 0.40, 0.00, 1.00, 'Keep dense fog from flattening the image')")
        add("slider('HDR Brightness', 0.00, -1.50, 1.50, 'Overall HDR scene brightness in stops')")
        add("slider('HDR Contrast', 1.00, 0.85, 1.20, 'Overall HDR contrast')")
        add("slider('HDR Saturation', 1.00, 0.80, 1.20, 'Overall HDR colour intensity')")
        t('Works with every Exposure Engine.')
        sep()
        t('Monitor black level (V1.5 finishing)')
        v15('black_limit_low_exposure', 'black_limit_high_exposure')
    else:
        page('🎨Tone Mapping')
        radio('Tone Curve', 6, 'AgX,Uchimura,Lottes,Neon Noir,ST6IX Dusk,Hyperchrome,Retrograde,BABAYAGA,ST6IX Lottes')
        t('AgX, Uchimura, Lottes: V1.2 scene-aware curves. Neon Noir to ST6IX Lottes: V1.5 dynamic curves.')
        v12('Tonemap Gamma')
        sep()
        t('V1.2 CURVES')
        v12('Scene Aware Tone Mapping', 'Tone Adaptation Strength', 'Dynamic Highlight Rolloff',
            'Dynamic Shadow Detail', 'Fog Contrast Protection')
        t('AgX')
        v12('AgX Exposure', 'AgX Slope', 'AgX Power', 'AgX Saturation')
        t('Uchimura')
        v12('Uchimura Peak', 'Uchimura Contrast', 'Uchimura Linear Start', 'Uchimura Linear Length',
            'Uchimura Black', 'Uchimura Gain')
        t('Lottes')
        v12('Lottes Contrast', 'Lottes Gamma', 'Lottes HDR Max', 'Lottes Mid In', 'Lottes Mid Out',
            'Lottes Gain')
        sep()
        t('V1.5 CURVES')
        v15('photo_realistic', 'sun_blinding')
        t('Hyperchrome / Retrograde curve controls')
        v15('TONEMAPPING__maxDisplayBrightness', 'TONEMAPPING__contrast', 'TONEMAPPING__linearSectionStart',
            'TONEMAPPING__linearSectionLength', 'TONEMAPPING__black', 'TONEMAPPING__pedestal',
            'TONEMAPPING__gain')
        t('AgX film emulation (Hyperchrome / Retrograde)')
        v15('TONEMAPPING__agx_mix', 'TONEMAPPING__agx_mix_luma_exp', 'TONEMAPPING__agx_slope',
            'TONEMAPPING__agx_power', 'TONEMAPPING__agx_sat')
        t('BABAYAGA')
        v15('TONEMAPPING__aces_exposure')
        t('Monitor black level (V1.5 finishing, all curves)')
        v15('black_limit_low_exposure', 'black_limit_high_exposure')

    page('🌡️Color')
    t('V1.2 ADAPTIVE WHITE BALANCE')
    v12('Day Color Temperature', 'Night Color Temperature', 'Automatic White Balance',
        'White Balance Strength', 'White Balance Warmth Bias', 'White Balance Tint',
        'Lock White Balance')
    sep()
    t('V1.5 DAY-DUSK-NIGHT TEMPERATURE')
    v15('color_temp_day', 'color_temp_dusk', 'color_temp_night')

    page('📹Lens')
    v12('Lens Profile', 'Lens Profile Strength')
    t('God rays')
    v15('godray_length')
    v12('Adaptive Godrays', 'Godrays Strength', 'Godrays FOV Response', 'Godrays Sun Facing Response',
        'Godrays Glare Ratio', 'Moon Godrays Strength')
    t('Vignette: finishing profile base x strength x lens profile x field of view')
    v12('Vignette Strength', 'Vignette FOV Dependence')
    v15('Vignette Intensity')
    t('Chromatic aberration')
    v12('Chromatic Aberration', 'Chromatic Samples', 'Chromatic Lateral', 'Chromatic Uniform')
    t('Lens distortion (Dashcam overrides the regular distortion when enabled)')
    v12('Lens Distortion', 'Lens Roundness', 'Lens Smoothness')
    v15('Dashcam', 'Lens Distortion Roundness', 'Lens Distortion Smoothness')
    if not hdr:
        v12('Filmic Contrast')
    v12('Depth of Field', 'DOF Focus Distance', 'DOF Aperture', 'DOF Quality')
    t('Film grain (automatic in finishing profiles, manual in Manual)')
    v15('Enable Film Grain', 'Film Grain Strength')

    page('🔍HDR & Clarity')
    t('Sharpness, clarity and HDR-style finishing (V1.5), active with every engine')
    v15('hdr_clarity_preset', 'hdr_sharpness', 'hdr_clarity', 'hdr_micro_contrast',
        'hdr_brightness_boost', 'hdr_color_vibrance', 'hdr_highlight_recovery')

    page('🌌Skydomes')
    v15('Skydome Preset', 'Skydome Brightness', 'Skydome Contrast', 'Skydome Rotation', 'Skydome Height')

    page('✨Reflections')
    t('V1.2 ADAPTIVE ENGINE')
    v12('Reflection Preset', 'Adaptive Reflections', 'Wet Weather Rendering', 'Wet Reflection Gain',
        'Wet Headlight Bloom', 'Rain Saturation Retention', 'Wet Black Depth',
        'Reflection Weather Response', 'Reflection CPL Strength', 'Reflection Highlight Response',
        'Reflection Level', 'Reflection Saturation', 'Reflection Emissive Boost', 'Fresnel Strength',
        'VAO Amount', 'VAO Track Exponent', 'VAO Dynamic Exponent', 'Weather VAO Adaptation')
    sep()
    t('V1.5 PRESETS ENGINE (ground fog gain also drives V1.5 fog)')
    v15('reflections_preset', 'reflections_saturation', 'reflections_level',
        'reflections_emissive_boost', 'vao_amount', 'groundfog_gain')

    page('🔧Status')
    v12('Diagnostics Enabled', 'Effect Preview', 'Effect Preview Strength')
    for s in ['Live Exposure', 'Live Highlights', 'Camera Occlusion', 'Wet Surface', 'World Fog',
              'Sun Facing', 'Tunnel Response', 'Star Output']:
        add("pure.script.ui.addStateFloat('%s', 0)" % s)
    add("pure.script.ui.addStateString('Render Status', 'Diagnostics disabled')")
    sep()
    for s in ['Status: Script OK', 'Status: Tonemap', 'Status: Bloom', 'Status: Exposure Mode',
              'Status: Exposure', 'Status: Interior', 'Status: Wetness', 'Status: Rain',
              'Status: Weather Adaptation']:
        add('pure.script.ui.addStateFloat("%s", 0)' % s)
    t(('Tonemap 0 = CSP HDR output' if hdr else 'Tonemap = Tone Curve index') + ' | Exposure Mode 1 = V1.5 Custom active')

    # Every source control must be placed exactly once, except the ones the
    # merge replaces on purpose.
    replaced = {('12', 'Tone Curve'), ('15', 'Tonemapping'), ('15', 'exposure_mode')}
    if hdr:
        replaced |= {('12', n) for n in HDR_REMOVED_V12} | {('15', n) for n in HDR_REMOVED_V15}
    missing = [('12', n) for n in c12 if ('12', n) not in used] + [('15', n) for n in c15 if ('15', n) not in used]
    missing = [m for m in missing if m not in replaced]
    assert not missing, ('controls not placed', missing)

    return MAIN_TEMPLATE.replace('--UI--', '\n'.join(body))

# SDR tone controls the HDR build replaces with the HDR Tone Mapping page.
HDR_REMOVED_V12 = ['Tone Curve', 'Tonemap Gamma', 'Scene Aware Tone Mapping', 'Tone Adaptation Strength',
    'Dynamic Highlight Rolloff', 'Dynamic Shadow Detail', 'Fog Contrast Protection',
    'AgX Exposure', 'AgX Slope', 'AgX Power', 'AgX Saturation',
    'Uchimura Peak', 'Uchimura Contrast', 'Uchimura Linear Start', 'Uchimura Linear Length',
    'Uchimura Black', 'Uchimura Gain', 'Lottes Contrast', 'Lottes Gamma', 'Lottes HDR Max',
    'Lottes Mid In', 'Lottes Mid Out', 'Lottes Gain', 'Filmic Contrast']
HDR_REMOVED_V15 = ['photo_realistic', 'sun_blinding', 'TONEMAPPING__maxDisplayBrightness',
    'TONEMAPPING__contrast', 'TONEMAPPING__linearSectionStart', 'TONEMAPPING__linearSectionLength',
    'TONEMAPPING__black', 'TONEMAPPING__pedestal', 'TONEMAPPING__gain', 'TONEMAPPING__agx_mix',
    'TONEMAPPING__agx_mix_luma_exp', 'TONEMAPPING__agx_slope', 'TONEMAPPING__agx_power',
    'TONEMAPPING__agx_sat', 'TONEMAPPING__aces_exposure']

def lua_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"

MAIN_TEMPLATE = r'''
-- ============================================================================
-- USER INTERFACE AND FRAME LOOP
-- ============================================================================

local function slider(name, default, minimum, maximum, tooltip)
    pure.script.ui.addSliderFloat(name, default, minimum, maximum, tooltip)
end

local function sliderInt(name, default, minimum, maximum, tooltip)
    pure.script.ui.addSliderInteger(name, default, minimum, maximum, tooltip)
end

-- Neutral exposure hand-off: CBE on, no bypass, no multiplier. Used at start
-- and whenever the Exposure Engine changes, so no engine inherits the last
-- one's lock or mix (Pure Native then really is Pure's own exposure).
local function resetExposure()
    pure.exposure.useCBE(true)
    pure.exposure.setBypass(0.25, 0)
    pure.exposure.cbe.setMultiplier(1)
end

function init_pure_script()
    pure.script.setVersion(VERSION)
    if type(pure.script.setAuthor) == 'function' then pure.script.setAuthor(BUILD.name) end
    -- Rebuild saved UI state once for the merged control set.
    if type(pure.script.resetSettingsWithNewVersion) == 'function' then
        pcall(pure.script.resetSettingsWithNewVersion)
    end
--UI--

    pure.config.set('light.ambient_model_V2', true, true)
    pure.config.set('AI_headlights.ambient_light', 0.5, true)
    pure.light.setVAOAdaption(1.0)
    pure.light.setLambertGamma(1.10)
    if type(pure.pp.UseSpice) == 'function' then pcall(pure.pp.UseSpice) end
    V12.reset()
    V15.init()
    resetExposure()
end

local lastExposureEngine = nil
local function readEngines()
    E.lighting = uiChoice('Lighting Engine', 1, 2)
    E.sky = uiChoice('Sky Engine', 1, 2)
    E.fog = uiChoice('Fog Engine', 1, 2)
    E.reflections = uiChoice('Reflection Engine', 1, 2)
    E.bloom = uiChoice('Bloom Engine', 2, 2)
    E.exposure = uiChoice('Exposure Engine', 2, 3)
    E.color = uiChoice('Color Engine', 1, 2)
    E.tone = BUILD.hdr and 0 or uiChoice('Tone Curve', DEFAULT_TONE, 9)
    E.sunblindManual = uiCheck('sunblinding_allow_control', true)
    if lastExposureEngine ~= nil and lastExposureEngine ~= E.exposure then
        resetExposure()
        V12.reset()
    end
    lastExposureEngine = E.exposure
end

local function numberOr(v, fallback)
    if type(v) == 'number' and v == v then return v end
    return fallback
end

-- Writes the values both engines contribute to, once, combined.
local function compose()
    -- HDR build: CSP maps the final image to the display, so YEBIS stays
    -- linear with neutral gamma and the scene-aware HDR response steers
    -- exposure, contrast and saturation instead of a tone curve.
    local hdrContrast, hdrSaturation = 1, 1
    if BUILD.hdr then
        hdrContrast = uiNumber('HDR Contrast', 1, 0.85, 1.2)
            * (1 + SIGNALS.fog * uiNumber('HDR Fog Contrast', 0.40, 0, 1) * hdrStrength() * 0.08)
        hdrSaturation = uiNumber('HDR Saturation', 1, 0.8, 1.2)
        pure.pp.setTonemapping(ac.TonemapFunction.Linear)
        local gamma = pure.pp.getGammaModulator()
        if math.abs(gamma - 1) < 0.0001 then gamma = 0.9999 end
        ac.setPpTonemapGamma(gamma)
        pure.yebis.set('filmicContrast', 0)
    end
    pure.config.set('pp.saturation',
        numberOr(OUT12['config:pp.saturation'], 1) * numberOr(OUT15['config:pp.saturation'], 1) * hdrSaturation, true)
    pure.config.set('pp.contrast',
        numberOr(OUT12['config:pp.contrast'], 1) * numberOr(OUT15['config:pp.contrast'], 1) * hdrContrast, true)
    -- Sun saturation: V1.2 lighting sets the base, V1.5 sky adds its sunset boost.
    local sunSaturation = (E.lighting == 1 and numberOr(OUT12['config:light.sun.saturation'], 1) or 1)
        * (E.sky == 2 and numberOr(OUT15['config:light.sun.saturation'], 1) or 1)
    pure.config.set('light.sun.saturation', sunSaturation, true)
    -- Vignette: the finishing-profile base scaled by the V1.2 strength, lens
    -- profile and field-of-view response (V1.2 strength 0.01 is neutral).
    pure.yebis.set('vignetteStrength', numberOr(OUT15['yebis:vignetteStrength'], 0.025)
        * numberOr(OUT12['yebis:vignetteStrength'], 0.01) / 0.01)
    -- Dashcam (V1.5) overrides the regular lens distortion (V1.2) while enabled.
    if OUT15['yebis:lensDistortionEnabled'] == true then
        pure.yebis.set('lensDistortionEnabled', true)
        pure.yebis.set('lensDistortionRoundness', numberOr(OUT15['yebis:lensDistortionRoundness'], 0))
        pure.yebis.set('lensDistortionSmoothness', numberOr(OUT15['yebis:lensDistortionSmoothness'], 0))
    else
        pure.yebis.set('lensDistortionEnabled', OUT12['yebis:lensDistortionEnabled'] == true)
        pure.yebis.set('lensDistortionRoundness', numberOr(OUT12['yebis:lensDistortionRoundness'], 0.05))
        pure.yebis.set('lensDistortionSmoothness', numberOr(OUT12['yebis:lensDistortionSmoothness'], 1))
    end
    -- The shared exposure trim (sceneEV): the V1.2 exposure engine folds it
    -- in itself; the other exposure engines take it as the CBE multiplier.
    if E.exposure ~= 1 then
        pure.exposure.cbe.setMultiplier(2 ^ sceneEV())
    end
end

function update_pure_script(dt)
    if type(dt) ~= 'number' or dt ~= dt then dt = 0 end
    readEngines()
    for k in pairs(OUT12) do OUT12[k] = nil end
    for k in pairs(OUT15) do OUT15[k] = nil end
    runBlock('V1.2 engine', V12.update, dt)
    runBlock('V1.5 engine', V15.update, dt)
    runBlock('final pass', compose)
end
'''
