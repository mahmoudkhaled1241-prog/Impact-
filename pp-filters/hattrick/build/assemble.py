#!/usr/bin/env python3
"""Assemble ST6IX HAT-TRICK from the V1.2 and V1.5 sources.

Usage: python3 assemble.py [--hdr] [output.lua]

Each engine's code is taken verbatim by line range, checked against anchor
text, and wrapped in its own scope with a gated `pure`/`ac` view.
"""
import sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
HDR = '--hdr' in sys.argv[1:]
ARGS = [a for a in sys.argv[1:] if a != '--hdr']

def load(name):
    text = open(os.path.join(HERE, name), encoding='utf-8-sig').read()
    return text.replace('\r\n', '\n').split('\n')

v12 = load('src_ST6IX_V1.2.lua')
v15 = load('src_ST6IX_V1.5.lua')

def span(lines, first, last, first_expect, last_expect):
    a, b = lines[first - 1], lines[last - 1]
    assert first_expect in a, (first, a)
    assert last_expect in b, (last, b)
    return lines[first - 1:last]

def replace_once(text, old, new):
    assert text.count(old) == 1, (text.count(old), old[:80])
    return text.replace(old, new)

out = []
core = open(os.path.join(HERE, 'part_core.lua'), encoding='utf-8').read().rstrip('\n')
if HDR:
    core = replace_once(core, "local BUILD = { name = 'ST6IX HAT-TRICK V1.0', hdr = false }",
                        "local BUILD = { name = 'ST6IX HAT-TRICK V1.0 HDR', hdr = true }")
    core = replace_once(core, "-- ST6IX HAT-TRICK V1.0\n", "-- ST6IX HAT-TRICK V1.0 HDR\n"
        "-- HDR build: CSP performs the final HDR display mapping, so YEBIS runs a\n"
        "-- linear tone function and the scene-aware HDR response works through\n"
        "-- exposure, contrast and saturation (HDR Tone Mapping page).\n")
out.append(core)

# ---------------------------------------------------------------- V1.2 engine
v12_top = '\n'.join(span(v12, 5, 255, 'local VERSION = 1.80', 'end'))
v12_top = v12_top.replace('local VERSION = 1.80\n', '')
v12_update = '\n'.join(span(v12, 525, len(v12) - 1 if v12[-1] == '' else len(v12),
                            'function update_pure_script(dt)', 'end'))
v12_update = replace_once(v12_update, 'function update_pure_script(dt)', 'V12.update = function(dt)')
v12_update = replace_once(v12_update,
    "        clamp((cbeMaximum - cbeAverage) / math.max(cbeAverage, 0.001) / 2.5, 0, 1), dt, 0.35)\n",
    "        clamp((cbeMaximum - cbeAverage) / math.max(cbeAverage, 0.001) / 2.5, 0, 1), dt, 0.35)\n"
    "    SIGNALS.highlight = highlightSignal\n")
v12_update = replace_once(v12_update,
    "        + badness * 0.18 + worldFog * 0.12 + overcast * 0.08, 0, 1)\n",
    "        + badness * 0.18 + worldFog * 0.12 + overcast * 0.08, 0, 1)\n"
    "    SIGNALS.darkness = darknessSignal\n"
    "    SIGNALS.fog = math.max(worldFog, mist)\n")
v12_update = replace_once(v12_update,
    "        + tunnelEVBoost\n",
    "        + tunnelEVBoost\n        + sceneEV()\n")
if HDR:
    # CSP performs the final HDR mapping: the SDR curves, their gamma and YEBIS
    # filmic contrast are replaced by the final pass (linear, neutral gamma).
    a = v12_update.index("    local tonemapper = math.floor(number('Tone Curve',1,1,3))\n")
    b_mark = "    ac.setPpTonemapGamma(gamma)\n"
    b = v12_update.index(b_mark, a) + len(b_mark)
    v12_update = v12_update[:a] + v12_update[b:]
    v12_update = replace_once(v12_update,
        "    pure.yebis.set('filmicContrast', number('Filmic Contrast',0.35,0,1))\n", "")
v12_update = replace_once(v12_update,
    "    yebisTry('vignetteFovDependency', number('Vignette FOV Dependence',0.25,0,1))\n", "")
# The V1.5 God Ray Length slider is the master length for these YEBIS rays.
v12_update = replace_once(v12_update,
    "        if sunRaysOn or moonRays > 0 then\n"
    "            pure.yebis.set('godraysEnabled', true)\n"
    "            pure.yebis.set('godraysLength', math.max(0.001, sunRays + moonRays))\n",
    "        local rayLengthScale = number('godray_length',10,0,20) / 10\n"
    "        if (sunRaysOn or moonRays > 0) and rayLengthScale > 0 then\n"
    "            pure.yebis.set('godraysEnabled', true)\n"
    "            pure.yebis.set('godraysLength', math.max(0.001, (sunRays + moonRays) * rayLengthScale))\n")

out.append('''
-- ============================================================================
-- ENGINE 1: ST6IX V1.2 (Gamma V1.8 photographic engine)
-- ============================================================================
local V12 = {}
do
local pure, ac = makeGatedApi(12, OUT12)
''')
out.append(v12_top)
out.append('''
V12.reset = function()
    smoothState = {}
    lockedExposure = nil
    lastLock = false
    lockedWhiteBalance = nil
    lastWhiteBalanceLock = false
    tunnelWasDark = false
    tunnelFlash = 0
    starOutput.brightness = 0
    starOutput.saturation = 0.9
    starOutput.exponent = 1.0
    lastStarOutput = nil
    lastStarBase = nil
    dofWasEnabled = nil
end
''')
out.append(v12_update)
out.append('end')

# ---------------------------------------------------------------- V1.5 engine
v15_top = span(v15, 1, 293, 'ST6IX V1.5', '')
v15_top = [l for l in v15_top]
v15_top[0] = '-- V1.5 tables and tonemappers (weather-aware finishing, based on V1.4).'
v15_top = '\n'.join(v15_top)

dyn = '\n'.join(span(v15, 302, 312, 'local dyn_range_adjust = _l_Exposure_lut[1]^1.5', 'local uchimura__gain'))
uchi = '\n'.join(span(v15, 315, 321, 'pure.pp.setTonemapping(ac.TonemapFunction.Uchimura)', 'ppTonemapUchimura.gain'))
retro = '\n'.join(span(v15, 326, 390, 'if _l_current_tonemapping ~= 3 then retro_intro_time = 0.0 end', 'end'))
retro = replace_once(retro, 'if _l_current_tonemapping ~= 3 then', 'if _l_current_tonemapping ~= 7 then')
hyper = '\n'.join(span(v15, 393, 406, 'retro_intro_time = 0.0', 'TONEMAPPING__agx_sat'))
aces = '\n'.join(span(v15, 412, 415, 'if not _l_init then', 'end'))
lottes = '\n'.join(span(v15, 417, 425, 'local exp_mod = (1-_l_Exposure_lut[4])', 'ppTonemapLottes.gain'))

def indent(block, spaces):
    pad = ' ' * spaces
    res = []
    for line in block.split('\n'):
        res.append(pad + line if line.strip() else line)
    return '\n'.join(res)

def dedent(block, spaces):
    res = []
    for line in block.split('\n'):
        res.append(line[spaces:] if line.startswith(' ' * spaces) else line.lstrip() if not line.strip() else line)
    return '\n'.join(res)

set_tm = '''
-- Tone Curve ids handled by this engine (1-based, shared list): 4 Neon Noir,
-- 5 ST6IX Dusk, 6 Hyperchrome, 7 Retrograde, 8 BABAYAGA, 9 ST6IX Lottes.
-- V1.5 selected these by thresholds that did not line up with its labels;
-- each id now runs the curve its name and code comments describe.
local function set_tonemapping(dt, mode)
    if BUILD.hdr then
        -- CSP performs the final HDR tone mapping (see the final pass).
        _l_current_tonemapping = mode
        return
    end
    if mode == 4 then
        pure.pp.setTonemapping(ac.TonemapFunction.Sensitometric)
    elseif mode >= 5 and mode <= 7 then
''' + indent(dedent(dyn, 8), 8) + '''

        if mode == 5 then
''' + indent(dedent(uchi, 12), 12) + '''
        else
            if mode == 7 then
''' + indent(dedent(retro, 16), 16) + '''
            else
''' + indent(dedent(hyper, 16), 16) + '''
            end
            pure.pp.setCustomRGBTonemapping(tonemap__custom)
        end
    elseif mode == 8 then
''' + indent(dedent(aces, 8), 8) + '''
    elseif mode == 9 then
''' + indent(dedent(lottes, 8), 8) + '''
    end

    -- Tonemap Gamma trims every curve; 1.10 is neutral for this engine.
    local gammaTrim = pure.script.ui.getValue('Tonemap Gamma')
    gammaTrim = type(gammaTrim) == 'number' and gammaTrim / 1.10 or 1
    local tmp_gamma = gamma * pure.pp.getGammaModulator() * gammaTrim
    if tmp_gamma > 0.9999 and tmp_gamma < 1.0001 then
        tmp_gamma = 0.9999
    end
    ac.setPpTonemapGamma(tmp_gamma)
    _l_current_tonemapping = mode
end
'''

v15_update = '\n'.join(span(v15, 1107, 2130, '-- ====', 'end'))
v15_update = replace_once(v15_update, 'function update_pure_script(dt)', 'V15.update = function(dt)')
v15_update = replace_once(v15_update,
    '        hdr_highlight_recovery = pure.script.ui.getValue("hdr_highlight_recovery")\n    end\n',
    '        hdr_highlight_recovery = pure.script.ui.getValue("hdr_highlight_recovery")\n    end\n'
    '    SIGNALS.recovery = hdr_highlight_recovery or 0\n')

out.append('''
-- ============================================================================
-- ENGINE 2: ST6IX V1.5 (Professional Edition)
-- ============================================================================
local V15 = {}
do
local pure, ac = makeGatedApi(15, OUT15, v15GetValue)
''')
out.append(v15_top)
out.append(set_tm)
out.append('''
V15.init = function()
    retro_intro_time = 0.0
    _l_current_tonemapping = DEFAULT_TONE
    -- Keep the sun/moon size slider and Pure's config in sync from the start.
    local cfgSunMoon = pure.config.get("sun.sun_moon_size") or 0
    if cfgSunMoon and cfgSunMoon > 0 then
        if pure.script.ui.setValue then pure.script.ui.setValue("sun.sun_moon_size", cfgSunMoon) end
        _last_cfg_sun_moon = cfgSunMoon
        _last_ui_sun_moon = cfgSunMoon
    else
        _last_ui_sun_moon = pure.script.ui.getValue("sun.sun_moon_size")
        _last_cfg_sun_moon = _last_ui_sun_moon
    end
    local initLength = pure.script.ui.getValue("godray_length") or 10
    local initIntensity = math.min(2.0, math.max(0.0, initLength / 10.0))
    local initActive = (initLength > 0) and 1 or 0
    for _, prefix in ipairs({ "godrays.", "shaders.godrays.", "shaders.sunrays." }) do
        pure.config.set(prefix .. "active", initActive, true)
        pure.config.set(prefix .. "length", initLength, true)
        pure.config.set(prefix .. "intensity", initIntensity, true)
    end
    pure.config.set("pp.godrays.length", initLength, true)
    pure.config.set("pp.godrays.intensity", initIntensity, true)
    _l_init = false
end
''')
out.append(v15_update)
out.append('end')

sys.path.insert(0, HERE)
import layout
out.append(layout.build_main(v12, v15, HDR).rstrip('\n'))

target = ARGS[0] if ARGS else os.path.join(os.path.dirname(HERE),
    'ST6IX_HatTrick_V1.0_HDR.lua' if HDR else 'ST6IX_HatTrick_V1.0.lua')
open(target, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print('written', target)
