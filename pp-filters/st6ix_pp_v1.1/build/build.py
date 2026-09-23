#!/usr/bin/env python3
"""Build ST6IX V1.3 (SDR and HDR) from ST6IX V1.2.

V1.3 is V1.2 unchanged underneath, plus the Skydomes and HDR & Clarity tabs
and film grain from ST6IX V1.5, restyled pages, renamed tone curves, and
Render Quality fixed at High (no radio button).

Usage: python3 build.py            -> ../ST6IX_PP_V1.3.lua, ../ST6IX_PP_V1.3_HDR.lua
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
BAR = '━' * 37


def load(name):
    return open(os.path.join(HERE, name), encoding='utf-8').read()


def replace_once(text, old, new):
    assert text.count(old) == 1, (text.count(old), old[:90])
    return text.replace(old, new)


def lua_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def index_controls(text):
    found = {}
    pat = re.compile(r"""(?:pure\.script\.ui\.)?(?:addSliderFloat|addSliderInteger|addCheckbox|addRadioButtons|slider|sliderInt)\(\s*'([^']+)'""")
    for line in text.split('\n'):
        if line.strip().startswith('--'):
            continue
        m = pat.search(line)
        if m and m.group(1) not in found:
            found[m.group(1)] = line.strip()
    return found


# Same options, same order; only the labels gain their ST6IX style.
RADIO_LABELS = {
    'Overall Mode': 'Natural🌿,Photorealistic📸,Manual⚙️',
    'Morning Preset': 'Natural Morning🌿,Bright Morning☀️,Dark Morning🌑,Cinematic Morning🎬,Custom⚙️',
    'Night Preset': 'Natural Night🌙,Bright Night🌕,Dark Night🌑,Cinematic Night🎬,Custom⚙️',
    'Fog Color Preset': 'Weather Adaptive🌦️,Neutral⚪,Cold Morning❄️,Warm Sunset🌇,Storm⛈️,Night🌙',
    'Sky Preset': 'Natural🌿,Golden Hour🌇,Overcast Soft☁️,Pastel Dawn🌅,City Haze🏙️,Storm⛈️,Custom⚙️',
    'Glare Style': 'Gentle🌤️,GT Broadcast📺,Cinematic🎬,Le Mans🏁,Lens Flare💫,Wet Night🌧️,Golden Hour🌇,Custom⚙️',
    'Tunnel Preset': 'Normal🚗,Flash⚡,Blinding☀️,Cinematic🎬',
    'Exposure Metering': 'Balanced⚖️,Center Weighted🎯,Cockpit Weighted🏎️,Photography📸',
    'Tone Curve': 'Silver Screen🎞️,Grand Tour🏁,Neon Punch⚡',
    'Lens Profile': 'Clean✨,Cinematic🎬,Vintage📼,Telephoto🔭,Custom⚙️',
    'Reflection Preset': 'Normal🚗,Cinematic🎬,Photography📸,Custom⚙️',
    'Effect Preview': 'Normal👁️,Exposure📷,Glare💫,Reflections✨,Fog🌫️',
}

# New controls (from ST6IX V1.5, with product names).
NEW_CONTROLS = {
    'Skydome Preset': "pure.script.ui.addRadioButtons('Skydome Preset', 1, 'Off🌍,ST6IX Nebula🌌,ST6IX Madara🔴,ST6IX Black Hole🕳️,ST6IX Black Matter⚫,ST6IX Black Matter Colour🟣')",
    'Skydome Brightness': "slider('Skydome Brightness', 1.00, 0.10, 5.00, 'Skydome luminosity')",
    'Skydome Contrast': "slider('Skydome Contrast', 1.00, 0.10, 3.00, 'Skydome colour contrast')",
    'Skydome Rotation': "slider('Skydome Rotation', 0.50, 0.00, 3.00, 'Horizontal rotation of the skydome')",
    'Skydome Height': "slider('Skydome Height', 1.00, 0.50, 2.00, 'Vertical position of the skydome')",
    'Clarity Preset': "pure.script.ui.addRadioButtons('Clarity Preset', 1, 'Off⭕,Subtle HDR🌤️,Full HDR☀️,Ultra HDR🔥,Cinematic Sharp🎥,Manual⚙️')",
    'Sharpness': "slider('Sharpness', 0.35, 0.00, 1.00, 'Edge definition and fine detail; eased at night and in the cockpit')",
    'Clarity': "slider('Clarity', 0.45, 0.00, 1.00, 'Midtone contrast for a vivid, HDR-like look')",
    'Micro Contrast': "slider('Micro Contrast', 0.22, 0.00, 0.50, 'Fine texture detail')",
    'Brightness Boost': "slider('Brightness Boost', 1.14, 0.80, 1.50, 'Widens the highlight range')",
    'Color Vibrance': "slider('Color Vibrance', 0.18, 0.00, 0.50, 'Lifts muted colours more than saturated ones')",
    'Highlight Recovery': "slider('Highlight Recovery', 0.28, 0.00, 0.60, 'Lowers exposure slightly when bright highlights dominate')",
    'Film Grain': "pure.script.ui.addCheckbox('Film Grain', false, 'Analog film grain texture for a cinematic look')",
    'Film Grain Strength': "slider('Film Grain Strength', 1.00, 0.00, 10.00, 'Film grain intensity; slightly finer in daylight')",
}

HDR_TONE = ['Scene Aware HDR', 'HDR Adaptation Strength', 'HDR Highlight Protection', 'HDR Shadow Lift',
            'HDR Fog Contrast', 'HDR Brightness', 'HDR Contrast', 'HDR Saturation']


def layout(hdr):
    """Pages as a list of items: ('page', name) | ('h', title, note) | ('c', names...) | ('t', text) | ('sep',)."""
    P = []
    page = lambda n: P.append(('page', n))
    h = lambda title, note=None: P.append(('h', title, note))
    c = lambda *names: P.append(('c',) + names)
    t = lambda text: P.append(('t', text))

    page('🎯Guide')
    h('🏁 ST6IX V1.3%s · PHOTOGRAPHIC PP FILTER' % (' HDR' if hdr else ''),
      'Every slider is live in every mode. Pick a look, then fine-tune.')
    if hdr:
        t('📺 HDR: Windows HDR on | CSP: DXGI flip model + HDR support | AC windowed/borderless')
    h('🎯 SIGNATURE LOOKS', 'Set each tab as shown, or mix and match.')
    t('🌅 CLEAR MORNING - Daytime→ Bright Morning | Sky→ Natural')
    t('   Glare→ Gentle' + ('' if hdr else ' | Tonemap→ Silver Screen'))
    t('🏁 RACE BROADCAST - Daytime→ Photorealistic | Glare→ GT Broadcast')
    t('   HDR&Clarity→ Full HDR' + ('' if hdr else ' | Tonemap→ Grand Tour'))
    t('🌇 GOLDEN HOUR - Daytime→ Cinematic Morning | Sky→ Golden Hour')
    t('   Glare→ Golden Hour | Reflections→ Cinematic')
    t('🌧️ WET NIGHT - Night→ Cinematic Night | Glare→ Wet Night')
    t('   Reflections→ Cinematic' + ('' if hdr else ' | Tonemap→ Neon Punch'))
    t('🌌 COSMIC NIGHT - Night→ Dark Night | Skydomes→ ST6IX Nebula')
    t('   Glare→ Cinematic | HDR&Clarity→ Subtle HDR')
    t('📸 PHOTO MODE - LensFX→ Cinematic + Depth of Field | Film Grain on')
    t('   Exposure→ Photography | Lock Exposure for the shot')
    h('💡 TIPS')
    t('Full HDR☀️ suits most daytime, Subtle HDR🌤️ keeps nights clean.')
    t('Cinematic Sharp🎥 is made for replays and screenshots.')
    t('Diagnostics tab: live readings when something looks off.')

    page('☀️Daytime')
    h('🎬 OVERALL LOOK', 'Modes add a subtle finish; every slider stays live.')
    c('Overall Mode')
    h('🌅 MORNING LOOK', 'Starting look for the daylight hours')
    c('Morning Preset', 'Morning Preset Strength')
    h('☀️ SUNLIGHT')
    c('Daylight Multiplier', 'Day Sun Level', 'Day Sun Saturation', 'Day Sun Speculars', 'Lambert Gamma',
      'Spectrum Adaptation')
    h('🌤️ AMBIENT & SKY LIGHT')
    c('Day Ambient Level', 'Day Sky Level', 'Day Advanced Ambient', 'Ambient V2 Sun', 'Ambient V2 Sky',
      'Ambient V2 Clouds', 'Weather Ambient Balance')
    h('🎨 DAYTIME COLOUR')
    c('Day Color Saturation', 'Day Contrast')
    h('🌡️ WHITE BALANCE', 'Adapts to time, clouds, fog and rain within safe limits')
    c('Day Color Temperature', 'Automatic White Balance', 'White Balance Strength', 'White Balance Warmth Bias',
      'White Balance Tint', 'Lock White Balance')
    h('💡 CAR LIGHTS & SCREENS')
    c('Day CSP Light Bounce', 'Day CSP Light Emissive', 'Day Display Brightness')

    page('🌙Night')
    h('🌙 NIGHT LOOK')
    c('Night Preset')
    h('🏙️ LIGHT POLLUTION & AMBIENT')
    c('Night Light Pollution Level', 'Night Light Pollution Density', 'Night Lowest Ambient')
    h('🌕 MOON & STARS')
    c('Moon Light', 'Moon Appearance', 'Stars Appearance', 'Stars Brightness', 'Stars Saturation', 'Stars Exponent')
    h('🔭 CELESTIAL REALISM', 'Moon and stars react to elevation, clouds, fog and city light')
    c('Adaptive Celestial Rendering', 'Celestial Weather Extinction', 'Moon Elevation Response',
      'Moon Star Suppression', 'Deep Sky Visibility')
    h('🎨 NIGHT COLOUR')
    c('Night Color Saturation', 'Night Contrast', 'Night Color Temperature')
    h('💡 CAR LIGHTS & SCREENS')
    c('Night CSP Light Bounce', 'Night CSP Light Emissive', 'Night Display Brightness')

    page('🌤️Sky&Clouds')
    h('🌤️ SKY LOOK', 'Weather refines the look with smooth transitions')
    c('Sky Preset', 'Sky Preset Strength', 'Sky Weather Response', 'Sky Transition Speed')
    h('🌈 SKY COLOUR')
    c('Day Sky Brightness', 'Day Sky Saturation', 'Twilight Sky Brightness', 'Twilight Sky Saturation',
      'Night Sky Brightness', 'Night Sky Saturation')
    h('☁️ CLOUDS')
    c('Day Cloud Brightness', 'Day Cloud Contrast', 'Day Cloud Softness', 'Twilight Cloud Brightness',
      'Twilight Cloud Contrast', 'Twilight Cloud Softness', 'Night Cloud Brightness', 'Night Cloud Contrast',
      'Night Cloud Softness')
    h('☀️ SUN & MOON SIZE')
    c('Sun Apparent Size', 'Moon Apparent Size')

    page('🌌Skydomes')
    h('🌌 CUSTOM SKYDOMES', 'Replace the sky with ST6IX cosmic backgrounds')
    c('Skydome Preset')
    t('↳ Off: normal sky | Others: ST6IX skydome textures')
    h('🎨 SKYDOME APPEARANCE')
    c('Skydome Brightness', 'Skydome Contrast')
    h('📍 SKYDOME POSITION')
    c('Skydome Rotation', 'Skydome Height')

    page('🌫️Fog')
    h('🌫️ FOG FINE TUNING', "Scales Pure's live weather fog; transitions are preserved")
    c('Enable Fog Fine Tuning', 'Fog Density', 'Fog Distance', 'Fog Blend', 'Fog Height', 'Fog Exponent')
    h('🎨 FOG COLOUR')
    c('Custom Fog Color', 'Fog Color Preset', 'Adaptive Fog Color Strength', 'Fog Color Red', 'Fog Color Green',
      'Fog Color Blue', 'Fog Color Mix')
    h('🌄 BACKLIGHT & HORIZON')
    c('Fog Backlight', 'Horizon Fog', 'Fog Cubemap Visibility')

    page('✴️Bloom')
    h('✴️ BLOOM', 'Restrained, source-aware bloom')
    c('Bloom Enabled', 'Bloom Strength', 'Bloom Threshold', 'Bloom Radius', 'Bloom Levels', 'Bloom Gamma',
      'Bloom Filter Threshold')

    page('💫Glare')
    h('💫 GLARE STYLE')
    c('Glare Enabled', 'Glare Style', 'Glare Style Strength')
    h('⚡ REACTIVE GLARE', 'Adapts to exposure, highlights and time of day')
    c('Reactive Glare', 'Reactive Glare Strength', 'Night Light Emphasis', 'Source Aware Glare',
      'Sun Glare Response', 'Headlight Glare Response', 'Emissive Color Protection')
    h('☀️ SUN BLINDING')
    c('Sun Blinding', 'Sun Blinding Iris')
    h('⭐ STAR GLARE')
    c('Glare Master', 'Star Strength', 'Star Length', 'Star Streaks', 'Star Softness', 'Star Filter Threshold')
    h('👻 LENS ARTIFACTS')
    c('Ghost Strength', 'Afterimage Strength', 'Afterimage Length', 'Anamorphic Glare')

    page('📷Exposure')
    h('🚇 TUNNELS', 'Normal is neutral; the others adapt inside and recover at the exit')
    c('Tunnel Preset', 'Tunnel Interior Lift', 'Tunnel Opening Protection', 'Tunnel Recovery Speed')
    h('🧠 SMART EXPOSURE')
    c('Adaptive Scene Exposure', 'Exposure Metering', 'Per Camera Exposure Memory', 'Adaptation Strength',
      'Highlight Protection', 'Interior Metering Bias', 'Maximum Target Shift', 'Camera Style Response')
    h('⚙️ AUTO EXPOSURE ENGINE')
    c('CBE Mix', 'CBE Target', 'CBE Sensitivity', 'Minimum Exposure', 'Maximum Exposure',
      'Dark Adaptation Speed', 'Bright Adaptation Speed', 'YEBIS Target')
    h('🎚️ COMPENSATION')
    c('Exposure Compensation EV', 'Cockpit Compensation EV', 'Lock Exposure')

    if hdr:
        page('🎨HDR Tonemap')
        h('🎨 HDR OUTPUT', 'CSP performs the final HDR tone mapping for your display.')
        t('Enable DXGI flip model + HDR support in CSP; run AC windowed or borderless.')
        h('🧠 SCENE AWARE HDR', 'Shapes the scene before CSP maps it to your display')
        c('Scene Aware HDR', 'HDR Adaptation Strength', 'HDR Highlight Protection', 'HDR Shadow Lift',
          'HDR Fog Contrast')
        h('🎚️ HDR FINISH')
        c('HDR Brightness', 'HDR Contrast', 'HDR Saturation')
    else:
        page('🎨Tonemap')
        h('🎨 TONE CURVE', 'Silver Screen: filmic | Grand Tour: broadcast | Neon Punch: punchy')
        c('Tone Curve', 'Tonemap Gamma')
        h('🧠 SCENE AWARE TONE', 'Refines the curve for highlights, darkness and fog')
        c('Scene Aware Tone Mapping', 'Tone Adaptation Strength', 'Dynamic Highlight Rolloff',
          'Dynamic Shadow Detail', 'Fog Contrast Protection')
        h('🎞️ SILVER SCREEN', 'AgX film curve: soft highlights, natural colour')
        c('AgX Exposure', 'AgX Slope', 'AgX Power', 'AgX Saturation')
        h('🏁 GRAND TOUR', 'Uchimura curve, the Gran Turismo tonemapper')
        c('Uchimura Peak', 'Uchimura Contrast', 'Uchimura Linear Start', 'Uchimura Linear Length',
          'Uchimura Black', 'Uchimura Gain')
        h('⚡ NEON PUNCH', 'Lottes curve: bold contrast and colour')
        c('Lottes Contrast', 'Lottes Gamma', 'Lottes HDR Max', 'Lottes Mid In', 'Lottes Mid Out', 'Lottes Gain')

    page('🔍HDR&Clarity')
    h('🔍 HDR & CLARITY', 'HDR-grade sharpness, clarity and colour depth')
    c('Clarity Preset')
    t('↳ Presets set the sliders below; choose Manual⚙️ to set them yourself.')
    h('🔪 SHARPNESS')
    c('Sharpness')
    h('💎 CLARITY & LOCAL CONTRAST')
    c('Clarity', 'Micro Contrast')
    h('✨ HDR ENHANCEMENT')
    c('Brightness Boost', 'Color Vibrance', 'Highlight Recovery')

    page('📹LensFX')
    h('📹 LENS PROFILE', 'Physical lens character')
    c('Lens Profile', 'Lens Profile Strength')
    h('☀️ GOD RAYS', 'Sun, camera and field-of-view aware')
    c('Adaptive Godrays', 'Godrays Strength', 'Godrays FOV Response', 'Godrays Sun Facing Response',
      'Godrays Glare Ratio', 'Moon Godrays Strength')
    h('📷 VIGNETTE')
    c('Vignette Strength', 'Vignette FOV Dependence')
    h('🌈 CHROMATIC ABERRATION')
    c('Chromatic Aberration', 'Chromatic Samples', 'Chromatic Lateral', 'Chromatic Uniform')
    h('🔍 LENS DISTORTION')
    c('Lens Distortion', 'Lens Roundness', 'Lens Smoothness')
    h('🎬 FILM GRAIN')
    c('Film Grain', 'Film Grain Strength')
    if not hdr:
        h('🎞️ FILM CONTRAST')
        c('Filmic Contrast')
    h('📸 DEPTH OF FIELD', 'For replays and screenshots')
    c('Depth of Field', 'DOF Focus Distance', 'DOF Aperture', 'DOF Quality')

    page('✨Reflections')
    h('✨ REFLECTION LOOK')
    c('Reflection Preset', 'Adaptive Reflections', 'Reflection Weather Response', 'Reflection CPL Strength',
      'Reflection Highlight Response')
    h('🌧️ WET WEATHER', 'Wet roads, standing water and night lights')
    c('Wet Weather Rendering', 'Wet Reflection Gain', 'Wet Headlight Bloom', 'Rain Saturation Retention',
      'Wet Black Depth')
    h('🪞 REFLECTION DETAIL')
    c('Reflection Level', 'Reflection Saturation', 'Reflection Emissive Boost', 'Fresnel Strength')
    h('🌑 AMBIENT OCCLUSION')
    c('VAO Amount', 'VAO Track Exponent', 'VAO Dynamic Exponent', 'Weather VAO Adaptation')

    page('🔧Diagnostics')
    h('🔧 DIAGNOSTICS', 'Live scene readings and warnings')
    c('Diagnostics Enabled', 'Effect Preview', 'Effect Preview Strength')
    h('📊 LIVE READINGS')
    P.append(('raw', "pure.script.ui.addStateFloat('Live Exposure', 0)"))
    for s in ['Live Highlights', 'Camera Occlusion', 'Wet Surface', 'World Fog', 'Sun Facing', 'Tunnel Response',
              'Star Output']:
        P.append(('raw', "pure.script.ui.addStateFloat('%s', 0)" % s))
    P.append(('raw', "pure.script.ui.addStateString('Render Status', 'Diagnostics disabled')"))
    return P


def build_ui(src_controls, hdr):
    lines, used = [], set()
    for item in layout(hdr):
        kind = item[0]
        if kind == 'page':
            lines += ['', '    pure.script.ui.addPage(%s)' % lua_str(item[1])]
        elif kind == 'h':
            lines.append('    header(%s%s)' % (lua_str(item[1]), ', ' + lua_str(item[2]) if item[2] else ''))
        elif kind == 't':
            lines.append('    pure.script.ui.addText(%s)' % lua_str(item[1]))
        elif kind == 'raw':
            lines.append('    ' + item[1])
        elif kind == 'c':
            for name in item[1:]:
                assert name not in used, ('placed twice', name)
                used.add(name)
                if name in NEW_CONTROLS:
                    lines.append('    ' + NEW_CONTROLS[name])
                    continue
                assert name in src_controls, ('unknown control', name)
                decl = src_controls[name]
                if name in RADIO_LABELS:
                    m = re.match(r"(.*addRadioButtons\('[^']+', \d+, )'([^']*)'\)$", decl)
                    assert m, decl
                    assert len(m.group(2).split(',')) == len(RADIO_LABELS[name].split(',')), name
                    decl = m.group(1) + lua_str(RADIO_LABELS[name]) + ')'
                lines.append('    ' + decl)
    missing = [n for n in src_controls if n not in used and n != 'Render Quality']
    assert not missing, ('controls not placed', missing)
    return '\n'.join(lines)


FX_TOP = '''
-- ============================================================================
-- ST6IX EXTRA FX (from ST6IX V1.5): skydomes, HDR & clarity, film grain
-- ============================================================================
-- Clarity Preset: 1 Off, 2 Subtle HDR, 3 Full HDR, 4 Ultra HDR,
-- 5 Cinematic Sharp, 6 Manual (sliders).
local CLARITY_PRESETS = {
    [1] = { sharpness = 0.00, clarity = 0.00, micro = 0.00, brightness = 1.00, vibrance = 0.00, recovery = 0.00 },
    [2] = { sharpness = 0.12, clarity = 0.14, micro = 0.06, brightness = 1.00, vibrance = 0.03, recovery = 0.12 },
    [3] = { sharpness = 0.18, clarity = 0.22, micro = 0.10, brightness = 1.02, vibrance = 0.06, recovery = 0.18 },
    [4] = { sharpness = 0.25, clarity = 0.30, micro = 0.14, brightness = 1.04, vibrance = 0.08, recovery = 0.24 },
    [5] = { sharpness = 0.20, clarity = 0.20, micro = 0.12, brightness = 1.01, vibrance = 0.04, recovery = 0.16 },
}

-- Skydome Preset: 1 Off, 2-6 ST6IX textures (brightness and exponent tuned per texture).
local SKYDOME_PATH = 'system/cfg/ppfilters/pure_scripts/textures/'
local SKYDOMES = {
    [2] = { texture = 'ST6IX Nebula.dds', brightness = 10, exponent = 1.5, height = 1.00 },
    [3] = { texture = 'ST6IX MADARA.dds', brightness = 8, exponent = 1.8, height = 1.20 },
    [4] = { texture = 'ST6IX blackhole.dds', brightness = 12, exponent = 2.0, height = 1.00 },
    [5] = { texture = 'ST6IX black-matter.dds', brightness = 11, exponent = 1.9, height = 1.10 },
    [6] = { texture = 'Black matter Colored.dds', brightness = 9, exponent = 1.7, height = 0.95 },
}
if type(ac.SkyCloudsCover) == 'function' then
    cover = cover or ac.SkyCloudsCover()
    if type(ac.addWeatherCloudCover) == 'function' then ac.addWeatherCloudCover(cover) end
end
local activeSkydome = nil

-- Reads the HDR & Clarity tab once per frame.
local function clarityFinish()
    local preset = CLARITY_PRESETS[math.floor(number('Clarity Preset', 1, 1, 6))]
    local f
    if preset then
        f = { sharpness = preset.sharpness, clarity = preset.clarity, micro = preset.micro,
              brightness = preset.brightness, vibrance = preset.vibrance, recovery = preset.recovery }
    else
        f = { sharpness = number('Sharpness', 0.35, 0, 1), clarity = number('Clarity', 0.45, 0, 1),
              micro = number('Micro Contrast', 0.22, 0, 0.5), brightness = number('Brightness Boost', 1.14, 0.8, 1.5),
              vibrance = number('Color Vibrance', 0.18, 0, 0.5), recovery = number('Highlight Recovery', 0.28, 0, 0.6) }
    end
    f.contrast = 1 + f.clarity * 0.35 + f.micro * 0.12
    f.saturation = 1 + f.clarity * 0.08
    return f
end

local function applyExtraFX(finish, day, night, cockpit)
    -- Sharpening, eased at night and in the cockpit to keep noise down.
    local sharpen = finish.sharpness > 0.01
    pure.pp.set('spice.Sharpen.active', sharpen)
    pure.pp.set('spice.Sharpen.strength', sharpen and finish.sharpness * 1.15
        * math.lerp(1, 0.55, night) * math.lerp(1, 0.92, cockpit) or 0)
    -- Vibrance lifts muted colours more than saturated ones.
    local vibrance = finish.vibrance > 0.01
    pure.pp.set('spice.Saturation.active', vibrance)
    pure.pp.set('spice.Saturation.strength', vibrance and 1 + finish.vibrance * 0.6 or 1)
    pure.config.set('pp.brightness', finish.brightness, true)

    -- Film grain, slightly finer in daylight.
    local grain = check('Film Grain', false)
    pure.pp.set('spice.SensorNoise.active', grain)
    pure.pp.set('spice.SensorNoise.strength', grain
        and 4 * math.lerp(1, 0.6, day) * number('Film Grain Strength', 1, 0, 10) or 0)
    pure.pp.set('spice.SensorNoise.scale', grain and 0.4 or 0)

    -- Skydomes.
    if cover then
        local index = math.floor(number('Skydome Preset', 1, 1, 6))
        local dome = SKYDOMES[index]
        if index ~= activeSkydome then
            if dome then cover:setTexture(SKYDOME_PATH .. dome.texture) else cover:setTexture() end
            activeSkydome = index
        end
        cover.shadowRadius = 100000
        cover.shadowOpacityMultiplier = 0
        cover.texOffsetX = number('Skydome Rotation', 0.5, 0, 3) * 1.5
        local brightness, exponent = 1, 1
        if dome then
            brightness, exponent = dome.brightness, dome.exponent
            cover.texRemapY = number('Skydome Height', 1, 0.5, 2) * dome.height
        end
        local b = number('Skydome Brightness', 1, 0.1, 5) * brightness
        local e = number('Skydome Contrast', 1, 0.1, 3) * exponent
        cover.colorMultiplier = rgb(b, b, b)
        cover.colorExponent = rgb(e, e, e)
    end
end
'''

HEADER_FN = '''
local function header(title, note)
    pure.script.ui.addText('%s')
    pure.script.ui.addText(title)
    pure.script.ui.addText('%s')
    if note then pure.script.ui.addText(note) end
end
''' % (BAR, BAR)


def build(src_name, hdr):
    text = load(src_name).replace('\r\n', '\n')
    controls = index_controls(text)
    first_line = text.split('\n', 1)[0]
    head_end = text.index('\nlocal VERSION = 1.80\n')
    text = ('-- ST6IX V1.3%s: photographic post-processing for Assetto Corsa\n'
            '-- Pure Gamma 3.50 / %s\n'
            '-- The ST6IX V1.2 engine with skydomes, HDR & clarity and film grain from\n'
            '-- ST6IX V1.5. Every slider is live in every overall mode.\n'
            % (' HDR' if hdr else '', 'CSP HDR output (DXGI flip model + HDR support)' if hdr
               else 'CSP dynamic tonemapping')) + text[head_end:]
    if hdr:
        text = text.replace('\n-- CSP performs the final HDR display mapping, so YEBIS runs a linear tone\n'
                            '-- function here and the scene-aware HDR response works through exposure and colour.\n', '\n')
    # Pure rebuilds saved settings when the version changes (new control set).
    text = replace_once(text, 'local VERSION = 1.80\n', 'local VERSION = 1.90\n')

    # Extra FX need number()/check(); insert after the helper that defines sliderInt.
    anchor = 'local function sliderInt(name, default, minimum, maximum, tooltip)\n' \
             '    pure.script.ui.addSliderInteger(name, default, minimum, maximum, tooltip)\nend\n'
    text = replace_once(text, anchor, anchor + HEADER_FN + FX_TOP)

    # UI: everything between setVersion and the end of the diagnostics states.
    a = text.index('    pure.script.setVersion(VERSION)\n') + len('    pure.script.setVersion(VERSION)\n')
    b_mark = "    pure.script.ui.addStateString('Render Status', 'Diagnostics disabled')\n"
    b = text.index(b_mark) + len(b_mark)
    ui = build_ui(controls, hdr)
    text = text[:a] + ui + '\n' + text[b:]
    text = replace_once(text, "    pure.config.set('light.ambient_model_V2', true, true)\nend\n",
                        "    pure.config.set('light.ambient_model_V2', true, true)\n"
                        "    if type(pure.pp.UseSpice) == 'function' then pcall(pure.pp.UseSpice) end\n"
                        "    activeSkydome = nil\nend\n")

    # Update: HDR & Clarity finish, highlight recovery, extra FX.
    text = replace_once(text, "    local profile = profiles[mode] or profiles[2]\n",
                        "    local profile = profiles[mode] or profiles[2]\n    local finish = clarityFinish()\n")
    text = replace_once(text, "    pure.config.set('pp.saturation', colorSat",
                        "    pure.config.set('pp.saturation', colorSat * finish.saturation")
    text = replace_once(text, "    pure.config.set('pp.contrast', contrast",
                        "    pure.config.set('pp.contrast', contrast * finish.contrast")
    text = replace_once(text, "    pure.exposure.cbe.setMultiplier(2^ev)\n",
                        "    ev = ev - highlightSignal * finish.recovery * 0.6\n"
                        "    pure.exposure.cbe.setMultiplier(2^ev)\n")
    # Render Quality has no radio button any more; it stays at High.
    text = replace_once(text, "    yebisTry('glareQuality', RENDER_QUALITY[math.floor(number('Render Quality',3,1,4))] or 4)\n",
                        "    yebisTry('glareQuality', RENDER_QUALITY[3])\n")
    text = replace_once(text, "    if diagnosticsEnabled then\n        pure.script.ui.setValue('Live Exposure'",
                        "    applyExtraFX(finish, day, night, cockpit)\n\n"
                        "    if diagnosticsEnabled then\n        pure.script.ui.setValue('Live Exposure'")
    return text


for src, hdr, out in [('src_ST6IX_V1.2.lua', False, 'ST6IX_PP_V1.3.lua'),
                      ('src_ST6IX_V1.2_HDR.lua', True, 'ST6IX_PP_V1.3_HDR.lua')]:
    path = os.path.join(OUT, out)
    open(path, 'w', encoding='utf-8').write(build(src, hdr))
    print('written', path)
