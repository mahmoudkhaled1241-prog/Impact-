-- ST6IX HAT-TRICK V1.0 HDR
-- HDR build: CSP performs the final HDR display mapping, so YEBIS runs a
-- linear tone function and the scene-aware HDR response works through
-- exposure, contrast and saturation (HDR Tone Mapping page).
-- One filter, two engines: ST6IX V1.2 (Gamma V1.8 photographic engine) and
-- ST6IX V1.5 (Professional Edition). Each page chooses which engine drives it;
-- only the selected engine may write to the game, so the two never fight.
-- Pure radio buttons are 1-based throughout this file.

local BUILD = { name = 'ST6IX HAT-TRICK V1.0 HDR', hdr = true }
local VERSION = 5.00

-- ============================================================================
-- ENGINE ROUTING
-- ============================================================================

-- Engine choice per area, refreshed every frame from the Engines page.
-- 1 = V1.2 engine, 2 = V1.5 engine; exposure 3 = Pure native; tone is the
-- 1-based Tone Curve index (1-3 V1.2 curves, 4-9 V1.5 curves).
local E = { lighting = 1, sky = 1, fog = 1, reflections = 1, bloom = 2,
    exposure = 2, color = 1, tone = 6, sunblindManual = true }
-- Areas this build fixes to one engine (none in the full build).
local FIXED_ENGINES = {}
-- Values of controls this build does not show, read in place of the UI.
local FIXED_VALUES = {}

-- Values both engines contribute to are captured here and written once,
-- combined, at the end of the frame.
local OUT12, OUT15 = {}, {}
-- Scene signals one engine computes and the other or the final pass reuses.
local SIGNALS = { highlight = 0, darkness = 0, fog = 0, recovery = 0, daySky = 1, v15SkyLevel = 1 }

local TONE_CURVES = 'AgX,Uchimura,Lottes,Neon Noir,ST6IX Dusk,Hyperchrome,Retrograde,BABAYAGA,ST6IX Lottes'
local DEFAULT_TONE = 6

local function ownerOf(block, area)
    if area == 'always' then return true end
    if area == 'tone' then
        if BUILD.hdr then return false end
        if block == 12 then return E.tone <= 3 end
        return E.tone >= 4
    end
    if area == 'sunblind' then
        if block == 12 then return not E.sunblindManual end
        return E.sunblindManual
    end
    local engine = E[area]
    if block == 12 then return engine == 1 end
    if area == 'exposure' then return engine >= 2 end
    return engine == 2
end

-- Pure config keys by area. Unlisted keys are always allowed.
local CONFIG_AREA_PREFIX = {
    { 'light.sky.', 'sky' }, { 'clouds2D.', 'sky' }, { 'clouds_raymarching.', 'sky' },
    { 'sun.sun_moon_size', 'sky' }, { 'sun.size', 'sky' },
    { 'light.', 'lighting' }, { 'csp_lights.', 'lighting' }, { 'nlp.', 'lighting' },
    { 'moon.', 'lighting' }, { 'stars.', 'lighting' },
    { 'fog.', 'fog' }, { 'shaders.groundfog.', 'fog' },
    { 'reflections.', 'reflections' }, { 'vao.', 'reflections' },
    { 'ppTonemap', 'tone' },
}
local SUNBLIND_SHARED = { ['shaders.sunblinding.blinding'] = true, ['shaders.sunblinding.iris'] = true,
    ['shaders.sunblinding.star_opacity'] = true, ['shaders.sunblinding.cover'] = true }
-- Captured instead of written: both engines contribute to these.
local COMPOSED_CONFIG = { ['pp.saturation'] = true, ['pp.contrast'] = true, ['light.sun.saturation'] = true,
    ['light.sky.level'] = true }
local COMPOSED_YEBIS = { vignetteStrength = true, lensDistortionEnabled = true,
    lensDistortionRoundness = true, lensDistortionSmoothness = true }

local function configArea(key)
    if SUNBLIND_SHARED[key] then return 'sunblind' end
    for _, entry in ipairs(CONFIG_AREA_PREFIX) do
        if key:sub(1, #entry[1]) == entry[1] then return entry[2] end
    end
    return 'always'
end

local function yebisArea(key)
    if key == 'glareQuality' then return 'always' end
    if key:sub(1, 5) == 'glare' then return 'bloom' end
    if key == 'colorTemperature' or key == 'whiteBalance' or key == 'hue' then return 'color' end
    return 'always'
end

local AC_AREA = {
    setFogDistance = 'fog', setFogBlend = 'fog', setFogDensity = 'fog', setFogExponent = 'fog',
    setFogHeight = 'fog', setFogColor = 'fog', setFogBacklitMultiplier = 'fog',
    setHorizonFogMultiplier = 'fog',
    setPpTonemapGamma = 'tone',
    setGlareBloomFilterThreshold = 'bloom', setGlareStarFilterThreshold = 'bloom',
    setFresnelGamma = 'reflections',
    setSkyStarsBrightness = 'lighting', setSkyStarsSaturation = 'lighting', setSkyStarsExponent = 'lighting',
}
local LIGHT_AREA = { setSpectrumAdaption = 'lighting', setLambertGamma = 'lighting',
    adaptLambertGamma = 'lighting', setVAOAdaption = 'reflections' }

-- Wraps every set* function of a table (and nested tables) so it only runs
-- while `block` owns `area`.
local function gatedSetters(block, area, target)
    if type(target) ~= 'table' then return target end
    local cache = {}
    return setmetatable({}, { __index = function(_, k)
        local cached = cache[k]
        if cached ~= nil then return cached end
        local v = target[k]
        local out = v
        if type(v) == 'function' and type(k) == 'string' and k:sub(1, 3) == 'set' then
            out = function(...) if ownerOf(block, area) then return v(...) end end
        elseif type(v) == 'table' then
            out = gatedSetters(block, area, v)
        end
        cache[k] = out
        return out
    end })
end

local function mapped(target, areas, block)
    if type(target) ~= 'table' then return target end
    local cache = {}
    return setmetatable({}, { __index = function(_, k)
        local cached = cache[k]
        if cached ~= nil then return cached end
        local v = target[k]
        local area = areas[k]
        local out = v
        if area and type(v) == 'function' then
            out = function(...) if ownerOf(block, area) then return v(...) end end
        end
        cache[k] = out
        return out
    end })
end

-- Builds the gated view of `pure` and `ac` one engine block works with.
-- Pure namespaces are looked up on first use, not at load time.
local function makeGatedApi(block, out, uiGetValue)
    local builders = {
        config = function(real)
            return setmetatable({
                set = function(key, value, rel)
                    if COMPOSED_CONFIG[key] then out['config:' .. key] = value; return end
                    if ownerOf(block, configArea(key)) then return real.set(key, value, rel) end
                end,
            }, { __index = real })
        end,
        yebis = function(real)
            return setmetatable({
                set = function(key, value, ...)
                    if COMPOSED_YEBIS[key] then out['yebis:' .. key] = value; return end
                    if ownerOf(block, yebisArea(key)) then return real.set(key, value, ...) end
                end,
            }, { __index = real })
        end,
        exposure = function(real) return gatedSetters(block, 'exposure', real) end,
        pp = function(real)
            return setmetatable({
                setTonemapping = function(...) if ownerOf(block, 'tone') then return real.setTonemapping(...) end end,
                setCustomRGBTonemapping = function(...)
                    if ownerOf(block, 'tone') then return real.setCustomRGBTonemapping(...) end
                end,
            }, { __index = real })
        end,
        stellar = function(real) return gatedSetters(block, 'lighting', real) end,
        light = function(real) return mapped(real, LIGHT_AREA, block) end,
        camera = function(real)
            return setmetatable({
                setCPL = function(...) if ownerOf(block, 'reflections') then return real.setCPL(...) end end,
            }, { __index = real })
        end,
    }
    if uiGetValue then
        builders.script = function(real)
            local ui = setmetatable({ getValue = uiGetValue }, { __index = function(_, k)
                local realUi = real.ui
                return realUi and realUi[k]
            end })
            return setmetatable({ ui = ui }, { __index = real })
        end
    end
    local P = setmetatable({}, { __index = function(t, k)
        local real = pure[k]
        local build = builders[k]
        if build == nil or type(real) ~= 'table' then return real end
        local wrapped = build(real)
        rawset(t, k, wrapped)
        return wrapped
    end })
    local A = mapped(ac, AC_AREA, block)
    return P, A
end

local function clampValue(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end

local function uiNumber(name, fallback, lo, hi)
    local x = pure.script.ui.getValue(name)
    if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then x = fallback end
    return clampValue(x, lo, hi)
end

local function uiChoice(name, default, count)
    return math.floor(uiNumber(name, default, 1, count) + 0.5)
end

local function uiCheck(name, fallback)
    local x = pure.script.ui.getValue(name)
    if type(x) ~= 'boolean' then return fallback end
    return x
end

-- Scene-aware HDR strength (HDR build only; 0 in SDR).
local function hdrStrength()
    if not BUILD.hdr then return 0 end
    return uiCheck('Scene Aware HDR', true) and uiNumber('HDR Adaptation Strength', 0.45, 0, 1) or 0
end

-- Exposure trim in stops shared by every exposure engine: the HDR response
-- (HDR build) plus highlight recovery from the HDR & Clarity page.
local function sceneEV()
    local ev = -SIGNALS.highlight * SIGNALS.recovery * 0.6
    if BUILD.hdr then
        local strength = hdrStrength()
        ev = ev + uiNumber('HDR Brightness', 0, -1.5, 1.5)
            - SIGNALS.highlight * uiNumber('HDR Highlight Protection', 0.55, 0, 1) * strength * 0.50
            + SIGNALS.darkness * uiNumber('HDR Shadow Lift', 0.35, 0, 1) * strength * 0.35
    end
    return ev
end

-- V1.5 was written for 0-based radio values; Pure delivers 1-based ones.
-- The V1.5 engine reads its radios through this translator.
local V15_RADIOS = {
    st6ix_profile = 1, lighting_preset = 7, night_preset = 1, reflections_preset = 7,
    sky_preset = 4, ['FOG Type'] = 3, ini_eye_preset_v2 = 1, hdr_clarity_preset = 2,
    ['Skydome Preset'] = 1, ['Tunnel Blinding Presets'] = 2,
}
-- SDR-only V1.5 tone inputs the HDR build does not show; their defaults keep
-- the shared code paths well defined.
local HDR_FIXED_V15 = { photo_realistic = 0.9, sun_blinding = 0.5 }
local function v15GetValue(name)
    local default = V15_RADIOS[name]
    if default then
        local x = FIXED_VALUES[name]
        if x == nil then x = pure.script.ui.getValue(name) end
        if type(x) ~= 'number' or x ~= x then x = default end
        return math.floor(x + 0.5) - 1
    end
    if name == 'Tonemapping' then return E.tone end
    if BUILD.hdr and HDR_FIXED_V15[name] ~= nil then return HDR_FIXED_V15[name] end
    if name == 'exposure_mode' then return E.exposure == 2 and 1 or 0 end
    local fixedValue = FIXED_VALUES[name]
    if fixedValue ~= nil then return fixedValue end
    return pure.script.ui.getValue(name)
end

local function v12GetValue(name)
    local fixedValue = FIXED_VALUES[name]
    if fixedValue ~= nil then return fixedValue end
    return pure.script.ui.getValue(name)
end

local blockErrors = {}
local function runBlock(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local text = tostring(err)
        if blockErrors[label] ~= text then
            blockErrors[label] = text
            pcall(ac.log, 'ST6IX HAT-TRICK ' .. label .. ': ' .. text)
        end
    else
        blockErrors[label] = nil
    end
    return ok
end

-- ============================================================================
-- ENGINE 1: ST6IX V1.2 (Gamma V1.8 photographic engine)
-- ============================================================================
local V12 = {}
do
local pure, ac = makeGatedApi(12, OUT12, v12GetValue)

-- Neutral YEBIS white point. The scene temperature is expressed against it,
-- so the Kelvin sliders shift the image instead of cancelling themselves out.
local NEUTRAL_WHITE_POINT = 6500
local smoothState = {}
local lastStarOutput = nil
local lastStarBase = nil
local dofWasEnabled = nil
local lockedExposure = nil
local lastLock = false
local lockedWhiteBalance = nil
local lastWhiteBalanceLock = false
local tunnelWasDark = false
local tunnelFlash = 0
local starOutput = { brightness=0, saturation=0.9, exponent=1.0 }

-- Pure can update stellar rendering after update_pure_script(). Apply the
-- chosen output once more at the final post-processing stage so the controls
-- remain authoritative on current CSP/Pure builds.
local function applyStarOutputLate()
    if type(ac.setSkyStarsBrightness) == 'function' then
        ac.setSkyStarsBrightness(starOutput.brightness)
    end
    if type(ac.setSkyStarsSaturation) == 'function' then
        ac.setSkyStarsSaturation(starOutput.saturation)
    end
    if type(ac.setSkyStarsExponent) == 'function' then
        ac.setSkyStarsExponent(starOutput.exponent)
    end
end

if type(ac.onPostProcessing) == 'function' then
    ac.onPostProcessing(applyStarOutputLate)
end

-- Minimal AgX implementation for Pure's documented custom RGB tonemapper hook.
local agxTonemap = {
    values = { exposure=1.0, slope=1.0, power=1.0, saturation=1.0 },
    shader = [[
    #define ST6IX_LUMA float3(0.2126, 0.7152, 0.0722)

    float3 st6ixAgxContrast(float3 x) {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        return 15.5*x4*x2 - 40.14*x4*x + 31.96*x4
             - 6.868*x2*x + 0.4298*x2 + 0.1191*x - 0.00232;
    }

    float3 st6ixAgx(float3 value) {
        const float3x3 inputMatrix = float3x3(
            0.8424790623, 0.0423282423, 0.0423756549,
            0.0784336000, 0.8784686365, 0.0784336000,
            0.0792237451, 0.0791661275, 0.8791429738);
        const float3x3 outputMatrix = float3x3(
            1.1968790051, -0.0528968518, -0.0529716355,
           -0.0980208811,  1.1519031299, -0.0980434501,
           -0.0990297441, -0.0989611768,  1.1510736726);
        value = max(mul(inputMatrix, value), float3(1e-6, 1e-6, 1e-6));
        value = (clamp(log2(value), -12.47393, 4.026069) + 12.47393) / 16.5;
        value = st6ixAgxContrast(value);
        float luma = dot(value, ST6IX_LUMA);
        value = pow(max(value * slope, 0), power);
        value = luma + saturation * (value - luma);
        return max(mul(outputMatrix, value), 0);
    }

    float3 tonemapping(float3 color) {
        return st6ixAgx(max(color * exposure, 0));
    }
]]
}

local profiles = {
    [1] = { light=1.00, contrast=0.99, bloom=0.86, glare=0.82,
            reflection=0.96, vignette=0.60 },
    [2] = { light=1.03, contrast=1.03, bloom=1.00, glare=1.00,
            reflection=1.04, vignette=1.00 },
    [3] = { light=1.00, contrast=1.00, bloom=1.00, glare=1.00,
            reflection=1.00, vignette=1.00 },
}

-- Presets are restrained multipliers layered over the user's page sliders.
-- The fifth morning/night entry and fourth reflection entry are neutral Custom modes;
-- the Natural/Normal entries carry a gentle character so they differ from Custom.
local MORNING_PRESETS = {
    [1] = {daylight=1.00, sun=1.00, ambient=1.03, sky=1.02, advanced=1.02,
            saturation=1.00, contrast=1.00, temperature=-60, bounce=1.01, emissive=1.00},
    [2] = {daylight=1.08, sun=1.02, ambient=1.05, sky=1.06, advanced=1.05,
            saturation=1.01, contrast=0.99, temperature=-150, bounce=1.02, emissive=1.02},
    [3] = {daylight=0.88, sun=0.90, ambient=0.90, sky=0.92, advanced=0.92,
            saturation=0.96, contrast=1.02, temperature=-300, bounce=0.96, emissive=1.05},
    [4] = {daylight=0.94, sun=0.92, ambient=0.96, sky=0.97, advanced=0.95,
            saturation=0.95, contrast=1.04, temperature=-450, bounce=1.00, emissive=1.08},
    [5] = {daylight=1.00, sun=1.00, ambient=1.00, sky=1.00, advanced=1.00,
            saturation=1.00, contrast=1.00, temperature=0, bounce=1.00, emissive=1.00},
}

local NIGHT_PRESETS = {
    [1] = {nlp=1.00, density=1.00, ambient=1.04, moon=1.05, moonAppearance=1.02,
            stars=1.00, starBrightness=1.02, starSaturation=1.00, starExponent=1.00,
            saturation=1.00, contrast=1.00, temperature=80, bounce=1.02, emissive=1.00, exposure=0.00},
    [2] = {nlp=1.10, density=0.95, ambient=1.18, moon=1.12, moonAppearance=1.05,
            stars=0.92, starBrightness=0.92, starSaturation=0.95, starExponent=1.05,
            saturation=1.02, contrast=0.98, temperature=100, bounce=1.05, emissive=1.03, exposure=0.18},
    [3] = {nlp=0.76, density=1.05, ambient=0.78, moon=0.80, moonAppearance=0.88,
            stars=1.12, starBrightness=1.12, starSaturation=1.03, starExponent=0.95,
            saturation=0.96, contrast=1.03, temperature=-150, bounce=0.95, emissive=0.98, exposure=-0.16},
    [4] = {nlp=0.88, density=1.08, ambient=0.86, moon=1.08, moonAppearance=1.10,
            stars=1.04, starBrightness=1.04, starSaturation=1.06, starExponent=0.96,
            saturation=0.97, contrast=1.05, temperature=-300, bounce=1.02, emissive=1.08, exposure=-0.04},
    [5] = {nlp=1.00, density=1.00, ambient=1.00, moon=1.00, moonAppearance=1.00,
            stars=1.00, starBrightness=1.00, starSaturation=1.00, starExponent=1.00,
            saturation=1.00, contrast=1.00, temperature=0, bounce=1.00, emissive=1.00, exposure=0.00},
}

local REFLECTION_PRESETS = {
    [1] = {level=1.03, saturation=0.99, emissive=1.10, vao=1.02,
            trackExponent=1.00, dynamicExponent=1.01, weatherVAO=1.05},
    [2] = {level=1.22, saturation=1.06, emissive=3.20, vao=1.08,
            trackExponent=1.03, dynamicExponent=1.02, weatherVAO=1.18},
    [3] = {level=1.35, saturation=1.10, emissive=5.00, vao=1.12,
            trackExponent=1.07, dynamicExponent=1.05, weatherVAO=1.28},
    [4] = {level=1.00, saturation=1.00, emissive=1.00, vao=1.00,
            trackExponent=1.00, dynamicExponent=1.00, weatherVAO=1.00},
}

-- Glare styles are restrained multipliers over the existing glare controls.
-- Custom is deliberately neutral so every value remains fully manual.
local GLARE_STYLES = {
    [1] = {bloom=0.72, radius=0.82, threshold=1.10, star=0.55, length=0.70, softness=1.12, streaks=4, ghost=0.00},
    [2] = {bloom=0.88, radius=0.88, threshold=1.02, star=0.82, length=0.92, softness=0.94, streaks=4, ghost=0.00},
    [3] = {bloom=1.00, radius=1.10, threshold=0.96, star=0.78, length=1.12, softness=1.10, streaks=6, ghost=0.02},
    [4] = {bloom=0.92, radius=0.94, threshold=1.00, star=1.08, length=1.34, softness=0.90, streaks=6, ghost=0.01},
    [5] = {bloom=1.04, radius=1.18, threshold=0.94, star=0.92, length=1.08, softness=1.14, streaks=6, ghost=0.08},
    [6] = {bloom=1.12, radius=1.22, threshold=0.90, star=0.92, length=1.12, softness=1.08, streaks=6, ghost=0.03},
    [7] = {bloom=0.92, radius=1.08, threshold=0.98, star=0.70, length=0.92, softness=1.18, streaks=4, ghost=0.02},
    [8] = {bloom=1.00, radius=1.00, threshold=1.00, star=1.00, length=1.00, softness=1.00, streaks=4, ghost=0.00},
}

-- Sky presets stay close to Pure's neutral result and are blended with the
-- time-specific controls below. Custom is a neutral pass-through preset.
local SKY_PRESETS = {
    [1] = {sky=1.00, saturation=1.03, clouds=1.00, contrast=1.03, softness=1.00, celestial=1.00},
    [2] = {sky=1.08, saturation=1.10, clouds=0.96, contrast=1.06, softness=1.04, celestial=1.10},
    [3] = {sky=0.90, saturation=0.78, clouds=1.18, contrast=0.72, softness=1.22, celestial=0.96},
    [4] = {sky=1.02, saturation=1.06, clouds=0.91, contrast=0.84, softness=1.16, celestial=1.04},
    [5] = {sky=0.86, saturation=0.72, clouds=1.08, contrast=0.78, softness=1.12, celestial=1.00},
    [6] = {sky=0.72, saturation=0.68, clouds=0.62, contrast=1.28, softness=0.82, celestial=1.00},
    [7] = {sky=1.00, saturation=1.00, clouds=1.00, contrast=1.00, softness=1.00, celestial=1.00},
}

-- YEBIS glare sampling quality. Higher levels only refine bloom and star
-- sampling; the look itself stays with the Bloom and Glare pages.
local RENDER_QUALITY = { [1] = 2, [2] = 3, [3] = 4, [4] = 5 }

local function clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end

local function number(name, fallback, lo, hi)
    local x = pure.script.ui.getValue(name)
    if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then
        x = fallback
    end
    return clamp(x, lo, hi)
end

local function check(name, fallback)
    local x = pure.script.ui.getValue(name)
    if type(x) ~= 'boolean' then return fallback end
    return x
end

local function smooth(key, target, dt, seconds)
    local previous = smoothState[key]
    if previous == nil then previous = target end
    local alpha = 1 - math.exp(-clamp(dt, 0, 0.25) / seconds)
    local result = previous + (target - previous) * alpha
    smoothState[key] = result
    return result
end

local function finite(value, fallback)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
        return fallback
    end
    return value
end

-- Sensor reads tolerate Pure/CSP builds that lack a getter, so one missing
-- function cannot stop the whole filter.
local function read(fn, fallback)
    if type(fn) ~= 'function' then return fallback end
    local ok, value = pcall(fn)
    if not ok then return fallback end
    return finite(value, fallback)
end

local function call(fn, ...)
    if type(fn) == 'function' then pcall(fn, ...) end
end

local function yebisTry(key, value)
    pcall(pure.yebis.set, key, value)
end

local function configTry(key, value)
    pcall(pure.config.set, key, value, true)
end

local function angleDelta(a, b)
    return math.abs((a - b + 180) % 360 - 180)
end

-- A camera-like meter ignores tiny changes, then moves decisively once the
-- scene has changed enough. This avoids constant target shimmer in replays.
local function cameraTargetResponse(target, dt, enabled, memoryKey)
    local suffix = memoryKey or 'shared'
    if not enabled then return smooth('adaptiveTarget_'..suffix, target, dt, 0.55) end
    local stateKey = 'cameraTarget_'..suffix
    local previous = smoothState[stateKey]
    if previous == nil then previous = target end
    local difference = target - previous
    if math.abs(difference) < 0.035 then
        target = previous
    end
    local seconds = difference < 0 and 0.20 or 0.38
    local alpha = 1 - math.exp(-clamp(dt, 0, 0.25) / seconds)
    local result = previous + (target - previous) * alpha
    smoothState[stateKey] = result
    return result
end

local function mixColor(a, b, t)
    return rgb(
        math.lerp(finite(a and a.r, b.r), b.r, t),
        math.lerp(finite(a and a.g, b.g), b.g, t),
        math.lerp(finite(a and a.b, b.b), b.b, t))
end

local function relative(key, value)
    pure.config.set(key, value, true)
end

local function slider(name, default, minimum, maximum, tooltip)
    pure.script.ui.addSliderFloat(name, default, minimum, maximum, tooltip)
end

local function sliderInt(name, default, minimum, maximum, tooltip)
    pure.script.ui.addSliderInteger(name, default, minimum, maximum, tooltip)
end

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

V12.update = function(dt)
    if type(dt) ~= 'number' or dt ~= dt then dt = 0 end
    dt = clamp(dt, 0, 0.25)

    local mode = math.floor(number('Overall Mode', 2, 1, 3))
    local profile = profiles[mode] or profiles[2]
    local diagnosticsEnabled = check('Diagnostics Enabled', false)
    local effectPreview = math.floor(number('Effect Preview',1,1,5))
    local effectPreviewStrength = diagnosticsEnabled
        and number('Effect Preview Strength',0.5,0,1) or 0
    local day = smooth('day', clamp(pure.mod.sun(0), 0, 1), dt, 0.60)
    local night = 1 - day
    local cockpit = smooth('cockpit', ac.isInteriorView() and 1 or 0, dt, 0.35)

    local morningPresetIndex = math.floor(number('Morning Preset',1,1,5))
    local morningPreset = MORNING_PRESETS[morningPresetIndex] or MORNING_PRESETS[1]
    -- Keep the chosen morning look active for the full daylight period. The
    -- outer day/night blends below already fade it naturally at dawn and dusk.
    local morningMix = number('Morning Preset Strength',1,0,1)
    local nightPresetIndex = math.floor(number('Night Preset',1,1,5))
    local nightPreset = NIGHT_PRESETS[nightPresetIndex] or NIGHT_PRESETS[1]
    local reflectionPresetIndex = math.floor(number('Reflection Preset',1,1,4))
    local reflectionPreset = REFLECTION_PRESETS[reflectionPresetIndex] or REFLECTION_PRESETS[1]

    -- Shared scene measurements. Every automatic system below uses the same
    -- smoothed signals so exposure, glare and reflections move together.
    local fov = clamp(read(pure.camera.getFOV, 50), 10, 140)
    local cameraOcclusion = smooth('cameraOcclusion',
        clamp(read(pure.camera.getOcclusion, 1), 0, 1), dt, 0.45)
    local overcast = smooth('overcast', clamp(read(pure.world.getOvercast, 0), 0, 1), dt, 1.0)
    local cloudCoverage = smooth('cloudCoverage',
        clamp(read(pure.world.getCloudCoverage, 0), 0, 1), dt, 1.0)
    local badness = smooth('badness', clamp(read(pure.world.getBadness, 0), 0, 1), dt, 1.0)
    local worldFog = smooth('worldFog', clamp(read(pure.world.getFog, 0), 0, 1), dt, 1.0)
    local humidity = smooth('humidity', clamp(read(pure.world.getHumidity, 0), 0, 1), dt, 1.5)
    local mist = smooth('mist', clamp(read(pure.world.getMist, 0), 0, 1), dt, 1.5)
    local smog = smooth('smog', clamp(read(pure.world.getSmog, 0), 0, 1), dt, 1.5)
    local cloudShadow = smooth('cloudShadow', clamp(read(pure.world.getCloudShadow, 0), 0, 1), dt, 0.8)
    local rainIntensity = smooth('rainIntensity',
        clamp(read(pure.world.getRainFX_Intensity, 0), 0, 1), dt, 1.0)
    local wetness = smooth('wetness', clamp(read(pure.world.getRainFX_Wetness, 0), 0, 1), dt, 1.2)
    local standingWater = smooth('standingWater',
        clamp(read(pure.world.getRainFX_Water, 0), 0, 1), dt, 1.2)
    local wetSurface = math.max(wetness, standingWater)
    local weatherSeverity = math.max(overcast, cloudCoverage * 0.85, badness,
        worldFog * 0.85, rainIntensity * 0.90)

    -- A tunnel exit is detected with hysteresis so trees, bridges and camera
    -- cuts do not repeatedly fire the effect. Normal is a true neutral preset.
    local tunnelPreset = math.floor(number('Tunnel Preset',1,1,4))
    local tunnelInterior = clamp((0.62 - cameraOcclusion) / 0.42, 0, 1) * day
    if cameraOcclusion < 0.38 and day > 0.15 then
        tunnelWasDark = true
    elseif tunnelWasDark and cameraOcclusion > 0.68 then
        tunnelFlash = tunnelPreset == 1 and 0 or 1
        tunnelWasDark = false
    end
    if tunnelPreset == 1 then
        tunnelFlash = 0
    elseif tunnelFlash > 0 then
        local tunnelRecovery = number('Tunnel Recovery Speed',1,0.5,2)
        local tunnelDecay = (tunnelPreset == 3 and 1.15
            or (tunnelPreset == 4 and 1.65 or 0.32)) / tunnelRecovery
        tunnelFlash = tunnelFlash * math.exp(-dt / tunnelDecay)
        if tunnelFlash < 0.001 then tunnelFlash = 0 end
    end
    local tunnelInteriorLift = 0
    local tunnelOpeningProtection = 0
    if tunnelPreset > 1 then
        local presetLift = tunnelPreset == 3 and 1.00 or (tunnelPreset == 4 and 0.75 or 0.65)
        tunnelInteriorLift = tunnelInterior * number('Tunnel Interior Lift',0.18,0,0.6) * presetLift
        tunnelOpeningProtection = tunnelInterior * cameraOcclusion
            * number('Tunnel Opening Protection',0.20,0,0.6)
    end
    local exitEV = tunnelPreset == 3 and 1.10 or (tunnelPreset == 4 and 0.24 or 0.38)
    local exitGlare = tunnelPreset == 3 and 0.85 or (tunnelPreset == 4 and 0.18 or 0.25)
    local tunnelEVBoost = tunnelFlash * exitEV * day + tunnelInteriorLift - tunnelOpeningProtection
    local tunnelGlareBoost = tunnelFlash * exitGlare * day

    local cbeAverage = 1
    local cbeMaximum = 1
    if type(ac.getCubemapBrightnessEstimationAverage) == 'function' then
        cbeAverage = math.max(0.001, finite(ac.getCubemapBrightnessEstimationAverage(), 1))
    end
    if type(ac.getCubemapBrightnessEstimationMaximum) == 'function' then
        cbeMaximum = math.max(cbeAverage, finite(ac.getCubemapBrightnessEstimationMaximum(), cbeAverage))
    end
    local highlightSignal = smooth('highlightSignal',
        clamp((cbeMaximum - cbeAverage) / math.max(cbeAverage, 0.001) / 2.5, 0, 1), dt, 0.35)
    SIGNALS.highlight = highlightSignal

    local sunHeading = read(pure.stellar.getSunHeading, 0)
    local sunElevation = read(pure.stellar.getSunElevation, 0)
    local moonElevation = read(pure.stellar.getMoonElevation, -20)
    -- Bell-shaped twilight weight: strongest while the sun crosses the horizon,
    -- fading into the separate daylight and nighttime values on either side.
    local twilight = smooth('twilight',
        1 - clamp(math.abs(sunElevation + 3) / 12, 0, 1), dt, 0.80)
    local cameraHeading = read(pure.camera.getHeading, 180)
    local cameraElevation = read(pure.camera.getElevation, 0)
    local horizontalFacing = 1 - clamp(angleDelta(cameraHeading, sunHeading) / math.max(fov * 0.75, 18), 0, 1)
    local verticalFacing = 1 - clamp(math.abs(cameraElevation - sunElevation) / math.max(fov * 0.55, 12), 0, 1)
    local sunFacing = smooth('sunFacing', horizontalFacing * verticalFacing * day, dt, 0.25)

    -- Metering modes alter only the documented CBE analysis window and target
    -- bias. They share all limits and protection logic below.
    local metering = math.floor(number('Exposure Metering',1,1,4))
    local analysisZoom = clamp((50 - fov) / 100, -0.45, 0.30)
    local analysisExponent = 0.25
    local analysisMultiplier = 1.50
    if metering == 2 then
        analysisZoom = clamp(analysisZoom + 0.16, -0.25, 0.45)
        analysisExponent = 0.32
        analysisMultiplier = 1.62
    elseif metering == 3 then
        analysisZoom = clamp(analysisZoom + cockpit * 0.20, -0.30, 0.45)
        analysisExponent = 0.30
        analysisMultiplier = 1.58
    elseif metering == 4 then
        analysisZoom = clamp(analysisZoom + 0.24, -0.20, 0.50)
        analysisExponent = 0.38
        analysisMultiplier = 1.35
    end
    pure.exposure.cbe.setAnalysis(analysisZoom, analysisExponent, analysisMultiplier)

    local adaptiveExposure = check('Adaptive Scene Exposure', true)
    local adaptationStrength = number('Adaptation Strength',0.35,0,1)
    local highlightProtection = number('Highlight Protection',0.25,0,1)
    local interiorBias = number('Interior Metering Bias',0.18,-0.5,0.75)
    local maximumTargetShift = number('Maximum Target Shift',0.18,0,0.5)
    local cameraStyleResponse = check('Camera Style Response', false)
    local darknessSignal = clamp((1 - cameraOcclusion) * 0.50
        + badness * 0.18 + worldFog * 0.12 + overcast * 0.08, 0, 1)
    SIGNALS.darkness = darknessSignal
    SIGNALS.fog = math.max(worldFog, mist)
    local requestedTargetShift = 0
    if adaptiveExposure then
        local meteringBias = metering == 2 and -highlightSignal * 0.10
            or (metering == 3 and cockpit * interiorBias * 0.35)
            or (metering == 4 and -highlightSignal * 0.18 or 0)
        requestedTargetShift = clamp(darknessSignal * 0.55 + cockpit * interiorBias + meteringBias
            - highlightSignal * highlightProtection, -1, 1)
            * maximumTargetShift * adaptationStrength
    end
    local cameraMemory = check('Per Camera Exposure Memory', true)
    local memoryKey = cameraMemory and (cockpit > 0.5 and 'cockpit' or 'exterior') or 'shared'
    if metering == 4 then memoryKey = 'photography' end
    local sceneTargetShift = cameraTargetResponse(requestedTargetShift, dt, cameraStyleResponse, memoryKey)

    local minExposure = number('Minimum Exposure',0.015,0.005,0.15)
    local maxExposure = math.max(minExposure + 0.001, number('Maximum Exposure',0.7,0.15,1.5))
    local calculatedExposure = read(pure.exposure.getCalculatedValue,
        read(pure.exposure.getValue, minExposure))
    local exposureRange = math.max(maxExposure - minExposure, 0.001)
    local exposureLevel = clamp((calculatedExposure - minExposure) / exposureRange, 0, 1)

    local daylight = number('Daylight Multiplier',1.15,0.60,1.80) * profile.light
        * math.lerp(1, morningPreset.daylight, morningMix)
    relative('light.daylight_multiplier', math.lerp(1, daylight, day))
    relative('light.sun.level', math.lerp(1, number('Day Sun Level',0.95,0.5,1.5)
        * math.lerp(1, morningPreset.sun, morningMix), day))
    relative('light.sun.saturation', math.lerp(1, number('Day Sun Saturation',1,0.7,1.3), day))
    relative('light.sun.speculars', math.lerp(1, number('Day Sun Speculars',1,0.5,1.5), day))
    relative('light.ambient.level', math.lerp(1, number('Day Ambient Level',1.02,0.6,1.5)
        * math.lerp(1, morningPreset.ambient, morningMix), day))
    local skyPresetIndex = math.floor(number('Sky Preset',1,1,7))
    local skyPreset = SKY_PRESETS[skyPresetIndex] or SKY_PRESETS[1]
    local skyPresetStrength = number('Sky Preset Strength',0.85,0,1)
    if skyPresetIndex == 7 then skyPresetStrength = 0 end
    local skyWeatherResponse = number('Sky Weather Response',0.55,0,1)
    local skyTransitionSeconds = 0.90 / number('Sky Transition Speed',1,0.25,3)
    local twilightWeight = clamp(twilight, 0, 1)
    local dayWeight = day * (1 - twilightWeight)
    local nightWeight = night * (1 - twilightWeight)
    local timeWeightTotal = math.max(dayWeight + twilightWeight + nightWeight, 0.001)
    dayWeight = dayWeight / timeWeightTotal
    twilightWeight = twilightWeight / timeWeightTotal
    nightWeight = nightWeight / timeWeightTotal

    local timeSkyBrightness = number('Day Sky Brightness',1,0.5,1.6) * dayWeight
        + number('Twilight Sky Brightness',1,0.5,1.6) * twilightWeight
        + number('Night Sky Brightness',1,0.4,1.6) * nightWeight
    local timeSkySaturation = number('Day Sky Saturation',1,0.5,1.4) * dayWeight
        + number('Twilight Sky Saturation',1,0.5,1.4) * twilightWeight
        + number('Night Sky Saturation',1,0.4,1.4) * nightWeight
    local baseDaySky = math.lerp(1, number('Day Sky Level',1.02,0.6,1.5)
        * math.lerp(1, morningPreset.sky, morningMix), day)
    SIGNALS.daySky = baseDaySky
    local weatherSky = 1 - skyWeatherResponse
        * clamp(weatherSeverity * 0.10 + worldFog * 0.08 + rainIntensity * 0.05, 0, 0.18)
    local skyLevelTarget = baseDaySky * timeSkyBrightness
        * math.lerp(1, skyPreset.sky, skyPresetStrength) * weatherSky
    local skySaturationTarget = timeSkySaturation
        * math.lerp(1, skyPreset.saturation, skyPresetStrength)
        * (1 - skyWeatherResponse * clamp(worldFog * 0.14 + rainIntensity * 0.08, 0, 0.18))
    relative('light.sky.level', smooth('skyLevel', clamp(skyLevelTarget, 0.35, 1.80), dt, skyTransitionSeconds))
    relative('light.sky.saturation', smooth('skySaturation', clamp(skySaturationTarget, 0.40, 1.50), dt, skyTransitionSeconds))

    local timeCloudBrightness = number('Day Cloud Brightness',1,0.4,1.8) * dayWeight
        + number('Twilight Cloud Brightness',1,0.4,1.8) * twilightWeight
        + number('Night Cloud Brightness',1,0.4,1.8) * nightWeight
    local timeCloudContrast = number('Day Cloud Contrast',1,0.5,1.6) * dayWeight
        + number('Twilight Cloud Contrast',1,0.5,1.6) * twilightWeight
        + number('Night Cloud Contrast',1,0.5,1.6) * nightWeight
    local timeCloudSoftness = number('Day Cloud Softness',1,0.5,1.5) * dayWeight
        + number('Twilight Cloud Softness',1,0.5,1.5) * twilightWeight
        + number('Night Cloud Softness',1,0.5,1.5) * nightWeight
    local cloudBrightnessTarget = timeCloudBrightness
        * math.lerp(1, skyPreset.clouds, skyPresetStrength)
        * (1 - skyWeatherResponse * weatherSeverity * 0.10)
    local cloudContrastTarget = timeCloudContrast
        * math.lerp(1, skyPreset.contrast, skyPresetStrength)
        * (1 + skyWeatherResponse * weatherSeverity * 0.12)
    local cloudSoftnessTarget = timeCloudSoftness
        * math.lerp(1, skyPreset.softness, skyPresetStrength)
        * (1 + skyWeatherResponse * mist * 0.10 - skyWeatherResponse * badness * 0.08)
    relative('clouds2D.brightness', smooth('cloudBrightness', clamp(cloudBrightnessTarget, 0.30, 2.00), dt, skyTransitionSeconds))
    relative('clouds2D.contrast', smooth('cloudContrast', clamp(cloudContrastTarget, 0.45, 1.80), dt, skyTransitionSeconds))
    relative('clouds_raymarching.softness', smooth('cloudSoftness', clamp(cloudSoftnessTarget, 0.45, 1.60), dt, skyTransitionSeconds))

    local celestialSize = math.lerp(number('Moon Apparent Size',1,0.5,1.6),
        number('Sun Apparent Size',1,0.5,1.6), day)
        * math.lerp(1, skyPreset.celestial, skyPresetStrength)
    relative('sun.sun_moon_size', smooth('celestialSize', clamp(celestialSize, 0.50, 1.70), dt, skyTransitionSeconds))
    relative('light.advanced_ambient_light', math.lerp(1, number('Day Advanced Ambient',1.02,0.5,1.6)
        * math.lerp(1, morningPreset.advanced, morningMix), day))
    -- Under cloud cover the sky dome dims and the cloud layer becomes the main
    -- ambient source; the balance slider controls how far that shift goes.
    do
        local ambientBalance = number('Weather Ambient Balance',0.5,0,1)
        configTry('light.advanced_ambient_lightV2_sun', number('Ambient V2 Sun',1,0.5,1.6)
            * (1 - ambientBalance * math.max(overcast, cloudShadow) * 0.30))
        configTry('light.advanced_ambient_lightV2_sky', number('Ambient V2 Sky',1,0.5,1.6)
            * (1 - ambientBalance * cloudCoverage * 0.18))
        configTry('light.advanced_ambient_lightV2_clouds', number('Ambient V2 Clouds',1,0.5,1.6)
            * (1 + ambientBalance * cloudCoverage * 0.40))
    end
    pure.light.setSpectrumAdaption(number('Spectrum Adaptation',1,0,1.5))
    pure.light.setLambertGamma(number('Lambert Gamma',1.7,1,2.4))
    pure.light.adaptLambertGamma(true)

    relative('nlp.level', math.lerp(1, number('Night Light Pollution Level',1,0,2.5) * nightPreset.nlp, night))
    relative('nlp.density', math.lerp(1, number('Night Light Pollution Density',0.95,0,2.5) * nightPreset.density, night))
    relative('nlp.lowest_ambient', math.lerp(1, number('Night Lowest Ambient',0.9,0.2,2) * nightPreset.ambient, night))
    local adaptiveCelestial = check('Adaptive Celestial Rendering', true)
    local celestialExtinction = number('Celestial Weather Extinction',0.65,0,1)
    local moonElevationResponse = number('Moon Elevation Response',0.35,0,1)
    local celestialWeather = clamp(cloudCoverage * 0.65 + worldFog * 0.45
        + mist * 0.25 + smog * 0.20, 0, 1)
    local moonElevationFactor = math.lerp(1,
        clamp((moonElevation + 5) / 35, 0.25, 1), moonElevationResponse)
    local moonWeatherFactor = adaptiveCelestial
        and (1 - celestialWeather * celestialExtinction * 0.70) or 1
    local moonLightValue = number('Moon Light',1,0,2.5) * nightPreset.moon
        * moonElevationFactor * moonWeatherFactor
    local moonAppearanceValue = number('Moon Appearance',1,0.2,2) * nightPreset.moonAppearance
        * moonElevationFactor * moonWeatherFactor
    relative('moon.light', math.lerp(1, moonLightValue, night))
    relative('moon.appearance', math.lerp(1, moonAppearanceValue, night))
    -- Pure's live star brightness is commonly around 100 and already includes
    -- its night curve, fog attenuation and exposure adaptation. Treat the UI
    -- values as multipliers instead of replacing that output with a 0..3 value.
    local pureStarsBrightness = math.max(0, read(pure.stellar.getStarsBrightness, 100 * night))
    -- If Pure hands back the value written last frame, keep the previous base so
    -- the star multipliers cannot compound into a fade-out or blow-up.
    if lastStarOutput and lastStarBase
        and math.abs(pureStarsBrightness - lastStarOutput) <= 1e-4 * math.max(1, lastStarOutput) then
        pureStarsBrightness = lastStarBase
    end
    lastStarBase = pureStarsBrightness
    local starsAppearance = number('Stars Appearance',1,0,3) * nightPreset.stars
    local starsBrightness = number('Stars Brightness',1,0,3) * nightPreset.starBrightness
    local starsSaturation = number('Stars Saturation',0.9,0,2) * nightPreset.starSaturation
    local starsExponent = number('Stars Exponent',1,0.3,2.5) * nightPreset.starExponent
    local deepSky = number('Deep Sky Visibility',1,0,2)
    local moonStarSuppression = number('Moon Star Suppression',0.22,0,1)
    local starCelestialFactor = 1
    if adaptiveCelestial then
        local moonInfluence = clamp(moonElevationFactor * moonAppearanceValue / 2, 0, 1)
        starCelestialFactor = clamp(1 - celestialWeather * celestialExtinction * 0.72
            - moonInfluence * moonStarSuppression, 0.08, 1)
    end
    relative('stars.appearance', math.lerp(1, starsAppearance, night))
    starOutput.brightness = pureStarsBrightness * starsBrightness * deepSky * starCelestialFactor
    starOutput.saturation = starsSaturation
    starOutput.exponent = starsExponent
    lastStarOutput = starOutput.brightness
    pure.stellar.setStarsBrightness(starOutput.brightness)
    pure.stellar.setStarsSaturation(starsSaturation)
    pure.stellar.setStarsExponent(starsExponent)
    -- Also apply here for CSP builds without a late post-processing callback.
    applyStarOutputLate()

    local dayBounce = number('Day CSP Light Bounce',1,0.5,2.5) * math.lerp(1, morningPreset.bounce, morningMix)
    local nightBounce = number('Night CSP Light Bounce',1.1,0.5,2.5) * nightPreset.bounce
    local dayEmissive = number('Day CSP Light Emissive',1.35,0.5,3) * math.lerp(1, morningPreset.emissive, morningMix)
    local nightEmissive = number('Night CSP Light Emissive',1.05,0.5,3) * nightPreset.emissive
    relative('csp_lights.bounce', math.lerp(nightBounce, dayBounce, day))
    relative('csp_lights.emissive', math.lerp(nightEmissive, dayEmissive, day))
    configTry('csp_lights.displays', math.lerp(number('Night Display Brightness',1,0.5,2.5),
        number('Day Display Brightness',1,0.5,2.5), day))

    local daySaturation = number('Day Color Saturation',0.99,0.75,1.25)
        * math.lerp(1, morningPreset.saturation, morningMix)
    local nightSaturation = number('Night Color Saturation',0.94,0.7,1.2) * nightPreset.saturation
    local colorSat = math.lerp(nightSaturation, daySaturation, day)
    local dayContrast = number('Day Contrast',1,0.85,1.15)
        * math.lerp(1, morningPreset.contrast, morningMix)
    local nightContrast = number('Night Contrast',0.98,0.85,1.15) * nightPreset.contrast
    local contrast = math.lerp(nightContrast, dayContrast, day) * profile.contrast
    local wetWeatherRendering = check('Wet Weather Rendering', true)
    local wetWeatherSignal = wetWeatherRendering and clamp(math.max(rainIntensity, wetSurface)
        * math.lerp(0.65, 1, standingWater), 0, 1) or 0
    colorSat = colorSat * math.lerp(1,
        number('Rain Saturation Retention',0.8,0.4,1), wetWeatherSignal)
    contrast = contrast * (1 + wetWeatherSignal * number('Wet Black Depth',0.25,0,1) * 0.08)
    pure.config.set('pp.saturation', colorSat, true)
    pure.config.set('pp.contrast', contrast, true)
    local dayTemperature = number('Day Color Temperature',6400,4800,8000)
        + morningPreset.temperature * morningMix
    local nightTemperature = number('Night Color Temperature',6100,4000,8000)
        + nightPreset.temperature
    local whiteBalance = math.lerp(nightTemperature, dayTemperature, day)
    if check('Automatic White Balance', true) then
        local wbStrength = number('White Balance Strength',0.55,0,1)
        local lowSun = clamp((18 - math.abs(sunElevation)) / 18, 0, 1) * day
        local weatherWB = overcast * 170 + worldFog * 120 + rainIntensity * 100
            - lowSun * 360 - night * smog * 120
        whiteBalance = whiteBalance + weatherWB * wbStrength
    end
    whiteBalance = clamp(whiteBalance + number('White Balance Warmth Bias',0,-600,600), 4000, 8000)
    local wbLock = check('Lock White Balance', false)
    if wbLock and not lastWhiteBalanceLock then lockedWhiteBalance = whiteBalance end
    if wbLock then whiteBalance = lockedWhiteBalance or whiteBalance else lockedWhiteBalance = nil end
    lastWhiteBalanceLock = wbLock
    -- The scene temperature is measured against a fixed neutral white point.
    -- Writing the same value to both would cancel the shift in YEBIS.
    pure.yebis.set('colorTemperature', whiteBalance)
    pure.yebis.set('whiteBalance', NEUTRAL_WHITE_POINT)
    pure.yebis.set('hue', number('White Balance Tint',0,-0.03,0.03))

    relative('fog.cubemaps', number('Fog Cubemap Visibility',1,0,1))
    do
        local fogTuning = check('Enable Fog Fine Tuning', true)
        local fog = nil
        if type(pure.world.getPureGammaFogTable) == 'function' then
            local ok, fogTable = pcall(pure.world.getPureGammaFogTable)
            if ok then fog = fogTable end
        end
        if type(fog) == 'table' then
            -- With fine tuning off the live Pure fog passes straight through, so
            -- switching it off restores Pure instead of freezing the last values.
            local function fogScale(name, fallback, lo, hi)
                return fogTuning and number(name, fallback, lo, hi) or 1
            end
            ac.setFogDistance((fog.distance or 60000) * fogScale('Fog Distance',1,0.25,2.5))
            ac.setFogBlend((fog.blend or 0.9) * fogScale('Fog Blend',1,0.5,1.5))
            ac.setFogDensity((fog.density or 1) * fogScale('Fog Density',1,0,2)
                * (effectPreview == 5 and (1 + effectPreviewStrength * 0.75) or 1))
            ac.setFogExponent((fog.exponent or 1) * fogScale('Fog Exponent',1,0.5,2))
            ac.setFogHeight((fog.height or 100000) * fogScale('Fog Height',1,0.25,2))
            local baseFogColor = fog.color or rgb(0.72, 0.76, 0.82)
            local finalFogColor = baseFogColor
            if fogTuning then
                local fogColorPreset = math.floor(number('Fog Color Preset',1,1,6))
                local fogColorStrength = number('Adaptive Fog Color Strength',0.55,0,1)
                    * (1 - cockpit * 0.65)
                local lowSunFog = clamp((16 - math.abs(sunElevation)) / 16, 0, 1) * day
                local adaptiveFogColor = rgb(
                    0.72 + lowSunFog * 0.13 - weatherSeverity * 0.13 - night * 0.22,
                    0.77 - lowSunFog * 0.03 - weatherSeverity * 0.11 - night * 0.25,
                    0.83 - lowSunFog * 0.16 - weatherSeverity * 0.12 - night * 0.24)
                local fogPresetColor = adaptiveFogColor
                if fogColorPreset == 2 then fogPresetColor = rgb(0.74, 0.76, 0.78)
                elseif fogColorPreset == 3 then fogPresetColor = rgb(0.66, 0.76, 0.88)
                elseif fogColorPreset == 4 then fogPresetColor = rgb(0.90, 0.72, 0.56)
                elseif fogColorPreset == 5 then fogPresetColor = rgb(0.53, 0.59, 0.65)
                elseif fogColorPreset == 6 then fogPresetColor = rgb(0.38, 0.44, 0.55) end
                finalFogColor = mixColor(baseFogColor, fogPresetColor, fogColorStrength)
                if check('Custom Fog Color', false) then
                    local customFog = rgb(
                        number('Fog Color Red',0.72,0,1),
                        number('Fog Color Green',0.78,0,1),
                        number('Fog Color Blue',0.85,0,1))
                    local fogColorMix = number('Fog Color Mix',0.65,0,1) * (1 - cockpit * 0.65)
                    finalFogColor = mixColor(baseFogColor, customFog, fogColorMix)
                end
            end
            ac.setFogColor(finalFogColor)
            ac.setFogBacklitMultiplier(math.max(0, (fog.backlit or 0) * fogScale('Fog Backlight',1,0,2)))
            if type(fog.horizont) == 'table' then
                ac.setHorizonFogMultiplier(
                    (fog.horizont.multiplier or 0) * fogScale('Horizon Fog',1,0,2),
                    fog.horizont.exponent or 1,
                    fog.horizont.height or 0)
            end
        end
    end

    local bloomOn = check('Bloom Enabled', true)
    local glareOn = check('Glare Enabled', true)
    local glareStyleIndex = math.floor(number('Glare Style',1,1,8))
    local glareStyle = GLARE_STYLES[glareStyleIndex] or GLARE_STYLES[1]
    local glareStyleStrength = number('Glare Style Strength',0.85,0,1)
    if glareStyleIndex == 8 then glareStyleStrength = 0 end
    local styleBloom = math.lerp(1, glareStyle.bloom, glareStyleStrength)
    local styleRadius = math.lerp(1, glareStyle.radius, glareStyleStrength)
    local styleThreshold = math.lerp(1, glareStyle.threshold, glareStyleStrength)
    local styleStar = math.lerp(1, glareStyle.star, glareStyleStrength)
    local styleLength = math.lerp(1, glareStyle.length, glareStyleStrength)
    local styleSoftness = math.lerp(1, glareStyle.softness, glareStyleStrength)
    -- Styles offset the manual streak count rather than replacing it, so the
    -- Star Streaks slider stays live under every style.
    local styleStreaks = clamp(number('Star Streaks',4,2,8)
        + (glareStyle.streaks - 4) * glareStyleStrength, 2, 8)
    local styleGhost = clamp(number('Ghost Strength',0,0,0.5)
        + glareStyle.ghost * glareStyleStrength, 0, 0.5)
    local lensProfile = math.floor(number('Lens Profile',1,1,5))
    local lensProfileStrength = number('Lens Profile Strength',0.7,0,1)
    local lensVignetteMultiplier = 1
    local lensCAAddition = 0
    local lensDistortionAddition = 0
    local lensSoftnessMultiplier = 1
    if lensProfile == 1 then
        lensVignetteMultiplier = math.lerp(1, 0.72, lensProfileStrength)
        lensSoftnessMultiplier = math.lerp(1, 0.96, lensProfileStrength)
    elseif lensProfile == 2 then
        lensVignetteMultiplier = math.lerp(1, 1.22, lensProfileStrength)
        lensCAAddition = 0.00035 * lensProfileStrength
        lensDistortionAddition = 0.025 * lensProfileStrength
        lensSoftnessMultiplier = math.lerp(1, 1.10, lensProfileStrength)
    elseif lensProfile == 3 then
        lensVignetteMultiplier = math.lerp(1, 1.48, lensProfileStrength)
        lensCAAddition = 0.00085 * lensProfileStrength
        lensDistortionAddition = 0.075 * lensProfileStrength
        lensSoftnessMultiplier = math.lerp(1, 1.18, lensProfileStrength)
    elseif lensProfile == 4 then
        lensVignetteMultiplier = math.lerp(1, 0.82, lensProfileStrength)
        lensCAAddition = 0.00018 * lensProfileStrength
        lensDistortionAddition = 0.012 * lensProfileStrength
        lensSoftnessMultiplier = math.lerp(1, 0.92, lensProfileStrength)
    end
    local reactiveGlare = check('Reactive Glare', true)
    local reactiveStrength = number('Reactive Glare Strength',0.30,0,1)
    local nightLightEmphasis = number('Night Light Emphasis',0.20,0,1)
    local sourceAwareGlare = check('Source Aware Glare', true)
    local sunGlareSignal = 0
    local headlightGlareSignal = 0
    local nightLightSignal = night * clamp(highlightSignal * 0.70 + exposureLevel * 0.30, 0, 1)
    if sourceAwareGlare then
        sunGlareSignal = sunFacing * day * number('Sun Glare Response',0.35,0,1)
            * (1 - weatherSeverity * 0.45)
        headlightGlareSignal = nightLightSignal
            * number('Headlight Glare Response',0.40,0,1)
            * (1 + wetWeatherSignal * number('Wet Headlight Bloom',0.35,0,1) * 0.80)
    end
    local emissiveProtection = number('Emissive Color Protection',0.45,0,1)
    -- Colour protection follows the night-light signal on its own when
    -- Source Aware Glare is off, so the slider is never dead.
    local protectionSignal = sourceAwareGlare and headlightGlareSignal or nightLightSignal * 0.40
    local reactiveGain = 1
    if reactiveGlare then
        reactiveGain = clamp(1 + reactiveStrength * (
            exposureLevel * 0.18 + night * nightLightEmphasis
            + sunFacing * day * 0.10 - highlightSignal * highlightProtection * 0.35), 0.70, 1.45)
    end
    reactiveGain = clamp(reactiveGain + tunnelGlareBoost
        + sunGlareSignal * 0.28 + headlightGlareSignal * 0.34
        + (effectPreview == 3 and effectPreviewStrength * 0.55 or 0), 0.70, 2.20)
    local bloomStrength = (bloomOn and number('Bloom Strength',0.24,0,0.8) or 0)
        * profile.bloom * reactiveGain * styleBloom
    local glareStrength = (glareOn and number('Star Strength',0.11,0,0.5) or 0)
        * profile.glare * styleStar
        * clamp(reactiveGain + night * nightLightEmphasis * reactiveStrength * 0.25, 0.70, 1.55)
    pure.yebis.set('glareEnabled', bloomStrength > 0 or glareStrength > 0)
    pure.yebis.set('glareUseCustomShape', true)
    pure.yebis.set('glareShapeLuminance', number('Glare Master',1,0,2))
    pure.yebis.set('glareLuminance', number('Glare Master',1,0,2))
    pure.yebis.set('glareShapeBloomLuminance', bloomStrength)
    pure.yebis.set('glareThreshold', number('Bloom Threshold',0.52,0.15,1.2)
        * styleThreshold
        * (1 + highlightSignal * highlightProtection * 0.18
        + protectionSignal * emissiveProtection * 0.22))
    pure.yebis.set('glareBloomGaussianRadiusScale', number('Bloom Radius',0.44,0.15,1.2)
        * styleRadius
        * clamp(1 + sunGlareSignal * 0.24 - headlightGlareSignal * 0.10, 0.85, 1.25))
    pure.yebis.set('glareBloomLevels', math.floor(number('Bloom Levels',4,1,8)+0.5))
    pure.yebis.set('glareBloomLuminanceGamma', number('Bloom Gamma',1.05,0.8,1.6))
    do
        local bloomFilterThreshold = number('Bloom Filter Threshold',0.001,0.0001,0.01)
        pure.yebis.set('glareBloomFilterThreshold', bloomFilterThreshold)
        call(ac.setGlareBloomFilterThreshold, bloomFilterThreshold)
    end
    pure.yebis.set('glareShapeStarLuminance', glareStrength
        * clamp(1 + headlightGlareSignal * 0.24 - sunGlareSignal * 0.08, 0.85, 1.35))
    pure.yebis.set('glareShapeStarLength', number('Star Length',0.065,0,0.3)
        * styleLength
        * clamp(1 + headlightGlareSignal * 0.18, 1, 1.18))
    pure.yebis.set('glareShapeStarStreaks', math.floor(styleStreaks+0.5))
    pure.yebis.set('glareStarSoftness', number('Star Softness',0.85,0.2,1.5)
        * lensSoftnessMultiplier * styleSoftness)
    do
        local starFilterThreshold = number('Star Filter Threshold',0.0015,0.0001,0.01)
        pure.yebis.set('glareStarFilterThreshold', starFilterThreshold)
        call(ac.setGlareStarFilterThreshold, starFilterThreshold)
    end
    pure.yebis.set('glareShapeGhostLuminance', glareOn and styleGhost or 0)
    pure.yebis.set('glareShapeAfterimageLuminance', glareOn and number('Afterimage Strength',0,0,0.4) or 0)
    pure.yebis.set('glareShapeAfterimageLength', number('Afterimage Length',0.2,0,1))
    pure.yebis.set('glareAnamorphic', check('Anamorphic Glare', false))
    yebisTry('glareQuality', RENDER_QUALITY[math.floor(number('Render Quality',3,1,4))] or 4)

    -- Pure's sun-blinding overlay supplies only the veil and iris response. Its
    -- star sprite stays off so it never doubles the YEBIS star glare above, and
    -- the veil yields to Sun Glare Response when that is already active.
    do
        local blindingShare = 1 - clamp(sunGlareSignal * 1.2, 0, 0.5)
        configTry('shaders.sunblinding.blinding', number('Sun Blinding',0.35,0,1) * 0.30
            * (1 - weatherSeverity * 0.6) * blindingShare)
        configTry('shaders.sunblinding.iris', number('Sun Blinding Iris',0.15,0,1) * 0.60)
        configTry('shaders.sunblinding.star_opacity', 0)
        configTry('shaders.sunblinding.cover', 0)
    end

    local darkSpeed = number('Dark Adaptation Speed',1.5,0.25,8)
    local brightSpeed = number('Bright Adaptation Speed',6,0.5,12)
    if cameraStyleResponse then
        darkSpeed = math.max(darkSpeed, 5.0)
        brightSpeed = math.max(brightSpeed, 9.0)
    end
    if tunnelPreset > 1 and tunnelInterior > 0 then
        darkSpeed = math.max(darkSpeed, 3.5 + tunnelInterior * 2.5)
        brightSpeed = math.max(brightSpeed, 7.5 + cameraOcclusion * 2.0)
    elseif metering == 4 then
        darkSpeed = math.min(darkSpeed, 1.10)
        brightSpeed = math.min(brightSpeed, 3.20)
    end
    pure.exposure.setCBEMix(number('CBE Mix',0.88,0,1))
    pure.exposure.cbe.setTarget(number('CBE Target',4,1,8) * (1 + sceneTargetShift))
    pure.exposure.cbe.setSensitivity(number('CBE Sensitivity',1.45,0.5,3))
    pure.exposure.cbe.setLimits(minExposure, maxExposure)
    pure.exposure.cbe.setAdaptionSpeeds(darkSpeed, brightSpeed)
    pure.exposure.yebis.setTarget(number('YEBIS Target',1,0.25,3) * (1 + sceneTargetShift * 0.55))
    pure.exposure.yebis.setLimits(minExposure, maxExposure)
    pure.exposure.yebis.setAdaptionSpeeds(darkSpeed, brightSpeed)
    local adaptiveHighlightEV = adaptiveExposure
        and (-highlightSignal * highlightProtection * adaptationStrength * 0.60) or 0
    local ev = number('Exposure Compensation EV',0,-1.5,1.5)
        + night * nightPreset.exposure
        + cockpit * number('Cockpit Compensation EV',0.1,-0.75,0.75)
        + adaptiveHighlightEV
        + tunnelEVBoost
        + sceneEV()
        + (effectPreview == 2 and sceneTargetShift * effectPreviewStrength * 1.5 or 0)
    pure.exposure.cbe.setMultiplier(2^ev)
    local lock = check('Lock Exposure', false)
    if lock and not lastLock then
        local measured = pure.exposure.getValue()
        lockedExposure = type(measured) == 'number' and measured == measured and measured or 0.25
    end
    if lock then
        pure.exposure.setBypass(clamp(lockedExposure or 0.25, 0.001, 4), 1)
    else
        pure.exposure.setBypass(0.25, 0)
        lockedExposure = nil
    end
    lastLock = lock


    do
        local adaptiveGodrays = check('Adaptive Godrays', true)
        local godraysStrength = number('Godrays Strength',0.35,0,1)
        local godraysFovResponse = number('Godrays FOV Response',0.50,0,1)
        local godraysFacingResponse = number('Godrays Sun Facing Response',0.60,0,1)
        local godraysGlareRatio = number('Godrays Glare Ratio',0.12,0,1)
        local godraysModulator = clamp(read(pure.pp.getGodraysModulator, 1), 0, 1)
        local fovScale = math.lerp(1, clamp(fov / 50, 0.55, 1.70), godraysFovResponse)
        local sunRays = 0
        local sunRayGlare = 0
        local sunRaysOn = adaptiveGodrays and godraysStrength > 0
        if sunRaysOn then
            local facingScale = 1 + godraysFacingResponse * (sunFacing * 0.35 - 0.15)
            sunRays = 6.0 * godraysStrength * godraysModulator * day * fovScale * facingScale
            sunRayGlare = godraysGlareRatio * godraysStrength * godraysModulator
        end
        -- Moon shafts need the moon above the horizon and fade with cloud and fog.
        local moonGodrays = number('Moon Godrays Strength',0,0,1)
        local moonRays = moonGodrays * 3.0 * night * fovScale
            * clamp((moonElevation - 2) / 20, 0, 1) * (1 - celestialWeather * 0.75)
        local rayLengthScale = number('godray_length',10,0,20) / 10
        if (sunRaysOn or moonRays > 0) and rayLengthScale > 0 then
            pure.yebis.set('godraysEnabled', true)
            pure.yebis.set('godraysLength', math.max(0.001, (sunRays + moonRays) * rayLengthScale))
            pure.yebis.set('godraysAngleAttenuation', math.lerp(18, 10, sunFacing))
            pure.yebis.set('godraysGlareRatio', sunRayGlare + moonRays * 0.012)
            pure.yebis.set('godraysDepthMaskThreshold', 0.99998)
            pure.yebis.set('godraysUseSunLightColor', true)
        else
            pure.yebis.set('godraysEnabled', false)
            pure.yebis.set('godraysLength', 0.001)
            pure.yebis.set('godraysGlareRatio', 0)
        end
    end

    local fovVignette = math.lerp(1, clamp(50 / fov, 0.70, 1.35),
        number('Vignette FOV Dependence',0.25,0,1))
    pure.yebis.set('vignetteStrength', number('Vignette Strength',0.01,0,0.2)
        * profile.vignette * lensVignetteMultiplier * fovVignette)
    pure.yebis.set('vignetteFOVDependence', number('Vignette FOV Dependence',0.25,0,1))
    -- The checkboxes are the master switches; lens profiles only add character
    -- on top of an enabled effect.
    local ca = check('Chromatic Aberration', false)
    local lateral = ca and (number('Chromatic Lateral',0.001,0,0.01) + lensCAAddition) or 0
    local uniform = ca and (number('Chromatic Uniform',0.0003,0,0.005)
        + lensCAAddition * 0.25) or 0
    pure.yebis.set('chromaticAberrationEnabled', ca)
    pure.yebis.set('chromaticAberrationActive', ca)
    pure.yebis.set('chromaticAberrationSamples', math.floor(number('Chromatic Samples',5,2,12)+0.5))
    pure.yebis.set('chromaticAberrationLateralDisplacement', vec2(lateral, lateral*0.5))
    pure.yebis.set('chromaticAberrationUniformDisplacement', vec2(uniform, uniform))
    local distortion = check('Lens Distortion', false)
    pure.yebis.set('lensDistortionEnabled', distortion)
    pure.yebis.set('lensDistortionRoundness', clamp(number('Lens Roundness',0.05,0,1)
        + lensDistortionAddition, 0, 1))
    pure.yebis.set('lensDistortionSmoothness', number('Lens Smoothness',1,0.1,2))

    do
        local dofOn = check('Depth of Field', false)
        if dofOn then
            yebisTry('dofEnabled', true)
            yebisTry('dofActive', true)
            yebisTry('dofFocusDistance', number('DOF Focus Distance',8,0.5,100))
            yebisTry('dofApertureFNumber', number('DOF Aperture',2.8,1.2,22))
            yebisTry('dofImageSensorHeight', 0.024)
            yebisTry('dofQuality', math.floor(number('DOF Quality',3,1,5) + 0.5))
        elseif dofWasEnabled then
            -- Released once on switch-off so other DOF sources are not overridden.
            yebisTry('dofEnabled', false)
            yebisTry('dofActive', false)
        end
        dofWasEnabled = dofOn
    end

    local adaptiveReflections = check('Adaptive Reflections', true)
    local reflectionWeatherResponse = number('Reflection Weather Response',0.30,0,1)
    local reflectionCPLStrength = number('Reflection CPL Strength',0.15,0,1)
    local reflectionHighlightResponse = number('Reflection Highlight Response',0.20,0,1)
    local reflectionLevelAuto = 1
    local reflectionSaturationAuto = 1
    local reflectionEmissiveAuto = 1
    local reflectionVaoAuto = 1
    if adaptiveReflections then
        reflectionLevelAuto = clamp(1 + reflectionWeatherResponse * (
            wetSurface * 0.22 - overcast * 0.05 - worldFog * 0.08)
            + reflectionHighlightResponse * highlightSignal * 0.18, 0.82, 1.30)
        reflectionSaturationAuto = clamp(1 - reflectionWeatherResponse * (
            overcast * 0.10 + worldFog * 0.12 + badness * 0.05), 0.78, 1.05)
        reflectionEmissiveAuto = clamp(1 + reflectionWeatherResponse * (
            night * 0.18 + wetSurface * 0.14), 1, 1.35)
        reflectionVaoAuto = clamp(1 + reflectionWeatherResponse * (
            overcast * 0.08 + wetSurface * 0.10), 1, 1.18)
    end
    -- The polarizer works in every mode; Adaptive Reflections only adds the
    -- heavy-weather reduction.
    do
        local presetCpl = reflectionPresetIndex == 3 and 1.25
            or (reflectionPresetIndex == 2 and 0.90 or 1.00)
        local cplWeather = adaptiveReflections and (1 - weatherSeverity * 0.55) or 1
        local cpl = clamp(reflectionCPLStrength * presetCpl
            * cplWeather * math.lerp(0.45, 1, day), 0, 1)
        if adaptiveReflections or cpl > 0 then
            pure.camera.setCPL(cpl, 0, 0, 1)
        else
            pure.camera.setCPL()
        end
    end

    -- Fresnel gamma below 1 strengthens grazing-angle reflections. Wet roads add
    -- to the manual amount, so a drying track settles back on its own.
    do
        local fresnelAmount = number('Fresnel Strength',0,0,1)
        if wetWeatherRendering then
            fresnelAmount = fresnelAmount + wetSurface * number('Wet Reflection Gain',0.45,0,1) * 0.35
        end
        call(ac.setFresnelGamma, math.lerp(1, 0.6, clamp(fresnelAmount, 0, 1)))
    end

    if wetWeatherRendering then
        local wetReflectionGain = number('Wet Reflection Gain',0.45,0,1)
        reflectionLevelAuto = reflectionLevelAuto * (1 + wetSurface * wetReflectionGain * 0.32)
        reflectionEmissiveAuto = reflectionEmissiveAuto * (1
            + wetSurface * night * number('Wet Headlight Bloom',0.35,0,1) * 0.28)
        -- Heavy cloud cover limits sky reflections while standing water still
        -- carries nearby lights and road detail.
        reflectionLevelAuto = reflectionLevelAuto
            * clamp(1 - overcast * (1 - standingWater) * 0.08, 0.90, 1)
    end
    if effectPreview == 4 then
        reflectionLevelAuto = reflectionLevelAuto * (1 + effectPreviewStrength * 0.35)
        reflectionEmissiveAuto = reflectionEmissiveAuto * (1 + effectPreviewStrength * 0.25)
    end

    relative('reflections.level', number('Reflection Level',1.05,0.5,1.8)
        * profile.reflection * reflectionPreset.level * reflectionLevelAuto)
    relative('reflections.saturation', number('Reflection Saturation',1,0.6,1.4)
        * reflectionPreset.saturation * reflectionSaturationAuto)
    relative('reflections.emissive_boost', number('Reflection Emissive Boost',1.1,0,5)
        * reflectionPreset.emissive * reflectionEmissiveAuto)
    relative('vao.amount', number('VAO Amount',1,0.5,1.5)
        * reflectionPreset.vao * reflectionVaoAuto)
    relative('vao.track_exponent', number('VAO Track Exponent',1,0.5,1.5)
        * reflectionPreset.trackExponent)
    relative('vao.dynamic_exponent', number('VAO Dynamic Exponent',1,0.5,1.5)
        * reflectionPreset.dynamicExponent)
    pure.light.setVAOAdaption(clamp(number('Weather VAO Adaptation',0.45,0,1)
        * reflectionPreset.weatherVAO * reflectionVaoAuto, 0, 1))

    if diagnosticsEnabled then
        pure.script.ui.setValue('Live Exposure', calculatedExposure)
        pure.script.ui.setValue('Live Highlights', highlightSignal)
        pure.script.ui.setValue('Camera Occlusion', cameraOcclusion)
        pure.script.ui.setValue('Wet Surface', wetSurface)
        pure.script.ui.setValue('World Fog', worldFog)
        pure.script.ui.setValue('Sun Facing', sunFacing)
        pure.script.ui.setValue('Tunnel Response', math.abs(tunnelEVBoost))
        pure.script.ui.setValue('Star Output', starOutput.brightness)
        local renderStatus = 'Balanced scene'
        if highlightSignal > 0.82 and calculatedExposure <= minExposure * 1.20 then
            renderStatus = 'Warning: concentrated highlight clipping risk'
        elseif calculatedExposure >= maxExposure * 0.96 then
            renderStatus = 'Warning: shadows near exposure ceiling'
        elseif tunnelFlash > 0.05 then
            renderStatus = 'Tunnel exit recovery active'
        elseif tunnelInterior > 0.25 and tunnelPreset > 1 then
            renderStatus = 'Tunnel interior adaptation active'
        elseif wetWeatherSignal > 0.35 then
            renderStatus = 'Wet-weather rendering active'
        elseif worldFog > 0.35 or mist > 0.35 then
            renderStatus = 'Fog contrast protection active'
        end
        pure.script.ui.setString('Render Status', renderStatus)
    else
        pure.script.ui.setString('Render Status', 'Diagnostics disabled')
    end
end
end

-- ============================================================================
-- ENGINE 2: ST6IX V1.5 (Professional Edition)
-- ============================================================================
local V15 = {}
do
local pure, ac = makeGatedApi(15, OUT15, v15GetValue)

-- V1.5 tables and tonemappers (weather-aware finishing, based on V1.4).
-- ============================================================================
-- CONFIGURATION TABLES
-- ============================================================================

local _l_exposure_LUT = {
--  CBE    exp    day   twi   ngt   fog   ref   amb
    { 0.00,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 1.00 },
    { 0.02,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 1.00 },
    { 0.05,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 0.55 },
    { 0.063, 0.17, 0.0,  1.00, 0.90, 0.00, 1.00, 0.35 },
    { 0.075, 0.25, 0.0,  1.00, 0.60, 0.00, 0.95, 0.15 },
    { 0.087, 0.60, 0.0,  1.00, 0.30, 0.00, 0.90, 0.00 },
    { 0.1,   0.90, 0.0,  1.00, 0.15, 0.05, 0.80, 0.00 },
    { 0.15,  1.00, 0.0,  0.75, 0.05, 0.15, 0.65, 0.00 },
    { 0.2,   0.50, 0.1,  0.25, 0.00, 0.30, 0.40, 0.00 },
    { 0.3,   0.25, 0.7,  0.00, 0.00, 0.60, 0.20, 0.00 },
    { 0.5,   0.05, 1.0,  0.00, 0.00, 1.00, 0.05, 0.00 },
    { 1.0,   0.00, 1.0,  0.00, 0.00, 1.00, 0.00, 0.00 },
}
local _l_ExposureCPP = LUT:new(_l_exposure_LUT)
local _l_Exposure_lut = _l_ExposureCPP:get(0.03)

-- ============================================================================
-- TONEMAPPING CONFIGURATION
-- ============================================================================

local tonemap__custom = {
    values = {
        P = 2.00,
        a = 1.00,
        m = 0.29,
        l = 0.40,
        c = 1.00,
        b = 0.00,
        gain = 1.00,
        agx_mix = 0.85,
        agx_mix_exp = 0.40,
        agx_slope = 1.25,
        agx_power = 1.75,
        agx_sat = 0.99,
    },
    shader = [[
    #define luminosityFactor float3(0.2126, 0.7152, 0.0722)

    float3 agxDefaultContrastApprox(float3 x) {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        return + 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4
               - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    }

    float3 agx(float3 val) {
        float3x3 agx_mat = float3x3(
          0.842479062253094, 0.0423282422610123, 0.0423756549057051,
          0.0784335999999992, 0.878468636469772, 0.0784336,
          0.0792237451477643, 0.0791661274605434, 0.879142973793104);
        float min_ev = -12.47393f;
        float max_ev = 4.026069f;
        val = mul(agx_mat, val);
        // Avoid log2(0) and invalid negative values in deep shadows.
        val = max(val, float3(1e-6, 1e-6, 1e-6));
        val = clamp(log2(val), min_ev, max_ev);
        val = (val - min_ev) / (max_ev - min_ev);
        val = agxDefaultContrastApprox(val);
        return val;
    }

    float3 agxEotf(float3 val) {
        float3x3 agx_mat_inv = float3x3(
          1.19687900512017, -0.0528968517574562, -0.0529716355144438,
          -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
          -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
        return mul(agx_mat_inv, val);
    }

    float3 agxLook(float3 val) {
        float luma = dot(val, luminosityFactor);
        float3 offset = float3(0.0, 0.0, 0.0);
        float3 slope = float3(agx_slope, agx_slope, agx_slope);
        float3 power = float3(agx_power, agx_power, agx_power);
        float sat = agx_sat;
        val = pow(max(0, val * slope + offset), power);
        return luma + sat * (val - luma);
    }

    float uchimura(float x) {
        float l0 = ((P - m) * l) / a;
        float L0 = m - m / a;
        float L1 = m + (1.0 - m) / a;
        float S0 = m + l0;
        float S1 = m + a * l0;
        float C2 = (a * P) / (P - S1);
        float CP = -C2 / P;
        float w0 = 1.0 - smoothstep(0.0, m, x);
        float w2 = step(m + l0, x);
        float w1 = 1.0 - w0 - w2;
        float T = m * pow(abs(x / m), c) + b;
        float S = P - (P - S1) * exp(CP * (x - S0));
        float L = m + a * (x - m);
        return T * w0 + L * w1 + S * w2;
    }

    float3 RGB_Uchimura_AgX(float3 x){
        float luma = saturate(dot(x, luminosityFactor));
        float3 col = agx(x);
        col = agxLook(col);
        col = agxEotf(col);
        x = lerp(x, col, agx_mix * pow(luma, agx_mix_exp));
        x *= gain;
        x = float3(uchimura(x.r), uchimura(x.g), uchimura(x.b));
        return x;
    }

    float3 tonemapping(float3 x){
        return RGB_Uchimura_AgX(x);
    }
]]
}

local tonemap__aces = {
    values = {
        exposure = 1.0,
    },
    shader = [[
    float3 ACESFitted(float3 x) {
        float3 a = x*(2.51*x + 0.03);
        float3 b = x*(2.43*x + 0.59) + 0.14;
        return saturate(a / b);
    }
    float3 tonemapping(float3 x){
        x = max(x, float3(0,0,0));
        x *= exposure;
        return ACESFitted(x);
    }
]]
}

-- ============================================================================
-- GLOBAL VARIABLES
-- ============================================================================

local CSP_VERSION = ac.getPatchVersionCode()
local _l_init = true
local _l_current_tonemapping = 2

-- Retrograde intro smoothing (seconds)
local retro_intro_time = 0.0
local retro_intro_duration = 2.5

local cloud_shadow = 0
local cloud_shadow_sun = 0
local cloud_shadow_twilight = 0
local cam_sun_face = 0
local badness = 0
local fog = 0
local occlusion = 0
local gamma = 1.0
local photo_realistic = 0.0
local interior = true
local color_mod = 1.0
local hsv_fog = hsv(0, 0, 0)
local rgb_fog = rgb(0, 0, 0)

-- Local cache for sun/moon size binding (keeps UI and engine config in sync)
local _last_cfg_sun_moon = nil
local _last_ui_sun_moon = nil
local _last_exposure_error = nil
local _last_godray_length = nil


local fogdensity = 0
local fogsat = 1
local fogtype = 2
local daycurvefog = 1

-- Unified preset tracker
-- unified preset tracker removed (reverted preset additions)


cover = cover or ac.SkyCloudsCover()
ac.addWeatherCloudCover(cover)

-- ============================================================================
-- PRESET DEFINITIONS
-- ============================================================================

-- LIGHTING PRESETS (0=Pure Default, 1=Sunrise/Sunset, 2=Midday, 3=Natural, 4=Golden Hour, 5=Crisp Clear, 6=Manual) - Daylight only
local LIGHTING_PRESETS = {
    [0] = { daylight_multiplier=1.00, sun_level=1.00, sun_speculars=1.00, ambient_level=1.00, advanced_ambient_light=1.00, sky_level=1.00, advanced_ambient_lightV2_sun=1.00, csp_lights_bounce=1.00, csp_lights_emissive=1.00 },  -- Pure Default: neutral
    [1] = { daylight_multiplier=1.62, sun_level=0.73, sun_speculars=1.077, ambient_level=0.952, advanced_ambient_light=1.077, sky_level=1.038, advanced_ambient_lightV2_sun=0.724, csp_lights_bounce=1.132, csp_lights_emissive=1.00 },  -- Sunrise/Sunset
    [2] = { daylight_multiplier=1.05, sun_level=0.95, sun_speculars=1.00, ambient_level=1.00, advanced_ambient_light=1.05, sky_level=1.03, advanced_ambient_lightV2_sun=0.98, csp_lights_bounce=1.00, csp_lights_emissive=1.00 },  -- Midday: neutral physical balance
    [3] = { daylight_multiplier=1.12, sun_level=0.92, sun_speculars=0.95, ambient_level=1.04, advanced_ambient_light=1.08, sky_level=1.06, advanced_ambient_lightV2_sun=1.01, csp_lights_bounce=1.05, csp_lights_emissive=1.00 }, -- Natural
    [4] = { daylight_multiplier=1.45, sun_level=0.85, sun_speculars=1.20, ambient_level=1.05, advanced_ambient_light=1.10, sky_level=1.12, advanced_ambient_lightV2_sun=0.90, csp_lights_bounce=1.10, csp_lights_emissive=1.05, bloom_preset=6 }, -- Golden Hour
    [5] = { daylight_multiplier=1.18, sun_level=1.00, sun_speculars=1.06, ambient_level=1.00, advanced_ambient_light=1.02, sky_level=1.08, advanced_ambient_lightV2_sun=1.00, csp_lights_bounce=1.02, csp_lights_emissive=1.00, pp_contrast=1.05, pp_sharpness=0.12, bloom_preset=7 }, -- Crisp Clear
}

-- REFLECTIONS PRESETS (0=Pure Default, 1=High Quality, 2=Performance, 3=Cinematic, 4=Manual)
local REFLECTIONS_PRESETS = {
    [0] = { reflections_saturation=1.00, reflections_level=1.00, reflections_emissive_boost=1.0, vao_amount=1.00, groundfog_gain=1.00 },  -- Pure Default: neutral
    [1] = { reflections_saturation=1.05, reflections_level=1.12, reflections_emissive_boost=4.0, vao_amount=1.08, groundfog_gain=1.00 },
    [2] = { reflections_saturation=0.95, reflections_level=0.82, reflections_emissive_boost=2.0, vao_amount=0.85, groundfog_gain=0.80 },  -- Performance
    [3] = { reflections_saturation=1.06, reflections_level=1.25, reflections_emissive_boost=8.0, vao_amount=1.10, groundfog_gain=1.10 },

    -- Richer looks remain available, but are capped to photographic values.
    [4] = { reflections_saturation=1.12, reflections_level=1.35, reflections_emissive_boost=12.0, vao_amount=1.15, groundfog_gain=1.12 },
    [5] = { reflections_saturation=1.10, reflections_level=1.45, reflections_emissive_boost=16.0, vao_amount=1.20, groundfog_gain=1.18 },
}

-- BLOOM & GLARE PRESETS (0=Pure Default, 1=Subtle, 2=Cinematic, 3=Intense, 4=Neon City, 5=Wet Night, 6=Golden Hour, 7=Crisp Clear, 8=Manual)
local BLOOM_PRESETS = {
    -- Values are calibrated against ST6IX PP V1.1(2).ini. Bloom filter
    -- thresholds are intentionally separate and remain in the INI-sized
    -- 0.0001-0.005 range instead of being fed the master 0-1 threshold.
    [0] = { bloom_intensity=0.34, bloom_threshold=0.46, bloom_filter=0.0010, bloom_radius=0.46, bloom_levels=4, bloom_gamma=1.02 },
    [1] = { bloom_intensity=0.22, bloom_threshold=0.54, bloom_filter=0.0015, bloom_radius=0.34, bloom_levels=3, bloom_gamma=1.00 },
    [2] = { bloom_intensity=0.40, bloom_threshold=0.43, bloom_filter=0.0008, bloom_radius=0.52, bloom_levels=4, bloom_gamma=1.03 },
    [3] = { bloom_intensity=0.48, bloom_threshold=0.50, bloom_filter=0.0007, bloom_radius=0.48, bloom_levels=4, bloom_gamma=1.04 },
    [4] = { bloom_intensity=0.36, bloom_threshold=0.48, bloom_filter=0.0008, bloom_radius=0.40, bloom_levels=3, bloom_gamma=1.02 },
    [5] = { bloom_intensity=0.46, bloom_threshold=0.44, bloom_filter=0.0006, bloom_radius=0.56, bloom_levels=4, bloom_gamma=1.03 },
    [6] = { bloom_intensity=0.32, bloom_threshold=0.47, bloom_filter=0.0010, bloom_radius=0.44, bloom_levels=3, bloom_gamma=1.01 },
    [7] = { bloom_intensity=0.18, bloom_threshold=0.58, bloom_filter=0.0020, bloom_radius=0.28, bloom_levels=2, bloom_gamma=1.00 },
}

-- Compatibility failures in optional YEBIS fields are logged once, never allowed
-- to abort the update before tonemapping. No exposure or tone changes.
local st6ix_bloom_field_errors = {}


-- EXPOSURE PRESETS (0=Pure Default, 1=Balanced, 2=High Dynamic, 3=Low Light, 4=Manual)
-- Using handleExposure parameters: method, target, minimumexposure, superexposure, fixedexposure, mix
local EXPOSURE_PRESETS = {
    [0] = { method=5, target=4.0,  minimumexposure=0.01,  superexposure=0.50, fixedexposure=0.25, mix=1.0 },  -- Pure Default: Neutral balanced
    [1] = { method=5, target=3.0,  minimumexposure=0.01,  superexposure=0.70, fixedexposure=0.30, mix=1.0 },  -- Balanced: Even distribution
    [2] = { method=5, target=2.5,  minimumexposure=0.005, superexposure=1.00, fixedexposure=0.35, mix=0.85 }, -- High Dynamic: Wide range
    [3] = { method=5, target=2.0,  minimumexposure=0.02,  superexposure=1.50, fixedexposure=0.50, mix=1.0 },  -- Low Light: Bright for dark scenes
}

-- CUSTOM EXPOSURE PRESETS (ST6IX-style with direct CBE/Yebis control)
-- Each preset defines: day_target, night_target, day_interior_target, night_interior_target, day_sensitivity, night_sensitivity, ae_mix, tunnel_blinding_strength
local CUSTOM_EXPOSURE_PRESETS = {
    [0] = { day_target=4.0, night_target=3.0, day_interior_target=4.0, night_interior_target=3.0, day_sensitivity=3.0, night_sensitivity=1.0, ae_mix=0.5, tunnel_blinding=1.25, day_exp_target=0.1, night_exp_target=0.75, day_interior_exp=0.12, night_interior_exp=0.5 },  -- Balanced
    [1] = { day_target=4.5, night_target=3.5, day_interior_target=4.5, night_interior_target=3.5, day_sensitivity=2.5, night_sensitivity=1.2, ae_mix=0.6, tunnel_blinding=1.0, day_exp_target=0.08, night_exp_target=0.60, day_interior_exp=0.10, night_interior_exp=0.45 },  -- Bright/Vivid
    [2] = { day_target=3.5, night_target=2.5, day_interior_target=3.5, night_interior_target=2.5, day_sensitivity=3.5, night_sensitivity=0.8, ae_mix=0.4, tunnel_blinding=1.5, day_exp_target=0.12, night_exp_target=0.90, day_interior_exp=0.14, night_interior_exp=0.60 },  -- Dark/Moody
    [3] = { day_target=5.0, night_target=4.0, day_interior_target=5.0, night_interior_target=4.0, day_sensitivity=2.0, night_sensitivity=1.5, ae_mix=0.7, tunnel_blinding=0.8, day_exp_target=0.06, night_exp_target=0.50, day_interior_exp=0.08, night_interior_exp=0.40 },  -- High Contrast
}

-- HDR & CLARITY PRESETS (0=Off, 1=Subtle HDR, 2=Full HDR, 3=Ultra HDR, 4=Cinematic Sharp, 5=Manual)
local HDR_CLARITY_PRESETS = {
    [0] = { sharpness=0.0, clarity=0.0, micro_contrast=0.0, hdr_brightness=1.0, color_vibrance=0.0, highlight_recovery=0.0 },
    [1] = { sharpness=0.12, clarity=0.14, micro_contrast=0.06, hdr_brightness=1.00, color_vibrance=0.03, highlight_recovery=0.12 },
    [2] = { sharpness=0.18, clarity=0.22, micro_contrast=0.10, hdr_brightness=1.02, color_vibrance=0.06, highlight_recovery=0.18 },
    [3] = { sharpness=0.25, clarity=0.30, micro_contrast=0.14, hdr_brightness=1.04, color_vibrance=0.08, highlight_recovery=0.24 },
    [4] = { sharpness=0.20, clarity=0.20, micro_contrast=0.12, hdr_brightness=1.01, color_vibrance=0.04, highlight_recovery=0.16 },
}

-- Overall finishing profiles. They scale post-processing and lighting controls
-- without replacing the selected tonemapping or skydome.
local ST6IX_PROFILES = {
    [0] = { bloom=0.72, cockpit_bloom=0.58, exterior_bloom=0.82, glare=0.38, bloom_radius=0.85, sharpness=0.68, clarity=0.74, vignette=0.025, grain=0.00 },
    [1] = { bloom=0.82, cockpit_bloom=0.64, exterior_bloom=0.90, glare=0.52, bloom_radius=0.90, sharpness=0.78, clarity=0.82, vignette=0.05,  grain=0.025 },
    [2] = { bloom=0.92, cockpit_bloom=0.72, exterior_bloom=0.98, glare=0.70, bloom_radius=0.95, sharpness=0.88, clarity=0.90, vignette=0.075, grain=0.04 },
    [3] = { bloom=1.00, cockpit_bloom=1.00, exterior_bloom=1.00, glare=1.00, bloom_radius=1.00, sharpness=1.00, clarity=1.00, vignette=nil, grain=nil },
}

-- SKY PRESETS (0=Pure Default, 1=Vivid, 2=Cinematic, 3=Natural, 4=Golden Hour, 5=Overcast Soft, 6=Pastel Dawn, 7=Smog/City Haze, 8=Storm Incoming, 9=Manual)
local SKY_PRESETS = {
    [0] = { day = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.0, clouds_contrast=1.0, sky_level=1.0, sky_saturation=1.0 }, night = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.0, clouds_contrast=1.0, sky_level=1.0, sky_saturation=1.0 }, duskdawn_sky_level=0.25 },
    [1] = { day = { sky_light_level=1.3, ["sun.sun_moon_size"]=1.5, clouds_brightness=0.481, clouds_contrast=1.115, sky_level=1.2, sky_saturation=1.3 }, night = { sky_light_level=1.3, ["sun.sun_moon_size"]=1.5, clouds_brightness=1.3, clouds_contrast=1.0, sky_level=1.2, sky_saturation=1.3 }, duskdawn_sky_level=0.35 },
    [2] = { day = { sky_light_level=1.125, ["sun.sun_moon_size"]=2.0, clouds_brightness=0.9, clouds_contrast=1.2, sky_level=0.9, sky_saturation=0.85 }, night = { clouds_brightness=0.8, clouds_contrast=1.1, sky_level=0.9, sky_saturation=0.85 }, duskdawn_sky_level=0.4 },
    [3] = { day = { sky_light_level=1.05, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.1, clouds_contrast=0.95, sky_level=1.1, sky_saturation=1.05 }, night = { sky_light_level=1.15, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.15, clouds_contrast=0.9, sky_level=1.1, sky_saturation=1.05 }, duskdawn_sky_level=0.3 },
    [4] = { day = { sky_light_level=1.1, ["sun.sun_moon_size"]=1.2, clouds_brightness=0.95, clouds_contrast=1.05, sky_level=1.12, sky_saturation=1.25 }, night = { sky_light_level=1.1, ["sun.sun_moon_size"]=1.2, clouds_brightness=1.1, clouds_contrast=1.0, sky_level=1.12, sky_saturation=1.25 }, duskdawn_sky_level=0.55 }, -- Golden Hour

    -- Requested additional presets
    [5] = { day = { sky_light_level=0.9, ["sun.sun_moon_size"]=0.95, clouds_brightness=1.6, clouds_contrast=0.6, sky_level=0.9, sky_saturation=0.7 }, night = { sky_light_level=0.9, ["sun.sun_moon_size"]=0.95, clouds_brightness=1.6, clouds_contrast=0.6, sky_level=0.9, sky_saturation=0.7 } }, -- Overcast Soft
    [6] = { day = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.05, clouds_brightness=0.8, clouds_contrast=0.8, sky_level=1.0, sky_saturation=1.1 }, night = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.05, clouds_brightness=0.8, clouds_contrast=0.8, sky_level=1.0, sky_saturation=1.1 }, duskdawn_sky_level=0.45 }, -- Pastel Dawn
    [7] = { day = { sky_light_level=0.8, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.2, clouds_contrast=0.7, sky_level=0.8, sky_saturation=0.6 }, night = { sky_light_level=0.8, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.2, clouds_contrast=0.7, sky_level=0.8, sky_saturation=0.6 } }, -- Smog / City Haze
    [8] = { day = { sky_light_level=0.7, ["sun.sun_moon_size"]=1.0, clouds_brightness=0.45, clouds_contrast=1.4, sky_level=0.7, sky_saturation=0.6 }, night = { sky_light_level=0.7, ["sun.sun_moon_size"]=1.0, clouds_brightness=0.45, clouds_contrast=1.4, sky_level=0.7, sky_saturation=0.6 } }, -- Storm Incoming
}

-- NIGHT PRESETS (0=Bright Night, 1=Dark Night, 2=Cinematic, 3=Neon City, 4=Wet Night, 5=Adjust-N)
local NIGHT_PRESETS = {
    [0] = { nlp_level=0.5, nlp_density=0.7, nlp_lowest_ambient=0.6, moon_light=0.8, moon_appearance=0.9, stars_appearance=1.5, stars_dynamic=true, csp_lights_bounce=0.7, csp_lights_emissive=0.6 },
    [1] = { nlp_level=1.5, nlp_density=1.2, nlp_lowest_ambient=1.3, moon_light=1.5, moon_appearance=1.2, stars_appearance=1.3, stars_dynamic=true, csp_lights_bounce=1.3, csp_lights_emissive=1.4 },
    [2] = { nlp_level=1.1, nlp_density=1.05, nlp_lowest_ambient=0.95, moon_light=1.35, moon_appearance=1.25, stars_appearance=1.35, stars_dynamic=true, csp_lights_bounce=1.18, csp_lights_emissive=1.25 }, -- Improved Cinematic
    [3] = { nlp_level=0.9, nlp_density=1.1, nlp_lowest_ambient=0.5, moon_light=0.6, moon_appearance=0.6, stars_appearance=0.8, stars_dynamic=true, csp_lights_bounce=0.9, csp_lights_emissive=1.2, reflections_saturation=1.4, bloom_preset=4 }, -- Neon City
    [4] = { nlp_level=1.0, nlp_density=0.9, nlp_lowest_ambient=0.7, moon_light=0.9, moon_appearance=0.8, stars_appearance=1.0, stars_dynamic=true, csp_lights_bounce=1.1, csp_lights_emissive=1.25, reflections_saturation=1.1, bloom_preset=5, glare_star_luminance=0.7 }, -- Wet Night
}

-- ============================================================================
-- TONEMAPPING FUNCTION
-- ============================================================================


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
        local dyn_range_adjust = _l_Exposure_lut[1]^1.5
        local dyn_range_adjust_inv = 1-dyn_range_adjust
        local dyn_range_adjust_dark = _l_Exposure_lut[6]^2
        local dyn_range_adjust_dark_inv = 1-dyn_range_adjust_dark

        local uchimura__maxDisplayBrightness = -0.95 + 0.15*cam_sun_face
        local uchimura__contrast = math.lerp(0.7 + 0.20*_l_Exposure_lut[7], 1.4 - 0.6*(1-_l_Exposure_lut[3]), photo_realistic)
        local uchimura__linearSessionStart = math.lerp(-0.257, (interior and -0.275 or -0.265), photo_realistic^0.34)
        local uchimura__linearSectionLength = math.lerp(0.3, 0.3 - 0.1*dyn_range_adjust_dark - 0.3*dyn_range_adjust, photo_realistic)
        local uchimura__black = math.lerp(0.2 - 0.2*_l_Exposure_lut[7] + 0.07*cam_sun_face, 0.00 + 0.07*cam_sun_face, photo_realistic)
        local uchimura__gain = math.lerp(-0.325 - 0.08*cam_sun_face, -0.325 - 0.08*cam_sun_face - (interior and 0.2 or 0.2)*_l_Exposure_lut[7] + 0.3*(1-_l_Exposure_lut[3]), photo_realistic)

        if mode == 5 then
            pure.pp.setTonemapping(ac.TonemapFunction.Uchimura)
            pure.config.set("ppTonemapUchimura.maxDisplayBrightness", uchimura__maxDisplayBrightness, true)
            pure.config.set("ppTonemapUchimura.contrast", uchimura__contrast, true)
            pure.config.set("ppTonemapUchimura.linearSectionStart", uchimura__linearSessionStart, true)
            pure.config.set("ppTonemapUchimura.linearSectionLength", uchimura__linearSectionLength, true)
            pure.config.set("ppTonemapUchimura.black", uchimura__black, true)
            pure.config.set("ppTonemapUchimura.gain", uchimura__gain, true)
        else
            if mode == 7 then
                if _l_current_tonemapping ~= 7 then retro_intro_time = 0.0 end
                retro_intro_time = math.min(retro_intro_time + dt, retro_intro_duration)
                local intro_fac = 1.0 - (retro_intro_time / retro_intro_duration)

                -- Retrograde base values (distinct defaults)
                local base_P = 2.00 + uchimura__maxDisplayBrightness
                local base_a = 1.10 + uchimura__contrast
                local base_m = math.max(0.001, 0.18 + uchimura__linearSessionStart)
                local base_l = math.min(1-math.max(0, base_m), 0.42 + uchimura__linearSectionLength)
                local base_c = 1.00 + uchimura__black
                local base_b = 0.01
                local base_gain = 1.05 + uchimura__gain
                local base_agx_mix = 0.75
                local base_agx_mix_exp = 0.45
                local base_agx_slope = 1.10
                local base_agx_power = 1.80
                local base_agx_sat = 0.92

                -- Intro punches that decay over time
                local intro_P_add = 0.40
                local intro_a_add = 0.20
                local intro_agx_mix_add = 0.20
                local intro_agx_power_add = 0.60

                if _l_init then
                    -- During init, apply a stronger starting look (with intro factor)
                    tonemap__custom.values.P = base_P + intro_P_add * intro_fac
                    tonemap__custom.values.a = base_a + intro_a_add * intro_fac
                    tonemap__custom.values.m = base_m
                    tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                    tonemap__custom.values.l = base_l
                    tonemap__custom.values.c = base_c
                    tonemap__custom.values.b = base_b
                    tonemap__custom.values.gain = base_gain
                    tonemap__custom.values.agx_mix = base_agx_mix + intro_agx_mix_add * intro_fac
                    tonemap__custom.values.agx_mix_exp = base_agx_mix_exp
                    tonemap__custom.values.agx_slope = base_agx_slope
                    tonemap__custom.values.agx_power = base_agx_power + intro_agx_power_add * intro_fac
                    tonemap__custom.values.agx_sat = base_agx_sat
                else
                    -- When running, blend UI sliders toward Retrograde base to differentiate from Hyperchrome
                    local uiP = pure.script.ui.getValue("TONEMAPPING__maxDisplayBrightness")
                    local uiA = pure.script.ui.getValue("TONEMAPPING__contrast")
                    local uim = pure.script.ui.getValue("TONEMAPPING__linearSectionStart")
                    local uil = pure.script.ui.getValue("TONEMAPPING__linearSectionLength")
                    local uiC = pure.script.ui.getValue("TONEMAPPING__black")
                    local uiB = pure.script.ui.getValue("TONEMAPPING__pedestal")
                    local uiGain = pure.script.ui.getValue("TONEMAPPING__gain")

                    tonemap__custom.values.P = uiP + uchimura__maxDisplayBrightness
                    tonemap__custom.values.a = uiA + uchimura__contrast
                    tonemap__custom.values.m = math.max(0.001, uim + uchimura__linearSessionStart)
                    tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                    tonemap__custom.values.l = math.min(1-math.max(0, tonemap__custom.values.m), uil + uchimura__linearSectionLength)
                    tonemap__custom.values.c = uiC + uchimura__black
                    tonemap__custom.values.b = uiB
                    tonemap__custom.values.gain = uiGain + uchimura__gain

                    -- Bias AGX/contrast/gain toward Retrograde base and apply intro punches
                    tonemap__custom.values.agx_mix = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_mix"), base_agx_mix, 0.65) + intro_agx_mix_add * intro_fac
                    tonemap__custom.values.agx_mix_exp = pure.script.ui.getValue("TONEMAPPING__agx_mix_luma_exp")
                    tonemap__custom.values.agx_slope = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_slope"), base_agx_slope, 0.5)
                    tonemap__custom.values.agx_power = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_power") * 2.2, base_agx_power, 0.65) + intro_agx_power_add * intro_fac
                    tonemap__custom.values.agx_sat = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_sat"), base_agx_sat, 0.4)
                end
            else
                retro_intro_time = 0.0
                tonemap__custom.values.P = pure.script.ui.getValue("TONEMAPPING__maxDisplayBrightness") + uchimura__maxDisplayBrightness
                tonemap__custom.values.a = pure.script.ui.getValue("TONEMAPPING__contrast") + uchimura__contrast
                tonemap__custom.values.m = math.max(0.001, pure.script.ui.getValue("TONEMAPPING__linearSectionStart") + uchimura__linearSessionStart)
                tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                tonemap__custom.values.l = math.min(1-math.max(0, tonemap__custom.values.m), pure.script.ui.getValue("TONEMAPPING__linearSectionLength") + uchimura__linearSectionLength)
                tonemap__custom.values.c = pure.script.ui.getValue("TONEMAPPING__black") + uchimura__black
                tonemap__custom.values.b = pure.script.ui.getValue("TONEMAPPING__pedestal")
                tonemap__custom.values.gain = pure.script.ui.getValue("TONEMAPPING__gain") + uchimura__gain
                tonemap__custom.values.agx_mix = pure.script.ui.getValue("TONEMAPPING__agx_mix")
                tonemap__custom.values.agx_mix_exp = pure.script.ui.getValue("TONEMAPPING__agx_mix_luma_exp")
                tonemap__custom.values.agx_slope = pure.script.ui.getValue("TONEMAPPING__agx_slope")
                tonemap__custom.values.agx_power = pure.script.ui.getValue("TONEMAPPING__agx_power") * 2.2
                tonemap__custom.values.agx_sat = pure.script.ui.getValue("TONEMAPPING__agx_sat")
            end
            pure.pp.setCustomRGBTonemapping(tonemap__custom)
        end
    elseif mode == 8 then
        if not _l_init then
            tonemap__aces.values.exposure = pure.script.ui.getValue("TONEMAPPING__aces_exposure")
            pure.pp.setCustomRGBTonemapping(tonemap__aces)
        end
    elseif mode == 9 then
        local exp_mod = (1-_l_Exposure_lut[4])
        local exp_mod2 = (1-_l_Exposure_lut[6])^2
        pure.pp.setTonemapping(ac.TonemapFunction.Lottes)
        pure.config.set("ppTonemapLottes.contrast", 0.75, true)
        pure.config.set("ppTonemapLottes.gamma", math.lerp(-0.03, -0.03 - 0.05*exp_mod2, photo_realistic^0.50), true)
        pure.config.set("ppTonemapLottes.hdrMax", 0.1, true)
        pure.config.set("ppTonemapLottes.midIn", math.lerp(-0.25 + 0.04*exp_mod, -0.25 - 0.05*exp_mod2, photo_realistic^0.50), true)
        pure.config.set("ppTonemapLottes.midOut", -0.24 + 0.07*exp_mod, true)
        pure.config.set("ppTonemapLottes.gain", 0.05, true)
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

-- ============================================================================
-- UPDATE FUNCTION - APPLIES ALL SLIDER VALUES
-- ============================================================================

-- V1.5: bounded, time-based environment adaptation. Missing optional telemetry
-- falls back to dry conditions, never to invented road wetness from humidity.
local st6ix_weather = {}
local function st6ix_unit(v, fallback)
    if type(v) ~= "number" or v ~= v then return fallback or 0 end
    return math.max(0, math.min(1, v))
end
local function st6ix_sample(fn, fallback)
    local ok, value = pcall(fn)
    return st6ix_unit(ok and value or nil, fallback)
end
local function st6ix_smooth(key, target, dt, seconds)
    local previous = st6ix_weather[key]
    if previous == nil then previous = target end
    local step = type(dt) == "number" and dt == dt and math.max(0, math.min(dt, 0.25)) or 0
    local value = previous + (target - previous) * (1 - math.exp(-step / seconds))
    st6ix_weather[key] = value
    return value
end
local function st6ix_environment(dt)
    local e = {}
    e.cloud = st6ix_smooth("cloud", st6ix_sample(function() return pure.world.getCloudCoverage() end), dt, 3)
    e.humidity = st6ix_smooth("humidity", st6ix_sample(function() return pure.world.getHumidity() end), dt, 4)
    e.shadow = st6ix_smooth("shadow", st6ix_sample(function() return pure.world.getCloudShadow() end), dt, 1.5)
    e.fog = st6ix_smooth("fog", st6ix_sample(function() return pure.world.getFog() end), dt, 4)
    e.wet = st6ix_smooth("wet", st6ix_sample(function() return ac.getSim().rainWetness end), dt, 4)
    e.rain = st6ix_smooth("rain", st6ix_sample(function() return ac.getSim().rainIntensity end), dt, 3)
    e.day = st6ix_smooth("day", st6ix_sample(function() return pure.mod.sun(0) * 10 end), dt, 2)
    e.golden = st6ix_smooth("golden", st6ix_sample(function() return pure.mod.twilight(0) end), dt, 2) * e.day
    e.cockpit = st6ix_smooth("cockpit", interior and 1 or 0, dt, 0.35)
    return e
end

V15.update = function(dt)
    interior = ac.isInteriorView()
    photo_realistic = pure.script.ui.getValue("photo_realistic")

    local profile_index = math.floor(pure.script.ui.getValue("st6ix_profile"))
    local profile = ST6IX_PROFILES[profile_index] or ST6IX_PROFILES[3]
    local environment = st6ix_environment(dt)
    local realism = profile_index == 3 and 0 or st6ix_unit(pure.script.ui.getValue("weather_realism_v15"), 0.75)
    -- Copy before scaling: never mutate the preset table and compound per frame.
    if realism > 0 then
        local adjusted = {}
        for key, value in pairs(profile) do adjusted[key] = value end
        adjusted.bloom = profile.bloom * (1 + realism * (-0.10 * environment.day + 0.06 * environment.golden + 0.10 * environment.wet * (1 - environment.day)))
        adjusted.glare = profile.glare * (1 - 0.22 * realism * environment.cockpit)
        profile = adjusted
    end

    -- Preset overrides must be declared before either the day or night
    -- lighting blocks assign them. Declaring them later creates a separate
    -- local variable and silently discards the daytime override.
    local day_bloom_override
    local lighting_contrast_override, lighting_sharpness_override
    local night_bloom_override, night_refl_sat_override, night_glare_lum_override

    -- Helper: smooth morning/day and night compensation across twilight
    local function day_compensate(_)
        local sunpos = pure.mod.sun(0)
        if sunpos > 0.15 then return 1 end
        if sunpos < 0.10 then return 0 end
        return (sunpos - 0.10) / (0.05)
    end
    local function night_compensate(x)
        return 1 - day_compensate(x)
    end

    -- (preset handlers reverted)
    
    -- ========================================================================
    -- LIGHTING CONTROLS (with Preset Support) - Only apply during daytime
    -- ========================================================================
    local is_daytime = pure.mod.sun(0) > 0.1  -- Check if sun is above horizon
    local lighting_preset = math.floor(pure.script.ui.getValue("lighting_preset"))
    local daylight_multi, sun_level, sun_speculars, ambient_level, advanced_ambient, sky_level, ambient_v2_sun, csp_bounce, csp_emissive
    
    if lighting_preset == 3 and LIGHTING_PRESETS[3] then
        -- Always enforce Natural preset
        local p = LIGHTING_PRESETS[3]
        daylight_multi = p.daylight_multiplier
        sun_level = p.sun_level
        sun_speculars = p.sun_speculars
        ambient_level = p.ambient_level
        advanced_ambient = p.advanced_ambient_light
        sky_level = p.sky_level
        ambient_v2_sun = p.advanced_ambient_lightV2_sun
        csp_bounce = p.csp_lights_bounce
        csp_emissive = p.csp_lights_emissive
    elseif LIGHTING_PRESETS[lighting_preset] then
        -- Apply other presets only during daytime
        local p = LIGHTING_PRESETS[lighting_preset]
        daylight_multi = p.daylight_multiplier
        sun_level = p.sun_level
        sun_speculars = p.sun_speculars
        ambient_level = p.ambient_level
        advanced_ambient = p.advanced_ambient_light
        sky_level = p.sky_level
        ambient_v2_sun = p.advanced_ambient_lightV2_sun
        csp_bounce = p.csp_lights_bounce
        csp_emissive = p.csp_lights_emissive
    else
        -- Manual mode - use slider values
        daylight_multi = pure.script.ui.getValue("daylight_multiplier")
        sun_level = pure.script.ui.getValue("sun_level")
        sun_speculars = pure.script.ui.getValue("sun_speculars")
        ambient_level = pure.script.ui.getValue("ambient_level")
        advanced_ambient = pure.script.ui.getValue("advanced_ambient_light")
        sky_level = pure.script.ui.getValue("sky_level")
        ambient_v2_sun = pure.script.ui.getValue("advanced_ambient_lightV2_sun")
        csp_bounce = pure.script.ui.getValue("csp_lights_bounce")
        csp_emissive = pure.script.ui.getValue("csp_lights_emissive")
    end
    SIGNALS.v15SkyLevel = sky_level
    
    -- Small trims complement Pure's own weather lighting; no exposure changes.
    if realism > 0 and LIGHTING_PRESETS[lighting_preset] then
        sun_speculars = sun_speculars * (1 - 0.08 * realism * environment.cloud)
        ambient_level = ambient_level * (1 + 0.025 * realism * environment.cloud)
    end
    -- Only apply daylight settings when sun is up
    if is_daytime then
        pure.config.set("light.daylight_multiplier", daylight_multi, true)
        pure.config.set("light.sun.level", sun_level, true)
        pure.config.set("light.sun.speculars", sun_speculars, true)
        pure.config.set("light.ambient.level", ambient_level, true)
        pure.config.set("light.advanced_ambient_light", advanced_ambient, true)
        -- Sky level and cloud brightness are owned by the Sky & Weather block
        -- below, preventing these lighting values from being overwritten later.
        pure.config.set("light.advanced_ambient_lightV2_sun", ambient_v2_sun, true)
        pure.config.set("csp_lights.bounce", csp_bounce, true)
        pure.config.set("csp_lights.emissive", csp_emissive, true)

        -- Lighting preset specific post-processing overrides (contrast/sharpness/bloom)
        if LIGHTING_PRESETS[lighting_preset] then
            local lp = LIGHTING_PRESETS[lighting_preset]
            -- Apply finishing overrides once in the final HDR/clarity block.
            lighting_contrast_override = lp.pp_contrast
            lighting_sharpness_override = lp.pp_sharpness
            -- Respect user toggle: only allow lighting presets to override Bloom/Glare if enabled
            if pure.script.ui.getValue("lighting_affects_bloom") then
                day_bloom_override = lp.bloom_preset
            else
                day_bloom_override = nil
            end
        end
    end
    
    -- Nightlight settings (with Preset Support) - Only apply at night
    local is_night = pure.mod.sun(0) < 0.1  -- Check if sun is below horizon
    local night_preset = math.floor(pure.script.ui.getValue("night_preset"))
    local nlp_level, nlp_density, nlp_lowest_ambient, moon_light, moon_appearance, stars_appearance, stars_dynamic
    
    local night_csp_lights_bounce, night_csp_lights_emissive

    if night_preset == 2 and NIGHT_PRESETS[2] then
        -- Always enforce Cinematic night preset
        local p = NIGHT_PRESETS[2]
        nlp_level = p.nlp_level
        nlp_density = p.nlp_density
        nlp_lowest_ambient = p.nlp_lowest_ambient
        moon_light = p.moon_light
        moon_appearance = p.moon_appearance
        stars_appearance = p.stars_appearance
        stars_dynamic = p.stars_dynamic
        night_csp_lights_bounce = p.csp_lights_bounce
        night_csp_lights_emissive = p.csp_lights_emissive
    elseif NIGHT_PRESETS[night_preset] then
        -- Apply other presets only at night
        local p = NIGHT_PRESETS[night_preset]
        nlp_level = p.nlp_level
        nlp_density = p.nlp_density
        nlp_lowest_ambient = p.nlp_lowest_ambient
        moon_light = p.moon_light
        moon_appearance = p.moon_appearance
        stars_appearance = p.stars_appearance
        stars_dynamic = p.stars_dynamic
        night_csp_lights_bounce = p.csp_lights_bounce
        night_csp_lights_emissive = p.csp_lights_emissive
    else
        -- Manual mode (index 5 or not found) - use slider values
        nlp_level = pure.script.ui.getValue("nlp_level")
        nlp_density = pure.script.ui.getValue("nlp_density")
        nlp_lowest_ambient = pure.script.ui.getValue("nlp_lowest_ambient")
        moon_light = pure.script.ui.getValue("moon_light")
        moon_appearance = pure.script.ui.getValue("moon_appearance")
        stars_appearance = pure.script.ui.getValue("stars_appearance")
        stars_dynamic = pure.script.ui.getValue("stars_dynamic_adaption")
        night_csp_lights_bounce = pure.script.ui.getValue("night_csp_lights_bounce")
        night_csp_lights_emissive = pure.script.ui.getValue("night_csp_lights_emissive")
    end
    
    -- Apply stars settings always (Pure handles day/night visibility automatically)
    pure.config.set("stars.appearance", stars_appearance, true)
    pure.config.set("stars.dynamic_adaption", stars_dynamic and 1 or 0, true)
    
    -- Only apply night-specific presets when sun is down (nlp/csp)
    if is_night then
        pure.config.set("nlp.level", nlp_level, true)
        pure.config.set("nlp.density", nlp_density, true)
        pure.config.set("nlp.lowest_ambient", nlp_lowest_ambient, true)
        pure.config.set("csp_lights.bounce", night_csp_lights_bounce, true)
        pure.config.set("csp_lights.emissive", night_csp_lights_emissive, true)
    end

    -- Moon settings: ramp in/out smoothly during twilight so they visibly take effect over frames
    local _sun_pos_for_moon = pure.mod.sun(0)
    local _moon_factor = 0
    if _sun_pos_for_moon < 0.1 then
        _moon_factor = 1
    elseif _sun_pos_for_moon > 0.15 then
        _moon_factor = 0
    else
        local _blend2 = (_sun_pos_for_moon - 0.1) / 0.05 -- 0 at night, 1 at day
        _moon_factor = math.max(0, math.min(1, 1 - _blend2))
    end
    local _moon_light_set = (moon_light or 0) * _moon_factor
    local _moon_appearance_set = math.lerp(1.0, (moon_appearance or 1.0), _moon_factor)
    pure.config.set("moon.light", _moon_light_set, true)
    pure.config.set("moon.appearance", _moon_appearance_set, true)

    -- Night preset specific overrides (bloom/reflection/etc.)
    if is_night and NIGHT_PRESETS[night_preset] then
        local np = NIGHT_PRESETS[night_preset]
        -- Respect user toggle: only allow night presets to override Bloom/Glare if enabled
        if pure.script.ui.getValue("lighting_affects_bloom") then
            night_bloom_override = np.bloom_preset
            night_glare_lum_override = np.glare_star_luminance
        else
            night_bloom_override = nil
            night_glare_lum_override = nil
        end
        night_refl_sat_override = np.reflections_saturation
    end
    
    -- ========================================================================
    -- REFLECTIONS (with Preset Support)
    -- ========================================================================
    local reflections_preset = math.floor(pure.script.ui.getValue("reflections_preset"))
    local refl_sat, refl_level, refl_emissive, vao_amount, fog_gain_val
    
    if REFLECTIONS_PRESETS[reflections_preset] then
        -- Apply preset values every frame
        local p = REFLECTIONS_PRESETS[reflections_preset]
        refl_sat = p.reflections_saturation
        refl_level = p.reflections_level
        refl_emissive = p.reflections_emissive_boost
        vao_amount = p.vao_amount
        fog_gain_val = p.groundfog_gain
    else
        -- Manual mode - use slider values
        refl_sat = pure.script.ui.getValue("reflections_saturation")
        refl_level = pure.script.ui.getValue("reflections_level")
        refl_emissive = pure.script.ui.getValue("reflections_emissive_boost")
        vao_amount = pure.script.ui.getValue("vao_amount")
        fog_gain_val = pure.script.ui.getValue("groundfog_gain")
    end

    -- Night preset can override reflections saturation
    if is_night and night_refl_sat_override then
        refl_sat = night_refl_sat_override
    end

    if realism > 0 and REFLECTIONS_PRESETS[reflections_preset] then
        refl_level = refl_level * (1 + realism * (0.12 * environment.wet - 0.04 * environment.day * (1 - environment.wet)))
        refl_emissive = refl_emissive * (1 + realism * (-0.18 * environment.day + 0.12 * environment.wet * (1 - environment.day)))
        refl_sat = 1 + (refl_sat - 1) * (1 - 0.35 * realism)
    end
    pure.config.set("reflections.saturation", refl_sat, true)
    pure.config.set("reflections.level", refl_level, true)
    pure.config.set("reflections.emissive_boost", refl_emissive, true)
    pure.config.set("vao.amount", vao_amount, true)
    
    -- ========================================================================
    -- GROUND FOG (UI hidden but fog remains active)
    -- ========================================================================
    local fog_active = math.floor(pure.script.ui.getValue("FOG Type")) ~= 0
    local fog_quality = 4    -- Default quality
    local fog_size = 0.5     -- Reduced size for less aggressive fog
    local fog_scale = 0.6    -- Reduced scale
    local fog_structure = 0.8 -- Slightly reduced structure
    local fog_gain = fog_gain_val  -- From Reflections preset/slider
    if realism > 0 then
        local moisture = math.max(environment.fog, environment.rain, math.max(0, (environment.humidity - 0.65) / 0.35))
        fog_gain = fog_gain * (1 + realism * (0.30 + 0.70 * moisture - 1))
    end
    local fog_nearby = 1.5   -- Increased fadeout near camera
    local fog_sun = 0.005    -- Reduced sun influence
    local fog_render_dist = 1.5 -- Reduced render distance
    local fog_car_turb = true   -- Default car turbulences
    
    pure.config.set("shaders.groundfog.active", fog_active and 1 or 0, true)
    pure.config.set("shaders.groundfog.Quality", fog_quality, true)
    pure.config.set("shaders.groundfog.Size", fog_size, true)
    pure.config.set("shaders.groundfog.Scale", fog_scale, true)
    pure.config.set("shaders.groundfog.Structure", fog_structure, true)
    pure.config.set("shaders.groundfog.Gain", fog_gain, true)
    pure.config.set("shaders.groundfog.Nearby_fadeout", fog_nearby, true)
    pure.config.set("shaders.groundfog.Sun_influence", fog_sun, true)
    pure.config.set("shaders.groundfog.Render_distance", fog_render_dist, true)
    pure.config.set("shaders.groundfog.Car_turbulences", fog_car_turb and 1 or 0, true)
    
    -- ========================================================================
    -- SUN BLINDING (matches SDK screenshot)
    -- ========================================================================
    local sun_blind_active = pure.script.ui.getValue("sunblinding_active")
    local sun_blind_sensitivity = pure.script.ui.getValue("sunblinding_sensitivity")
    local sun_blind_time_up = pure.script.ui.getValue("sunblinding_time_up")
    local sun_blind_time_down = pure.script.ui.getValue("sunblinding_time_down")
    local sun_blind_cover = pure.script.ui.getValue("sunblinding_cover")
    local sun_blind_blinding = pure.script.ui.getValue("sunblinding_blinding")
    local sun_blind_iris = pure.script.ui.getValue("sunblinding_iris")
    local sun_star_opacity = pure.script.ui.getValue("sunblinding_star_opacity")
    local sun_star_size = pure.script.ui.getValue("sunblinding_star_size")
    local sun_star_blur = pure.script.ui.getValue("sunblinding_star_blur")
    
    if pure.shader.isRunning("sunblinding") then
        pure.config.set("shaders.sunblinding.active", sun_blind_active and 1 or 0, true)
        pure.config.set("shaders.sunblinding.sensitivity", sun_blind_sensitivity, true)
        pure.config.set("shaders.sunblinding.time_up", sun_blind_time_up, true)
        pure.config.set("shaders.sunblinding.time_down", sun_blind_time_down, true)
        pure.config.set("shaders.sunblinding.cover", sun_blind_cover, true)
        pure.config.set("shaders.sunblinding.blinding", sun_blind_blinding, true)
        pure.config.set("shaders.sunblinding.iris", sun_blind_iris, true)
        pure.config.set("shaders.sunblinding.star_opacity", sun_star_opacity, true)
        pure.config.set("shaders.sunblinding.star_size", sun_star_size, true)
        pure.config.set("shaders.sunblinding.star_blur", sun_star_blur, true)
        
        cam_sun_face = pure.utils.CamFacesSun() * pure.script.ui.getValue("sun_blinding") * 0.6666667
    else
        cam_sun_face = 0
    end
    
    -- ========================================================================
    -- SKY & SUN/MOON (with Preset Support)
    -- ========================================================================
    local sky_preset = math.floor(pure.script.ui.getValue("sky_preset"))
    local sky_light, sun_moon, day_clouds_bright, day_clouds_contrast, night_clouds_bright, night_clouds_contrast
    local day_sky_level, dusk_sky_level, day_sky_sat
    
    if SKY_PRESETS[sky_preset] then
        -- Apply preset values every frame
        local p = SKY_PRESETS[sky_preset]
        if p.day and p.night then
            -- New day/night structured presets
            sky_light = p.day.sky_light_level or p.day.sky_level or 1.0
            -- Support distinct day/night sun/moon size values and fall back to day when missing
            day_sun_moon = p.day["sun.sun_moon_size"] or p.day.sun_moon_size or p.day.sun_moon or 1.0
            night_sun_moon = p.night["sun.sun_moon_size"] or p.night.sun_moon_size or p.night.sun_moon or day_sun_moon
            day_clouds_bright = p.day.clouds_brightness
            day_clouds_contrast = p.day.clouds_contrast
            night_clouds_bright = p.night.clouds_brightness
            night_clouds_contrast = p.night.clouds_contrast
            day_sky_level = p.day.sky_level
            dusk_sky_level = p.duskdawn_sky_level
            day_sky_sat = p.day.sky_saturation
        else
            -- Backwards-compatible legacy fields
            sky_light = p.sky_light_level
            -- Legacy presets only have a single sun_moon value; use it for both day and night
            day_sun_moon = p["sun.sun_moon_size"] or p.sun_moon_size or p.sun_moon or 1.0
            night_sun_moon = day_sun_moon
            day_clouds_bright = p.daytime_clouds_brightness
            day_clouds_contrast = p.daytime_clouds_contrast
            night_clouds_bright = p.nighttime_clouds_brightness
            night_clouds_contrast = p.nighttime_clouds_contrast
            day_sky_level = p.daytime_sky_level
            dusk_sky_level = p.duskdawn_sky_level
            day_sky_sat = p.daytime_sky_saturation
        end
    else
        -- Manual mode - use slider values
        sky_light = pure.script.ui.getValue("sky_light_level")

        -- Two-way binding between UI slider and engine config 'sun.sun_moon_size':
        -- * If engine config exists/changes, update UI and use it
        -- * If user changes UI, write back to engine config
        local cfg_sun_moon = pure.config.get("sun.sun_moon_size") or 0
        local ui_sun_moon = pure.script.ui.getValue("sun.sun_moon_size")

        -- Detect external config change -> prefer config and update UI
        if cfg_sun_moon > 0 and (_last_cfg_sun_moon == nil or cfg_sun_moon ~= _last_cfg_sun_moon) then
            day_sun_moon = cfg_sun_moon
            night_sun_moon = cfg_sun_moon
            if pure.script.ui.setValue then pure.script.ui.setValue("sun.sun_moon_size", cfg_sun_moon) end
            _last_cfg_sun_moon = cfg_sun_moon
            _last_ui_sun_moon = cfg_sun_moon
        -- Detect UI change by user -> write to config and use it
        elseif ui_sun_moon ~= _last_ui_sun_moon then
            day_sun_moon = ui_sun_moon
            night_sun_moon = ui_sun_moon
            pure.config.set("sun.sun_moon_size", ui_sun_moon, true)
            _last_ui_sun_moon = ui_sun_moon
            _last_cfg_sun_moon = ui_sun_moon
        else
            -- Stable state: prefer config when present, otherwise UI
            if cfg_sun_moon and cfg_sun_moon > 0 then
                day_sun_moon = cfg_sun_moon
                night_sun_moon = cfg_sun_moon
            else
                day_sun_moon = ui_sun_moon
                night_sun_moon = ui_sun_moon
            end
        end

        day_clouds_bright = pure.script.ui.getValue("Daytime Clouds Brightness")
        day_clouds_contrast = pure.script.ui.getValue("Daytime Clouds Contrast")
        night_clouds_bright = pure.script.ui.getValue("Nighttime Clouds Brightness")
        night_clouds_contrast = pure.script.ui.getValue("Nighttime Clouds Contrast")
        day_sky_level = pure.script.ui.getValue("Daytime Sky Level")
            * pure.script.ui.getValue("sky_light_level") / 1.125
        dusk_sky_level = pure.script.ui.getValue("Duskdawn Sky Level")
        day_sky_sat = pure.script.ui.getValue("Daytime Sky Saturation")
    end
    
    -- Apply sky settings (non-cloud related). Use one authoritative level so a
    -- second write cannot silently cancel the first one.
    -- Smoothly interpolate sun/moon size between day and night across twilight for frame-accurate changes
    local _sun_pos_for_size = pure.mod.sun(0)
    local _sun_size = day_sun_moon or 1.0
    local _night_size = night_sun_moon or _sun_size
    if _sun_pos_for_size > 0.15 then
        _sun_size = day_sun_moon
    elseif _sun_pos_for_size < 0.1 then
        _sun_size = _night_size
    else
        local _blend = (_sun_pos_for_size - 0.1) / 0.05 -- 0 at night, 1 at day
        _sun_size = math.lerp(_night_size, day_sun_moon, _blend)
    end
    pure.config.set("sun.size", _sun_size, true)
    pure.config.set("light.sky.level", day_sky_level or sky_light or 1.0, true)
    pure.config.set("light.sky.dusk_dawn_level", dusk_sky_level, true)
    pure.config.set("light.sky.day_saturation", day_sky_sat, true)

    -- Sunset sun saturation: peaks at twilight, falls back to 1.0 at midday and night
    local _sunset_tw = math.max(0, 1.0 - pure.mod.dayCurve(1, 0, 1) - pure.mod.nightCurve(1, 0, 1))
    local _sunset_sun_sat_target = pure.script.ui.getValue("sunset_sun_sat")
    local _sunset_sun_sat = math.lerp(1.0, _sunset_sun_sat_target, _sunset_tw)
    pure.config.set("light.sun.saturation", _sunset_sun_sat, true)
    
    -- Apply cloud settings based on time of day
    local sun_pos = pure.mod.sun(0)
    local is_day_clouds = sun_pos > 0.15  -- Daytime threshold
    local is_night_clouds = sun_pos < 0.1  -- Nighttime threshold
    local is_transition = not is_day_clouds and not is_night_clouds  -- Twilight
    
    if is_day_clouds then
        -- Apply daytime cloud settings
        pure.config.set("clouds2D.brightness", day_clouds_bright, true)
        pure.config.set("clouds2D.contrast", day_clouds_contrast, true)
    elseif is_night_clouds then
        -- Apply nighttime cloud settings
        pure.config.set("clouds2D.brightness", night_clouds_bright, true)
        pure.config.set("clouds2D.contrast", night_clouds_contrast, true)
    else
        -- Twilight transition - blend between day and night
        local blend = (sun_pos - 0.1) / 0.05  -- 0 at night, 1 at day
        local blended_bright = math.lerp(night_clouds_bright, day_clouds_bright, blend)
        local blended_contrast = math.lerp(night_clouds_contrast, day_clouds_contrast, blend)
        pure.config.set("clouds2D.brightness", blended_bright, true)
        pure.config.set("clouds2D.contrast", blended_contrast, true)
    end
    
    -- (unified preset handler and duplicate binary helpers reverted)

    local exposure_ok, exposure_err = true, nil
    if math.floor(pure.script.ui.getValue("exposure_mode")) == 1 then
        exposure_ok, exposure_err = pcall(function()
        local AETargetDay = pure.script.ui.getValue("AE Day Target")*day_compensate(0)
        local AETargetNight = pure.script.ui.getValue("AE Night Target")*night_compensate(0)

        local AETargetDayInterior = pure.script.ui.getValue("AE Interior Day Target")*day_compensate(0)
        local AETargetNightInterior = pure.script.ui.getValue("AE Interior Night Target")*night_compensate(0)

        local DaySensitivity = 1* pure.script.ui.getValue("Day Exposure Sensitivity")*day_compensate(0)
        local NightSensitivity = 1* pure.script.ui.getValue("Night Exposure Sensitivity")*night_compensate(0)

        local AESensitivity = (DaySensitivity)+(NightSensitivity)

        local yebisDay = 1
        local yebisNight = 0.5

        local yebisDayInterior = 1
        local yebisNightInterior = 0.5

        local yebisTarget = (yebisDay)+(yebisNight)
        local yebisInteriorTarget = (yebisDayInterior)+(yebisNightInterior)

        local dayMix = pure.script.ui.getValue("Day AE Mix")
        local nightMix = pure.script.ui.getValue("Night AE Mix")

        local finalAEMix = (day_compensate(0) * dayMix) + (night_compensate(0) * nightMix)

        local AEFinal = math.lerp(pure.exposure.getValue(), 0.015, 0.050)

        --exposure presets--
        local TunnelBlinding = 1
        local FlashPreset = pure.script.ui.getValue("Tunnel Blinding Presets")
        local BlindingStrength = pure.script.ui.getValue("Tunnel Blinding Strength")
        -- derive TunnelBlinding using ST6IX occlusion LUT if available, else keep 1
        local oc = pure.camera.getOcclusion()
        if FlashPreset == 0 then
            TunnelBlinding = math.lerp(2* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.55, 0.775))
        elseif FlashPreset == 1 then
            TunnelBlinding = math.lerp(3* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.575, 0.75))
        else
            TunnelBlinding = math.lerp(1* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.575, 0.75))
        end

        if pure.exposure and pure.exposure.cbe and pure.exposure.yebis then
            pure.exposure.cbe.setTarget((AETargetDay*TunnelBlinding)+(AETargetNight))
            pure.exposure.cbe.setSensitivity(AESensitivity)
            pure.exposure.cbe.setLimits((0.025 + 0.05),(5 + 5))
            pure.exposure.cbe.setAdaptionSpeeds(20, 4)
            pure.exposure.yebis.setTarget(yebisTarget)
            pure.exposure.yebis.setLimits(0.15, 0.75)
            pure.exposure.yebis.setAdaptionSpeeds(50, 15)
            pure.exposure.setCBEMix(finalAEMix)
            pure.exposure.setBypass(math.lerp(
                AEFinal,
                (pure.script.ui.getValue("Day Target Exposure") * day_compensate(0) +
                 pure.script.ui.getValue("Night Target Exposure") * night_compensate(0)),
                pure.mod.day(0) + pure.mod.night(0)
            ), finalAEMix)
        end

        -- Interior exposure uses the same locally calculated values. Keeping
        -- this block inside the pcall prevents nil-variable failures when
        -- switching to cockpit view.
        if ac.isInteriorView() == true and pure.exposure and pure.exposure.cbe and pure.exposure.yebis then
            pure.exposure.cbe.setTarget((AETargetDayInterior*TunnelBlinding)+(AETargetNightInterior))
            pure.exposure.cbe.setSensitivity(AESensitivity)
            pure.exposure.cbe.setLimits((0.025 + 0.05),(5 + 5))
            pure.exposure.cbe.setAdaptionSpeeds(20, 4)
            pure.exposure.yebis.setTarget(yebisInteriorTarget)
            pure.exposure.yebis.setLimits(0.15, 0.75)
            pure.exposure.yebis.setAdaptionSpeeds(50, 15)
            pure.exposure.setCBEMix(finalAEMix)
            pure.exposure.setBypass(math.lerp(
                AEFinal,
                (pure.script.ui.getValue("Day Interior Exposure") * day_compensate(0) +
                 pure.script.ui.getValue("Night Interior Exposure") * night_compensate(0)),
                pure.mod.day(0) + pure.mod.night(0)
            ), finalAEMix)
        end

        -- Update readout state floats so the UI shows live values
        if pure.script.ui.setValue then
            -- Final exposure from Pure's exposure system
            pcall(function()
                if pure.exposure and pure.exposure.getValue then
                    pure.script.ui.setValue("Final Exposure", pure.exposure.getValue())
                end
            end)
            -- Occlusion (tunnel) value
            pcall(function()
                pure.script.ui.setValue("Occlusion", pure.camera.getOcclusion())
            end)
        end
        end)
    end

    if not exposure_ok then
        local error_text = tostring(exposure_err)
        if error_text ~= _last_exposure_error then
            ac.log("ST6IX V1.3 exposure: " .. error_text)
            _last_exposure_error = error_text
        end
    else
        _last_exposure_error = nil
    end
    
    -- ========================================================================
    -- BLOOM CONTROLS (with Preset Support)
    -- ========================================================================
    local function bounded(x, lo, hi) return math.max(lo, math.min(hi, x)) end
    local function knob(key, default)
        local x = pure.script.ui.getValue(key)
        return type(x) == "number" and x == x and x or default
    end
    local bloom_preset_ui = bounded(math.floor(knob("ini_eye_preset_v2", 0)), 0, 8)
    local bloom_preset = bloom_preset_ui
    if bloom_preset_ui ~= 8 then
        if is_night and night_bloom_override then bloom_preset = night_bloom_override end
        if not is_night and day_bloom_override then bloom_preset = day_bloom_override end
    end
    local p = BLOOM_PRESETS[bloom_preset] or {
        bloom_intensity=0.34, bloom_threshold=0.46, bloom_filter=0.001,
        bloom_radius=0.46, bloom_levels=4, bloom_gamma=1.02
    }
    local bloom_enabled = pure.script.ui.getValue("ini_eye_bloom_enabled_v2") == true
    local glare_enabled = pure.script.ui.getValue("ini_eye_glare_enabled_v2") == true
    local bloom_int = p.bloom_intensity * bounded(knob("ini_eye_bloom_strength_v2", 1), 0, 2)
    if not bloom_enabled then bloom_int = 0 end
    local bloom_thresh = bounded(p.bloom_threshold + bounded(knob("ini_eye_bloom_threshold_v2", 0), -0.18, 0.20), 0.20, 0.80)
    local bloom_filter = bounded(p.bloom_filter or 0.001, 0.0001, 0.005)
    local bloom_rad = bounded(p.bloom_radius * bounded(knob("ini_eye_bloom_radius_v2", 1), 0.45, 1.60), 0.12, 0.90)
    local bloom_levels = bounded(math.floor(p.bloom_levels + bounded(knob("ini_eye_bloom_levels_v2", 0), -2, 2) + 0.5), 2, 6)
    local bloom_gamma = bounded(p.bloom_gamma * knob("ini_eye_bloom_gamma_v2", 1), 0.85, 1.20)

    -- Keep only a subtle camera difference. The old profile stack reduced
    -- Drive-mode bloom to roughly 49%, hiding slider changes against this INI.
    local camera_bloom = interior and 0.82 or 1.0
    local bloom_output = bloom_int * camera_bloom

    -- Direct glare values are not multiplied by profile or weather strength.
    local star_len = bounded(knob("ini_eye_glare_length_v2", 0.07), 0, 0.30)
    local star_lum = bounded(knob("ini_eye_glare_brightness_v2", 0.12), 0, 0.60)
    local star_streaks = bounded(math.floor(knob("ini_eye_glare_streaks_v2", 4) + 0.5), 2, 8)
    local star_threshold_ui = bounded(knob("ini_eye_glare_threshold_v2", 0.42), 0.10, 0.80)
    local star_filter = 0.0001 + star_threshold_ui * 0.0030
    local star_softness = bounded(knob("ini_eye_glare_softness_v2", 0.80), 0.20, 1.50)
    if not glare_enabled or star_len == 0 then star_lum = 0 end

    -- Every runtime property is isolated. A CSP/Pure build rejecting one
    -- optional property must never stop the rest of bloom, glare or tonemapping.
    local function safe_yebis(key, value)
        if st6ix_bloom_field_errors[key] then return end
        local ok, err = pcall(pure.yebis.set, key, value)
        if not ok then
            st6ix_bloom_field_errors[key] = true
            pcall(function() ac.log("ST6IX bloom/glare optional field " .. key .. ": " .. tostring(err)) end)
        end
    end
    safe_yebis("glareEnabled", bloom_output > 0 or star_lum > 0)
    safe_yebis("glareUseCustomShape", true)
    safe_yebis("glareLuminance", 1.0)
    safe_yebis("glareShapeLuminance", 1.0)
    safe_yebis("glareThreshold", math.min(bloom_thresh, star_threshold_ui))
    safe_yebis("glareBloomLevels", bloom_levels)
    safe_yebis("glareShapeBloomLuminance", bloom_output)
    safe_yebis("glareBloomLuminanceGamma", bloom_gamma)
    safe_yebis("glareBloomFilterThreshold", bloom_filter)
    safe_yebis("glareBloomGaussianRadiusScale", bloom_rad)
    safe_yebis("glareShapeStarLength", star_len)
    safe_yebis("glareShapeStarLuminance", star_lum)
    safe_yebis("glareShapeStarStreaksNumber", star_streaks)
    safe_yebis("glareStarFilterThreshold", star_filter)
    safe_yebis("glareStarSoftness", star_softness)
    safe_yebis("glareStarLengthFOVDependence", 0)
    safe_yebis("glareGenerationRangeScale", 0.07)
    safe_yebis("glareBlur", 0.8)
    safe_yebis("glareShapeStarSecondaryLength", 0)
    safe_yebis("glareShapeStarDispersion", 0)
    safe_yebis("glareShapeStarForceDispersion", false)
    safe_yebis("glareShapeBloomDispersion", 0)
    safe_yebis("glareShapeBloomDispersionBaseLevel", 0)
    safe_yebis("glareShapeGhostLuminance", 0)
    safe_yebis("glareShapeGhostHaloLuminance", 0)
    safe_yebis("glareShapeAfterimageLuminance", 0)

    -- Apply tonemapping immediately after the confirmed-working bloom block.
    -- The old call was near the end of update_pure_script(), so any unrelated
    -- error in fog, skydomes or finishing effects prevented it from running.
    local active_tonemap = math.floor(pure.script.ui.getValue("Tonemapping") or 2)
    set_tonemapping(dt, active_tonemap)

    pcall(function()
        pure.script.ui.setValue("Status: Script OK", 1)
        pure.script.ui.setValue("Status: Tonemap", active_tonemap)
        pure.script.ui.setValue("Status: Bloom", bloom_preset)
        pure.script.ui.setValue("Status: Wetness", environment.wet)
        pure.script.ui.setValue("Status: Rain", environment.rain)
        pure.script.ui.setValue("Status: Weather Adaptation", realism)
        pure.script.ui.setValue("Status: Exposure Mode", math.floor(pure.script.ui.getValue("exposure_mode") or 0))
        pure.script.ui.setValue("Status: Exposure", pure.exposure.getValue())
        pure.script.ui.setValue("Status: Interior", interior and 1 or 0)
    end)

    -- ========================================================================
    -- GOD RAYS (controlled only by length; active when length > 0)
    -- ========================================================================
    local godray_len = pure.script.ui.getValue("godray_length")
    -- These compatibility keys only need rewriting when the slider changes.
    if _last_godray_length ~= godray_len then
        local godray_intensity = math.min(2.0, math.max(0.0, godray_len / 10.0))
        local godray_active = (godray_len > 0) and 1 or 0

        -- Primary keys
        pure.config.set("godrays.active", godray_active, true)
        pure.config.set("godrays.length", godray_len, true)
        pure.config.set("godrays.intensity", godray_intensity, true)

        -- Compatibility namespaces for older Pure/CSP builds.
        pure.config.set("shaders.godrays.active", godray_active, true)
        pure.config.set("shaders.godrays.length", godray_len, true)
        pure.config.set("shaders.godrays.intensity", godray_intensity, true)

        pure.config.set("shaders.sunrays.active", godray_active, true)
        pure.config.set("shaders.sunrays.length", godray_len, true)
        pure.config.set("shaders.sunrays.intensity", godray_intensity, true)

        pure.config.set("pp.godrays.length", godray_len, true)
        pure.config.set("pp.godrays.intensity", godray_intensity, true)
        _last_godray_length = godray_len
    end
    
    -- ========================================================================
    -- SCENE ANALYSIS & EXPOSURE
    -- ========================================================================
    occlusion = pure.camera.getOcclusion()
    cloud_shadow = pure.world.getCloudShadow() * occlusion
    cloud_shadow_sun = cloud_shadow * pure.mod.sun(0)
    cloud_shadow_twilight = cloud_shadow * pure.mod.twilight(0)
    badness = math.pow(pure.world.getBadness() * pure.mod.twilight(0) * occlusion, 1.5)
    fog = math.smootherstep(pure.world.getFog()) * pure.mod.twilight(0) * occlusion
    fog_gain = fog_gain or 1.053
    fog = fog * fog * fog_gain
    
    local exp = pure.exposure.getValue()
    _l_Exposure_lut = _l_ExposureCPP:get(exp)
    
    -- ========================================================================
    -- ADVANCED FOG SYSTEM 
    -- ========================================================================
    
    -- Update daycurvefog
    daycurvefog = pure.mod.dayCurve(1.0, 1.06, 0.6)
    
    -- Calculate fog thickness with day/night compensation (uses helpers defined earlier)
    
    local fog_thickness_value = pure.script.ui.getValue("Fog Thickness")
    local Fogthickness = (fog_thickness_value * 0.75 * day_compensate(0) + 
                          (fog_thickness_value * 1.14) * night_compensate(0))
    
    Fogthickness = (Fogthickness - (Fogthickness * 0.45 * night_compensate(0))) + 
                   ((0.25 * Fogthickness) * pure.world.getCloudCoverage())
    
    -- Get fog data
    local worldfogget = __PURE__world__fog_get()
    local basecolor = worldfogget.color
    local RGBcolorfog = rgb_fog
    local ambientcolor = Pure_getColor(COLORS.AMBIENT)
    
    local skycolor = ambientcolor * 0.65
    local fogtyper = -(0.5 * badness)
    local mixermult = pure.script.ui.getValue("Fog Color mixer") * pure.mod.dayCurve(4, 1, 1)
    local colorblend = pure.mod.dayCurve(
        mixermult * day_compensate(0) + (mixermult * night_compensate(0)) - 1.2,
        mixermult * day_compensate(0) + (mixermult * 2 * night_compensate(0)),
        0.67
    )
    
    fogtype = math.floor(pure.script.ui.getValue("FOG Type"))
    local fog_amount_value = pure.script.ui.getValue("Fog amount")
    if realism > 0 then
        local moisture = math.max(environment.fog, environment.rain, math.max(0, (environment.humidity - 0.65) / 0.35))
        local factor = 0.25 + 0.65 * moisture + 0.10 * environment.cloud
        fog_amount_value = fog_amount_value * (1 + realism * (factor - 1))
        Fogthickness = Fogthickness * (1 + realism * (factor - 1))
    end
    
    if fogtype == 0 then
        -- None mode: reset every property changed by the other presets so no
        -- stale fog survives after switching modes.
        fogdensity = 0
        fogsat = 1
        ac.setFogBacklitMultiplier(0)
        st6ix_weather.fog_density = 0
        st6ix_weather.fog_blend = 0
        ac.setFogDensity(0)
        ac.setFogHeight(0)
        ac.setFogColor(basecolor)
        ac.setHorizonFogMultiplier(1, 1, 1)
        ac.setFogBlend(0)
        ac.setFogExponent(1)
        ac.setFogDistance(1000000, 1000000, 0)
        
    elseif fogtype == 1 then
        -- Immersive mode
        fogdensity = pure.mod.dayCurve(1, 1, 0.07) * (500 * fog_amount_value) + (140.25 * badness)
        ac.setFogBacklitMultiplier(pure.mod.dayCurve(0.20, 0.04, 0.67))
        ac.setFogDensity(st6ix_smooth("fog_density", fogdensity, dt, 2))
        ac.setFogHeight(pure.mod.dayCurve(1120, 1913, 0.67))
        ac.setFogColor(math.lerp(skycolor, RGBcolorfog, colorblend) / daycurvefog)
        fogsat = 1
        ac.setHorizonFogMultiplier(0.705, 1, 1)
        ac.setFogBlend(st6ix_smooth("fog_blend", 25.502 * Fogthickness + worldfogget.density * 0.8, dt, 2))
        ac.setFogExponent(0.7510)
        ac.setFogHeight(pure.mod.dayCurve(1120, 1213, 0.67))
        ac.setFogDistance(
            550000 * (pure.utils.CamIsInTunnel() + 0.1),
            350000 * (pure.utils.CamIsInTunnel() + 0.1),
            pure.world.getHumidity()
        )
        
    elseif fogtype == 2 then
        -- Realistic mode
        fogdensity = 0
        ac.setFogBacklitMultiplier(pure.mod.dayCurve(0.15, 0.02, 0.67))
        ac.setFogDensity(st6ix_smooth("fog_density", fog_amount_value * 7000, dt, 2))
        ac.setFogHeight(1120)
        ac.setFogColor(math.lerp(skycolor, RGBcolorfog, colorblend) / daycurvefog)
        fogsat = pure.mod.dayCurve(0.65, 1, 0.06)
        ac.setHorizonFogMultiplier(0.705, 1, 1)
        ac.setFogBlend(st6ix_smooth("fog_blend", 14.502 * Fogthickness + worldfogget.density, dt, 2))
        ac.setFogExponent(0.7510)
        ac.setFogHeight(pure.mod.dayCurve(1120, 1213, 0.67))
        ac.setFogDistance(
            5500000 * (pure.utils.CamIsInTunnel() + 0.1),
            3500000 * (pure.utils.CamIsInTunnel() + 0.1),
            pure.world.getHumidity()
        )
    end
    
    -- Convert fog color using HSV
    RGBToHSV_To(hsv_fog, worldfogget.color)
    hsv_fog.v = hsv_fog.v * 1 * (1 + (8 * badness * 1))
    hsv_fog.s = hsv_fog.s * fogsat
    HSVToRGB_To(rgb_fog, hsv_fog.h, hsv_fog.s, hsv_fog.v)
    
    -- ========================================================================
    -- DASHCAM LENS DISTORTION 
    -- ========================================================================
    local lensDistortionEnabled = pure.script.ui.getValue("Dashcam") or false
    local lensDistortionRoundness = pure.script.ui.getValue("Lens Distortion Roundness")
    local lensDistortionSmoothness = pure.script.ui.getValue("Lens Distortion Smoothness")
    
    pure.yebis.set("lensDistortionEnabled", lensDistortionEnabled)
    
    if lensDistortionEnabled then
        pure.yebis.set("lensDistortionRoundness", lensDistortionRoundness)
        pure.yebis.set("lensDistortionSmoothness", lensDistortionSmoothness)
    end
    
    -- ========================================================================
    -- VIGNETTE
    -- ========================================================================
    local vignetteintense = profile.vignette
    if vignetteintense == nil then
        vignetteintense = pure.script.ui.getValue("Vignette Intensity")
    end
    pure.yebis.set("vignetteStrength", vignetteintense, true)
    
    -- ========================================================================
    -- FILM GRAIN 
    -- ========================================================================
    local automatic_grain = profile.grain
    if automatic_grain ~= nil and automatic_grain > 0 then
        pure.pp.set("spice.SensorNoise.active", true)
        pure.pp.set("spice.SensorNoise.strength", automatic_grain * pure.mod.dayCurve(0.85, 1.15, 0.5))
        pure.pp.set("spice.SensorNoise.scale", 0.4)
    elseif automatic_grain == nil and pure.script.ui.getValue("Enable Film Grain") then
        pure.pp.set("spice.SensorNoise.active", true)
        pure.pp.set("spice.SensorNoise.strength", (4 * pure.mod.dayCurve(0.6, 1, 0.5)) * pure.script.ui.getValue("Film Grain Strength"))
        pure.pp.set("spice.SensorNoise.scale", 0.4)
    else
        pure.pp.set("spice.SensorNoise.active", false)
        pure.pp.set("spice.SensorNoise.strength", 0)
        pure.pp.set("spice.SensorNoise.scale", 0)
    end
    
    -- ========================================================================
    -- SKYDOMES 
    -- ========================================================================
    local skydometype = pure.script.ui.getValue("Skydome Preset")
    local SkydomesRot = pure.script.ui.getValue("Skydome Rotation")
    local SkydomesHeight = pure.script.ui.getValue("Skydome Height")
    local SkydomesBright = pure.script.ui.getValue("Skydome Brightness")
    local SkydomesContrast = pure.script.ui.getValue("Skydome Contrast")
    
    cover.shadowRadius = 100000
    cover.shadowOpacityMultiplier = 0.00
    cover.texOffsetX = SkydomesRot * 1.5
    
    local brightnessp = 1
    local exponentp = 1
    
    if skydometype == 0 then
        -- OFF
        cover:setTexture()
    elseif skydometype == 1 then
        -- ST6IX Nebula
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX Nebula.dds')
        brightnessp = 10
        exponentp = 1.5
        cover.texRemapY = SkydomesHeight
    elseif skydometype == 2 then
        -- ST6IX MADARA
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX MADARA.dds')
        brightnessp = 8
        exponentp = 1.8
        cover.texRemapY = SkydomesHeight * 1.2
    elseif skydometype == 3 then
        -- ST6IX blackhole
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX blackhole.dds')
        brightnessp = 12
        exponentp = 2.0
        cover.texRemapY = SkydomesHeight * 1.0
    elseif skydometype == 4 then
        -- ST6IX black-matter
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX black-matter.dds')
        brightnessp = 11
        exponentp = 1.9
        cover.texRemapY = SkydomesHeight * 1.1
    elseif skydometype == 5 then
        -- ST6IX Black matter Colored
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/Black matter Colored.dds')
        brightnessp = 9
        exponentp = 1.7
        cover.texRemapY = SkydomesHeight * 0.95
    end
    
    cover.colorMultiplier = rgb(
        SkydomesBright * brightnessp,
        SkydomesBright * brightnessp,
        SkydomesBright * brightnessp
    )
    cover.colorExponent = rgb(
        SkydomesContrast * exponentp,
        SkydomesContrast * exponentp,
        SkydomesContrast * exponentp
    )
    
    -- ========================================================================
    -- HDR & CLARITY ENHANCEMENT
    -- ========================================================================
    local hdr_preset = math.floor(pure.script.ui.getValue("hdr_clarity_preset"))
    local hdr_sharpness, hdr_clarity, hdr_micro_contrast, hdr_brightness_boost, hdr_color_vibrance, hdr_highlight_recovery
    
    if HDR_CLARITY_PRESETS[hdr_preset] then
        local p = HDR_CLARITY_PRESETS[hdr_preset]
        hdr_sharpness = p.sharpness
        hdr_clarity = p.clarity
        hdr_micro_contrast = p.micro_contrast
        hdr_brightness_boost = p.hdr_brightness
        hdr_color_vibrance = p.color_vibrance
        hdr_highlight_recovery = p.highlight_recovery
    else
        -- Manual mode
        hdr_sharpness = pure.script.ui.getValue("hdr_sharpness")
        hdr_clarity = pure.script.ui.getValue("hdr_clarity")
        hdr_micro_contrast = pure.script.ui.getValue("hdr_micro_contrast")
        hdr_brightness_boost = pure.script.ui.getValue("hdr_brightness_boost")
        hdr_color_vibrance = pure.script.ui.getValue("hdr_color_vibrance")
        hdr_highlight_recovery = pure.script.ui.getValue("hdr_highlight_recovery")
    end
    SIGNALS.recovery = hdr_highlight_recovery or 0

    hdr_sharpness = hdr_sharpness * profile.sharpness
    hdr_clarity = hdr_clarity * profile.clarity
    if lighting_sharpness_override then
        hdr_sharpness = lighting_sharpness_override * profile.sharpness
    end
    
    -- Apply sharpening via SPICE post-processing
    local sharpen_active = hdr_sharpness > 0.01
    pure.pp.set("spice.Sharpen.active", sharpen_active)
    if sharpen_active then
        -- Adaptive sharpness: reduce slightly at night to avoid noise amplification
        local night_sharpen_damp = math.lerp(1.0, 0.55, 1.0 - math.min(1, pure.mod.sun(0) * 10))
        local cockpit_sharpen_damp = interior and 0.92 or 1.0
        cockpit_sharpen_damp = cockpit_sharpen_damp * (1 - realism * (0.12 * environment.cockpit + 0.12 * environment.shadow + 0.08 * environment.rain))
        pure.pp.set("spice.Sharpen.strength", hdr_sharpness * 1.15 * night_sharpen_damp * cockpit_sharpen_damp)
    else
        pure.pp.set("spice.Sharpen.strength", 0)
    end
    
    -- Apply clarity saturation component
    if hdr_clarity > 0.01 then
        local clarity_saturation = 1.0 + (hdr_clarity * 0.08)
        pure.config.set("pp.saturation", clarity_saturation, true)
    else
        pure.config.set("pp.saturation", 1.0, true)
    end
    
    -- Color vibrance: selective saturation that boosts muted colors more than already-saturated ones
    -- Implemented through spice color grading
    if hdr_color_vibrance > 0.01 then
        local vibrance_sat = 1.0 + (hdr_color_vibrance * 0.6)
        pure.pp.set("spice.Saturation.active", true)
        pure.pp.set("spice.Saturation.strength", vibrance_sat)
    else
        pure.pp.set("spice.Saturation.active", false)
    end
    
    -- Highlight recovery intentionally does not overwrite the working bloom/glare preset.

    
    -- ========================================================================
    -- BLACK LEVELS & CONTRAST
    -- ========================================================================
    local black_multi = interior and 0.05 or 0.025
    -- In the Pure API used by the supplied working Lua, isHDR is a state value,
    -- not a callable function. Calling it stopped this update before tonemapping.
    local hdr_black_limit = pure.system.isHDR and 1.5 or 0
    local contrast_damp_day = black_multi * (pure.script.ui.getValue("black_limit_low_exposure") + hdr_black_limit)
    local contrast_damp_night = black_multi * (pure.script.ui.getValue("black_limit_high_exposure") + hdr_black_limit) * _l_Exposure_lut[5]
    local base_contrast = 1.00 - math.min(math.max(contrast_damp_day, contrast_damp_night), contrast_damp_day*_l_Exposure_lut[4] + contrast_damp_day*cloud_shadow_twilight + contrast_damp_night)
    -- Combine with HDR clarity contrast boost
    local clarity_contrast_boost = (hdr_clarity and hdr_clarity > 0.01) and (hdr_clarity * 0.35) or 0
    local micro_contrast_boost = (hdr_micro_contrast and hdr_micro_contrast > 0.01) and (hdr_micro_contrast * 0.12) or 0
    local final_contrast = lighting_contrast_override or (base_contrast + clarity_contrast_boost + micro_contrast_boost)
    pure.config.set("pp.contrast", final_contrast, true)
    
    -- ========================================================================
    -- GAMMA & TONEMAPPING
    -- ========================================================================
    -- Gamma: further lowered for brighter realistic output (was 1.35/1.28/1.22/1.15)
    gamma = math.lerp(math.lerp(math.lerp(1.18, 1.12, math.min(1, math.max(0, pure.mod.dayCurve(0.0,1.2,0.67)))), 1.08, _l_Exposure_lut[1]), 1.02, _l_Exposure_lut[2])
    -- Integrate HDR brightness boost
    local final_brightness = (hdr_brightness_boost and hdr_brightness_boost > 1.001) and hdr_brightness_boost or 1.00
    pure.config.set("pp.brightness", final_brightness, true)
    
    -- Tonemapping is applied directly after bloom above, before optional blocks.
    
    -- Spectrum adaption
    pure.light.setSpectrumAdaption(pure.script.ui.getValue("spectrum_adaption"))

    -- ========================================================================
    -- COLOR TEMPERATURE (per day/dusk/night)
    -- ========================================================================
    local _ct_aw = pure.mod.dayCurve(1, 0, 1)
    local _ct_nw = pure.mod.nightCurve(1, 0, 1)
    local _ct_tw = math.max(0, 1.0 - _ct_aw - _ct_nw)
    local _ct_blended = (pure.script.ui.getValue("color_temp_day")   * _ct_aw)
                      + (pure.script.ui.getValue("color_temp_dusk")  * _ct_tw)
                      + (pure.script.ui.getValue("color_temp_night") * _ct_nw)
    -- Normalize weights to avoid unintended temperature dips at twilight.
    local _ct_weight = _ct_aw + _ct_tw + _ct_nw
    if _ct_weight > 0 then _ct_blended = _ct_blended / _ct_weight else _ct_blended = 6500 end
    pure.yebis.set("colorTemperature", _ct_blended)
end
end

-- ============================================================================
-- USER INTERFACE AND FRAME LOOP
-- ============================================================================

-- Defaults of controls this build does not show (none in the full build).


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

    pure.script.ui.addPage('🎯Guide')
    pure.script.ui.addText('ST6IX HAT-TRICK V1.0 HDR - two ST6IX engines in one filter.')
    pure.script.ui.addText('HDR build: CSP performs the final HDR tone mapping for your display.')
    pure.script.ui.addText('Setup: Windows HDR on; CSP DXGI flip model + HDR support; AC windowed/borderless.')
    pure.script.ui.addText('Engines page: pick which engine drives each area. Only the selected one')
    pure.script.ui.addText('writes to the game, so the two never fight. Controls are grouped by engine.')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('Recipes: "Sky V1.5: Natural" = Sky Engine V1.5 + sky preset Natural.')
    pure.script.ui.addText('🌅 MORNING CLEAR - Sky: V1.5 Natural | HDR Brightness 0')
    pure.script.ui.addText('   Daytime V1.5: Crisp Clear | Bloom V1.5: Crisp Clear | Fog V1.5: None')
    pure.script.ui.addText('🌫️ MORNING HAZY - Fog V1.5: Realistic (amount 0.08, thickness 0.02)')
    pure.script.ui.addText('   Sky V1.5: Overcast Soft | Bloom V1.5: Subtle')
    pure.script.ui.addText('🌇 DUSK / DAWN - Daytime V1.5: Golden Hour | Sky V1.5: Golden Hour')
    pure.script.ui.addText('   Reflections V1.5: Cinematic | HDR Saturation 1.05')
    pure.script.ui.addText('🌙 NIGHT CLEAR - Night V1.5: Bright Night | Bloom V1.5: Subtle')
    pure.script.ui.addText('🌃 NIGHT CITY - Night V1.5: Neon City | Bloom V1.5: City Lights')
    pure.script.ui.addText('   Sky V1.5: Smog / City Haze | Reflections V1.5: Magical Shimmer')
    pure.script.ui.addText('🌧️ WET DAY / NIGHT - V1.2 engines: Lighting, Reflections and Fog adapt')
    pure.script.ui.addText('   to rain, wet roads and standing water automatically.')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('Mix freely: e.g. V1.5 lighting presets with V1.2 adaptive sky and fog.')

    pure.script.ui.addPage('⚙️Engines')
    pure.script.ui.addText('Choose the engine for each area. Pages show both engines\' controls;')
    pure.script.ui.addText('only the controls of the selected engine are active.')
    pure.script.ui.addRadioButtons('Lighting Engine', 1, 'V1.2 Photographic,V1.5 Presets')
    pure.script.ui.addRadioButtons('Sky Engine', 1, 'V1.2 Adaptive Sky,V1.5 Sky Presets')
    pure.script.ui.addRadioButtons('Fog Engine', 1, 'V1.2 Pure Weather Tuning,V1.5 Atmospheric')
    pure.script.ui.addRadioButtons('Reflection Engine', 1, 'V1.2 Adaptive,V1.5 Presets')
    pure.script.ui.addRadioButtons('Bloom Engine', 2, 'V1.2 Reactive,V1.5 INI-Matched')
    pure.script.ui.addRadioButtons('Exposure Engine', 2, 'V1.2 Adaptive,V1.5 ST6IX Custom,Pure Native')
    pure.script.ui.addRadioButtons('Color Engine', 1, 'V1.2 Adaptive White Balance,V1.5 Day-Dusk-Night')
    pure.script.ui.addText('Tone mapping: CSP HDR output (HDR Tone Mapping page shapes the scene).')
    pure.script.ui.addText('After switching an engine, restart the session for a fully clean state.')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('Overall look (V1.2)')
    pure.script.ui.addRadioButtons('Overall Mode', 2, 'Natural,Photorealistic,Manual')
    pure.script.ui.addText('Finishing profile (V1.5): sharpness, clarity, vignette and grain')
    pure.script.ui.addRadioButtons("st6ix_profile", 1, "Photoreal Drive🏎,Photoreal Cinema🎥,Photoreal Photo📸,Manual⚙")
    pure.script.ui.addText('Photoreal Drive: neutral, clean and driver-focused')
    pure.script.ui.addText('Photoreal Cinema: restrained camera depth | Photoreal Photo: detailed')
    pure.script.ui.addText('Manual: individual finishing sliders stay authoritative')
    pure.script.ui.addSliderFloat("weather_realism_v15", 0.75, 0, 1, "Weather adaptation strength; zero restores static profile effects")

    pure.script.ui.addPage('☀️Daytime')
    pure.script.ui.addText('V1.2 PHOTOGRAPHIC ENGINE')
    pure.script.ui.addRadioButtons('Morning Preset', 1, 'Natural Morning,Bright Morning,Dark Morning,Cinematic Morning,Custom')
    slider('Morning Preset Strength', 1.00, 0.00, 1.00, 'Preset influence throughout daylight')
    slider('Daylight Multiplier', 1.15, 0.60, 1.80, 'Pure daylight multiplier during daytime')
    slider('Day Sun Level', 0.95, 0.50, 1.50, 'Direct sunlight level')
    slider('Day Sun Saturation', 1.00, 0.70, 1.30, 'Direct sunlight color strength')
    slider('Day Sun Speculars', 1.00, 0.50, 1.50, 'Sun specular response')
    slider('Day Ambient Level', 1.02, 0.60, 1.50, 'Ambient light level')
    slider('Day Sky Level', 1.02, 0.60, 1.50, 'Sky illumination level')
    slider('Day Advanced Ambient', 1.02, 0.50, 1.60, 'Pure advanced ambient light')
    slider('Spectrum Adaptation', 1.00, 0.00, 1.50, 'Weather color-temperature compensation')
    slider('Lambert Gamma', 1.70, 1.00, 2.40, 'Low-angle material-lighting response')
    slider('Day CSP Light Bounce', 1.00, 0.50, 2.50, 'Dynamic-light bounce in daylight')
    slider('Day CSP Light Emissive', 1.35, 0.50, 3.00, 'Dynamic-light emissive visibility in daylight')
    slider('Day Display Brightness', 1.00, 0.50, 2.50, 'Dashboard and in-car screen brightness in daylight')
    pure.script.ui.addText('Ambient light model')
    slider('Ambient V2 Sun', 1.00, 0.50, 1.60, 'Sunlight share of the V2 ambient model')
    slider('Ambient V2 Sky', 1.00, 0.50, 1.60, 'Sky share of the V2 ambient model')
    slider('Ambient V2 Clouds', 1.00, 0.50, 1.60, 'Cloud share of the V2 ambient model')
    slider('Weather Ambient Balance', 0.50, 0.00, 1.00, 'Move ambient light from sun and sky toward clouds as cover grows')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 PRESETS ENGINE')
    pure.script.ui.addRadioButtons("lighting_preset", 7, "Pure Default,Sunrise/Sunset🌅,Midday☀,Natural🌿,Golden Hour🌇,Crisp Clear❄,Manual")
    pure.script.ui.addCheckbox("lighting_affects_bloom", false)
    pure.script.ui.addSliderFloat("daylight_multiplier", 1.0, 0.1, 10.0, "Overall daylight brightness multiplier")
    pure.script.ui.addSliderFloat("sun_level", 1.0, 0, 10.0, "Direct sunlight intensity")
    pure.script.ui.addSliderFloat("sun_speculars", 1.0, 0, 10.0, "Specular highlights from sun (reflections & shine)")
    pure.script.ui.addSliderFloat("ambient_level", 1.0, 0, 10.0, "Indirect/ambient light strength")
    pure.script.ui.addSliderFloat("advanced_ambient_light", 1.0, 0, 10.0, "Advanced ambient system multiplier")
    pure.script.ui.addSliderFloat("advanced_ambient_lightV2_sun", 1.0, 0.5, 10.0, "V2 ambient from sun contribution")
    pure.script.ui.addSliderFloat("sky_level", 1.0, 0, 10.0, "Sky illumination intensity")
    pure.script.ui.addSliderFloat("csp_lights_bounce", 1.0, 0.5, 10.0, "Light bounce/GI intensity")
    pure.script.ui.addSliderFloat("csp_lights_emissive", 1.0, 1.0, 10.0, "Emissive materials brightness")
    pure.script.ui.addSliderFloat("spectrum_adaption", 1.0, 0, 2, "Color spectrum shift with exposure")
    pure.script.ui.addSeparator()
    pure.script.ui.addText('COLOUR FINISH (both engines)')
    slider('Day Color Saturation', 0.99, 0.75, 1.25, 'Final daytime saturation')
    slider('Day Contrast', 1.00, 0.85, 1.15, 'Final daytime contrast')

    pure.script.ui.addPage('🌙Night')
    pure.script.ui.addText('V1.2 PHOTOGRAPHIC ENGINE')
    pure.script.ui.addRadioButtons('Night Preset', 1, 'Natural Night,Bright Night,Dark Night,Cinematic Night,Custom')
    slider('Night Light Pollution Level', 1.00, 0.00, 2.50, 'Night light-pollution brightness')
    slider('Night Light Pollution Density', 0.95, 0.00, 2.50, 'Night light-pollution density')
    slider('Night Lowest Ambient', 0.90, 0.20, 2.00, 'Minimum ambient light at night')
    slider('Moon Light', 1.00, 0.00, 2.50, 'Moonlight intensity')
    slider('Moon Appearance', 1.00, 0.20, 2.00, 'Visible moon brightness')
    slider('Stars Appearance', 1.00, 0.00, 3.00, 'Overall star visibility')
    slider('Stars Brightness', 1.00, 0.00, 3.00, 'Star brightness multiplier')
    slider('Stars Saturation', 0.90, 0.00, 2.00, 'Star color saturation')
    slider('Stars Exponent', 1.00, 0.30, 2.50, 'Star luminance distribution')
    slider('Night CSP Light Bounce', 1.10, 0.50, 2.50, 'Dynamic-light bounce at night')
    slider('Night CSP Light Emissive', 1.05, 0.50, 3.00, 'Dynamic-light emissive intensity at night')
    slider('Night Display Brightness', 1.00, 0.50, 2.50, 'Dashboard and in-car screen brightness at night')
    pure.script.ui.addCheckbox('Adaptive Celestial Rendering', true, 'Coordinate moon and stars with elevation, clouds, fog and city light')
    slider('Celestial Weather Extinction', 0.65, 0.00, 1.00, 'Cloud and fog reduction of moon and stars')
    slider('Moon Elevation Response', 0.35, 0.00, 1.00, 'Reduce moon response close to the horizon')
    slider('Moon Star Suppression', 0.22, 0.00, 1.00, 'Dim stars beneath a bright elevated moon')
    slider('Deep Sky Visibility', 1.00, 0.00, 2.00, 'Overall deep-sky and Milky Way visibility where the sky texture supports it')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 PRESETS ENGINE')
    pure.script.ui.addRadioButtons("night_preset", 1, "Bright Night🌕,Dark Night🌑,Cinematic🎥,Neon City🌃,Wet Night🌧,Manual")
    pure.script.ui.addSliderFloat("nlp_level", 1.0, 0.0, 10.0, "Overall light pollution intensity")
    pure.script.ui.addSliderFloat("nlp_density", 1.0, 0.0, 10.0, "Light pollution density/concentration")
    pure.script.ui.addSliderFloat("nlp_lowest_ambient", 1.0, 0.0, 10.0, "Minimum ambient light level (prevents pure black)")
    pure.script.ui.addSliderFloat("moon_light", 1.0, 0.0, 3.0, "Moonlight illumination strength")
    pure.script.ui.addSliderFloat("moon_appearance", 1.0, 0.0, 10.0, "Moon visual brightness in sky")
    pure.script.ui.addSliderFloat("stars_appearance", 1.0, 0.0, 100.0, "Star visibility & brightness")
    pure.script.ui.addCheckbox("stars_dynamic_adaption", true)
    pure.script.ui.addSliderFloat("night_csp_lights_bounce", 1.0, 0.0, 10.0, "Light bounce/GI at night")
    pure.script.ui.addSliderFloat("night_csp_lights_emissive", 1.0, 0.0, 10.0, "Emissive materials at night")
    pure.script.ui.addSeparator()
    pure.script.ui.addText('COLOUR FINISH (both engines)')
    slider('Night Color Saturation', 0.94, 0.70, 1.20, 'Final nighttime saturation')
    slider('Night Contrast', 0.98, 0.85, 1.15, 'Final nighttime contrast')

    pure.script.ui.addPage('🌤️Sky & Clouds')
    pure.script.ui.addText('V1.2 ADAPTIVE SKY ENGINE')
    pure.script.ui.addRadioButtons('Sky Preset', 1, 'Natural,Golden Hour,Overcast Soft,Pastel Dawn,City Haze,Storm,Custom')
    slider('Sky Preset Strength', 0.85, 0.00, 1.00, 'Blend the selected look with the time-specific controls')
    slider('Sky Weather Response', 0.55, 0.00, 1.00, 'Allow cloud, fog and rain to refine the selected look')
    slider('Sky Transition Speed', 1.00, 0.25, 3.00, 'Speed of smooth time, weather and preset transitions')
    slider('Day Sky Brightness', 1.00, 0.50, 1.60, 'Additional daylight sky brightness')
    slider('Day Sky Saturation', 1.00, 0.50, 1.40, 'Daylight sky color strength')
    slider('Twilight Sky Brightness', 1.00, 0.50, 1.60, 'Dawn and dusk sky brightness')
    slider('Twilight Sky Saturation', 1.00, 0.50, 1.40, 'Dawn and dusk sky color strength')
    slider('Night Sky Brightness', 1.00, 0.40, 1.60, 'Night sky brightness')
    slider('Night Sky Saturation', 1.00, 0.40, 1.40, 'Night sky color strength')
    slider('Day Cloud Brightness', 1.00, 0.40, 1.80, 'Cloud brightness in daylight')
    slider('Day Cloud Contrast', 1.00, 0.50, 1.60, 'Cloud contrast in daylight')
    slider('Day Cloud Softness', 1.00, 0.50, 1.50, 'Raymarched cloud softness in daylight')
    slider('Twilight Cloud Brightness', 1.00, 0.40, 1.80, 'Cloud brightness at dawn and dusk')
    slider('Twilight Cloud Contrast', 1.00, 0.50, 1.60, 'Cloud contrast at dawn and dusk')
    slider('Twilight Cloud Softness', 1.00, 0.50, 1.50, 'Raymarched cloud softness at dawn and dusk')
    slider('Night Cloud Brightness', 1.00, 0.40, 1.80, 'Cloud brightness at night')
    slider('Night Cloud Contrast', 1.00, 0.50, 1.60, 'Cloud contrast at night')
    slider('Night Cloud Softness', 1.00, 0.50, 1.50, 'Raymarched cloud softness at night')
    slider('Sun Apparent Size', 1.00, 0.50, 1.60, 'Apparent sun size during daylight')
    slider('Moon Apparent Size', 1.00, 0.50, 1.60, 'Apparent moon size at night')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 SKY PRESETS ENGINE')
    pure.script.ui.addRadioButtons("sky_preset", 4, "Pure Default,Vivid🌈,Cinematic🎥,Natural🌿,Golden Hour🌇,Overcast Soft☁️,Pastel Dawn🌅,Smog/City Haze🏙️,Storm Incoming⛈️,Manual")
    pure.script.ui.addSliderFloat("sky_light_level", 1.125, 0, 2.0, "Overall sky contribution to scene lighting")
    pure.script.ui.addSliderFloat("sun.sun_moon_size", 1.5, 0.5, 30.0, "Larger = more dramatic sun/moon appearance")
    pure.script.ui.addSliderFloat("Daytime Clouds Brightness", 1.0, 0.0, 3.0, "Cloud brightness during day")
    pure.script.ui.addSliderFloat("Daytime Clouds Contrast", 1.0, 0.0, 3.0, "Cloud edge definition during day")
    pure.script.ui.addSliderFloat("Nighttime Clouds Brightness", 1.0, 0.0, 3.0, "Cloud visibility at night")
    pure.script.ui.addSliderFloat("Nighttime Clouds Contrast", 1.0, 0.0, 3.0, "Cloud edge definition at night")
    pure.script.ui.addSliderFloat("Daytime Sky Level", 1.0, 0.0, 3.0, "Sky brightness during daytime")
    pure.script.ui.addSliderFloat("Duskdawn Sky Level", 0.25, 0.0, 10.0, "Sky intensity during sunrise/sunset")
    pure.script.ui.addSliderFloat("Daytime Sky Saturation", 1.0, 0.0, 3.0, "Sky color intensity (vivid vs washed out)")
    pure.script.ui.addSliderFloat("sunset_sun_sat", 1.4, 1.0, 3.0, "Sun disc saturation at sunset/dawn (peaks at twilight, neutral at midday/night)")

    pure.script.ui.addPage('🌫️Fog')
    pure.script.ui.addText('V1.2 PURE WEATHER TUNING ENGINE (scales Pure\'s live weather fog)')
    pure.script.ui.addCheckbox('Enable Fog Fine Tuning', true, 'Scale Pure Gamma live fog; weather transitions are preserved')
    pure.script.ui.addCheckbox('Custom Fog Color', false, 'Blend a chosen fog tint with Pure weather fog')
    pure.script.ui.addRadioButtons('Fog Color Preset', 1, 'Weather Adaptive,Neutral,Cold Morning,Warm Sunset,Storm,Night')
    slider('Adaptive Fog Color Strength', 0.55, 0.00, 1.00, 'Weather and time influence on fog color')
    slider('Fog Color Red', 0.72, 0.00, 1.00, 'Red channel of the custom fog color')
    slider('Fog Color Green', 0.78, 0.00, 1.00, 'Green channel of the custom fog color')
    slider('Fog Color Blue', 0.85, 0.00, 1.00, 'Blue channel of the custom fog color')
    slider('Fog Color Mix', 0.65, 0.00, 1.00, 'Blend between the live weather color and the custom color')
    slider('Fog Density', 1.00, 0.00, 2.00, 'Multiplier of Pure weather fog density')
    slider('Fog Distance', 1.00, 0.25, 2.50, 'Multiplier of Pure fog distance')
    slider('Fog Blend', 1.00, 0.50, 1.50, 'Multiplier of Pure fog blend')
    slider('Fog Height', 1.00, 0.25, 2.00, 'Multiplier of Pure fog height')
    slider('Fog Exponent', 1.00, 0.50, 2.00, 'Multiplier of Pure fog exponent')
    slider('Fog Backlight', 1.00, 0.00, 2.00, 'Sun backlight through fog')
    slider('Horizon Fog', 1.00, 0.00, 2.00, 'Horizon fog multiplier')
    slider('Fog Cubemap Visibility', 1.00, 0.00, 1.00, 'Fog contribution in reflections')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 ATMOSPHERIC ENGINE (None / Immersive / Realistic + ground fog)')
    pure.script.ui.addRadioButtons("FOG Type", 3, "None,Immersive,Realistic")
    pure.script.ui.addSliderFloat("Fog amount", 0.025, 0, 5, "Overall fog density")
    pure.script.ui.addSliderFloat("Fog Thickness", 0.005, -0.01, 0.09, "Fog layer thickness/vertical distribution")
    pure.script.ui.addSliderFloat("Fog Color mixer", 0.5, 0, 1, "Mix between sky color and fog color (0=sky, 1=fog)")

    pure.script.ui.addPage('✴️Bloom & Glare')
    pure.script.ui.addRadioButtons('Render Quality', 3, 'Performance,Balanced,High,Ultra')
    pure.script.ui.addText('Render Quality refines bloom and glare sampling in both engines.')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.2 REACTIVE ENGINE')
    pure.script.ui.addCheckbox('Bloom Enabled', true, 'Enable YEBIS bloom')
    slider('Bloom Strength', 0.24, 0.00, 0.80, 'Bloom luminance; deliberately restrained')
    slider('Bloom Threshold', 0.52, 0.15, 1.20, 'Higher values restrict bloom to brighter sources')
    slider('Bloom Radius', 0.44, 0.15, 1.20, 'Bloom spread radius')
    sliderInt('Bloom Levels', 4, 1, 8, 'Number of bloom levels')
    slider('Bloom Gamma', 1.05, 0.80, 1.60, 'Bloom luminance response')
    slider('Bloom Filter Threshold', 0.0010, 0.0001, 0.0100, 'Bright-pass threshold used by YEBIS bloom')
    pure.script.ui.addCheckbox('Glare Enabled', true, 'Enable star glare and optional camera artifacts')
    pure.script.ui.addRadioButtons('Glare Style', 1, 'Gentle,GT Broadcast,Cinematic,Le Mans,Lens Flare,Wet Night,Golden Hour,Custom')
    slider('Glare Style Strength', 0.85, 0.00, 1.00, 'Blend the selected style with the manual glare controls')
    pure.script.ui.addCheckbox('Reactive Glare', true, 'Adapt bloom and glare to exposure, highlights and time of day')
    slider('Reactive Glare Strength', 0.30, 0.00, 1.00, 'Amount of automatic glare response')
    slider('Night Light Emphasis', 0.20, 0.00, 1.00, 'Additional controlled response from lights at night')
    pure.script.ui.addCheckbox('Source Aware Glare', true, 'Give sunlight, headlights and emissive signs different responses')
    slider('Sun Glare Response', 0.35, 0.00, 1.00, 'Broad soft glare while facing the sun')
    slider('Headlight Glare Response', 0.40, 0.00, 1.00, 'Tighter night-light glare response')
    slider('Emissive Color Protection', 0.45, 0.00, 1.00, 'Keep signs and colored lights from blooming to white')
    slider('Glare Master', 1.00, 0.00, 2.00, 'Overall glare luminance')
    slider('Star Strength', 0.11, 0.00, 0.50, 'Star glare luminance')
    slider('Star Length', 0.065, 0.00, 0.30, 'Star glare length')
    sliderInt('Star Streaks', 4, 2, 8, 'Number of star streaks')
    slider('Star Softness', 0.85, 0.20, 1.50, 'Star glare softness')
    slider('Star Filter Threshold', 0.0015, 0.0001, 0.0100, 'Star bright-pass threshold')
    slider('Ghost Strength', 0.00, 0.00, 0.50, 'Lens ghost luminance')
    slider('Afterimage Strength', 0.00, 0.00, 0.40, 'Lens afterimage luminance')
    slider('Afterimage Length', 0.20, 0.00, 1.00, 'Afterimage trail length')
    pure.script.ui.addCheckbox('Anamorphic Glare', false, 'Use anamorphic glare shape')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 INI-MATCHED ENGINE')
    pure.script.ui.addRadioButtons("ini_eye_preset_v2", 1, "Natural,Subtle,Soft Night,Bright Sources,City Lights,Wet Night,Golden Hour,Crisp Clear,Manual")
    pure.script.ui.addCheckbox("ini_eye_bloom_enabled_v2", true)
    pure.script.ui.addSliderFloat("ini_eye_bloom_strength_v2", 1, 0, 2.0, "Visible bloom strength; 0 disables bloom only")
    pure.script.ui.addSliderFloat("ini_eye_bloom_threshold_v2", 0, -0.18, 0.20, "Bright-source cutoff offset; lower affects more pixels")
    pure.script.ui.addSliderFloat("ini_eye_bloom_radius_v2", 1, 0.45, 1.60, "Halo radius; 1 is the preset default")
    pure.script.ui.addSliderFloat("ini_eye_bloom_levels_v2", 0, -2, 2, "Bloom pass offset; kept within 2-6 passes")
    pure.script.ui.addSliderFloat("ini_eye_bloom_gamma_v2", 1, 0.85, 1.15, "Bloom response; 1 is neutral")
    pure.script.ui.addCheckbox("ini_eye_glare_enabled_v2", true)
    pure.script.ui.addSliderFloat("ini_eye_glare_brightness_v2", 0.12, 0, 0.60, "Star brightness; 0 disables the star component")
    pure.script.ui.addSliderFloat("ini_eye_glare_length_v2", 0.07, 0, 0.30, "Streak length; 0 removes streaks")
    pure.script.ui.addSliderFloat("ini_eye_glare_streaks_v2", 4, 2, 8, "Number of streaks; rounded to a whole number")
    pure.script.ui.addSliderFloat("ini_eye_glare_threshold_v2", 0.42, 0.10, 0.80, "Bright-source cutoff; higher restricts glare to brighter lights")
    pure.script.ui.addSliderFloat("ini_eye_glare_softness_v2", 0.80, 0.20, 1.50, "Star softness; matches the INI at 0.80")

    pure.script.ui.addPage('🌞Sun Effects')
    pure.script.ui.addText('Works when sun blinding is enabled in CSP settings.')
    pure.script.ui.addCheckbox("sunblinding_active", true)
    pure.script.ui.addCheckbox("sunblinding_allow_control", true)
    pure.script.ui.addSliderFloat("sunblinding_sensitivity", 1.0, 0, 2.0, "How sensitive the effect is to sun exposure")
    pure.script.ui.addSliderFloat("sunblinding_time_up", 0.75, 0.1, 2.0, "Fade-in time when looking at sun (seconds)")
    pure.script.ui.addSliderFloat("sunblinding_time_down", 1.875, 0.5, 3.0, "Fade-out time when looking away (seconds)")
    pure.script.ui.addText('Manual control ON: the sliders below drive the sun blinding.')
    pure.script.ui.addSliderFloat("sunblinding_cover", 0.063, 0, 1.0, "Sun corona/coverage intensity")
    pure.script.ui.addSliderFloat("sunblinding_blinding", 0.031, 0, 1.0, "Direct blinding intensity")
    pure.script.ui.addSliderFloat("sunblinding_iris", 0.625, 0, 2.0, "Iris/lens flare intensity")
    pure.script.ui.addSliderFloat("sunblinding_star_opacity", 0.400, 0, 2.0, "Star flare visibility")
    pure.script.ui.addSliderFloat("sunblinding_star_size", 2.0, 0.5, 10.0, "Star pattern size")
    pure.script.ui.addSliderFloat("sunblinding_star_blur", 0.548, 0, 10.0, "Star blur/softness")
    pure.script.ui.addSeparator()
    pure.script.ui.addText('Manual control OFF: automatic weather-aware sun blinding (V1.2)')
    slider('Sun Blinding', 0.35, 0.00, 1.00, 'Veiling glare when looking straight into the sun')
    slider('Sun Blinding Iris', 0.15, 0.00, 1.00, 'Iris contraction around a bright sun disk')

    pure.script.ui.addPage('📷Exposure')
    pure.script.ui.addText('V1.2 ADAPTIVE ENGINE')
    pure.script.ui.addRadioButtons('Tunnel Preset', 1, 'Normal,Flash,Blinding,Cinematic')
    pure.script.ui.addText('Normal is neutral. Other modes adapt inside the tunnel and recover at the exit.')
    slider('Tunnel Interior Lift', 0.18, 0.00, 0.60, 'Additional interior exposure before the tunnel exit')
    slider('Tunnel Opening Protection', 0.20, 0.00, 0.60, 'Protect the bright opening while still inside the tunnel')
    slider('Tunnel Recovery Speed', 1.00, 0.50, 2.00, 'Speed of the exit recovery curve')
    pure.script.ui.addCheckbox('Adaptive Scene Exposure', true, 'Use scene brightness, occlusion and weather to refine exposure')
    pure.script.ui.addRadioButtons('Exposure Metering', 1, 'Balanced,Center Weighted,Cockpit Weighted,Photography')
    pure.script.ui.addCheckbox('Per Camera Exposure Memory', true, 'Keep separate adaptive targets for cockpit and exterior cameras')
    slider('Adaptation Strength', 0.35, 0.00, 1.00, 'Strength of automatic scene-aware target adjustment')
    slider('Highlight Protection', 0.25, 0.00, 1.00, 'Reduce exposure when concentrated highlights dominate the scene')
    slider('Interior Metering Bias', 0.18, -0.50, 0.75, 'Positive values brighten cockpit metering')
    slider('Maximum Target Shift', 0.18, 0.00, 0.50, 'Maximum proportional change to automatic exposure targets')
    pure.script.ui.addCheckbox('Camera Style Response', false, 'Hold small changes and react quickly to meaningful lighting transitions')
    slider('CBE Mix', 0.88, 0.00, 1.00, '1 = CBE only; 0 = YEBIS autoexposure only')
    slider('CBE Target', 4.00, 1.00, 8.00, 'Pure CBE target multiplier')
    slider('CBE Sensitivity', 1.45, 0.50, 3.00, 'CBE response to scene brightness')
    slider('Minimum Exposure', 0.015, 0.005, 0.15, 'Lowest automatic exposure')
    slider('Maximum Exposure', 0.70, 0.15, 1.50, 'Highest automatic exposure')
    slider('Dark Adaptation Speed', 1.50, 0.25, 8.00, 'Speed when exposure rises in darkness')
    slider('Bright Adaptation Speed', 6.00, 0.50, 12.00, 'Speed when exposure falls in bright scenes')
    slider('YEBIS Target', 1.00, 0.25, 3.00, 'YEBIS visible-image exposure target')
    slider('Exposure Compensation EV', 0.00, -1.50, 1.50, 'Exposure compensation in stops')
    slider('Cockpit Compensation EV', 0.10, -0.75, 0.75, 'Additional cockpit exposure in stops')
    pure.script.ui.addCheckbox('Lock Exposure', false, 'Capture and hold current exposure for photography')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 ST6IX CUSTOM ENGINE')
    pure.script.ui.addStateFloat("Final Exposure", 0)
    pure.script.ui.addStateFloat("Occlusion", 0)
    pure.script.ui.addSliderFloat("Day Target Exposure", 0.08, 0.001, 0.25, "target for final exposure for day")
    pure.script.ui.addSliderFloat("Day Exposure Sensitivity", 2, 0.01, 10, "raise higher for more sensitive day exposure")
    pure.script.ui.addSliderFloat("AE Day Target", 4, 1.0, 16.0, "adjusts auto exposure target for day")
    pure.script.ui.addSliderFloat("Day AE Mix", 0.75, 0.01, 1.0, "adjusts auto exposure mix for day")
    pure.script.ui.addSliderFloat("Night Target Exposure", 0.75, 0.01, 2, "target for final exposure for night")
    pure.script.ui.addSliderFloat("Night Exposure Sensitivity", 1, 0.01, 10, "raise higher for more sensitive night exposure")
    pure.script.ui.addSliderFloat("AE Night Target", 6, 1.0, 16.0, "adjusts auto exposure target for night")
    pure.script.ui.addSliderFloat("Night AE Mix", 0.95, 0.01, 1.0, "adjusts auto exposure mix for night")
    pure.script.ui.addSliderFloat("Day Interior Exposure", 0.08, 0.01, 0.25, "day final exposure target")
    pure.script.ui.addSliderFloat("Night Interior Exposure", 0.75, 0.01, 3, "night final exposure target")
    pure.script.ui.addSliderFloat("AE Interior Day Target", 4, 1.0, 16.0, "adjusts auto exposure target for day")
    pure.script.ui.addSliderFloat("AE Interior Night Target", 6, 1.0, 16.0, "adjusts auto exposure target for night")
    pure.script.ui.addRadioButtons("Tunnel Blinding Presets", 2, "Flash⚡,Blinding☀️,Normal")
    pure.script.ui.addSliderFloat("Tunnel Blinding Strength", 1.35, 1, 2, "adjusts the strength of the tunnel blinding")

    pure.script.ui.addPage('🎨HDR Tone Mapping')
    pure.script.ui.addText('CSP performs the final HDR tone mapping for your display.')
    pure.script.ui.addText('In CSP video settings enable DXGI flip model and HDR support; run AC windowed or borderless.')
    pure.script.ui.addCheckbox('Scene Aware HDR', true, 'Adapt exposure and contrast to highlights, darkness and fog')
    slider('HDR Adaptation Strength', 0.45, 0.00, 1.00, 'Strength of the scene-aware HDR response')
    slider('HDR Highlight Protection', 0.55, 0.00, 1.00, 'Hold exposure back when bright sky, sun and reflections dominate')
    slider('HDR Shadow Lift', 0.35, 0.00, 1.00, 'Open up detail in dark scenes')
    slider('HDR Fog Contrast', 0.40, 0.00, 1.00, 'Keep dense fog from flattening the image')
    slider('HDR Brightness', 0.00, -1.50, 1.50, 'Overall HDR scene brightness in stops')
    slider('HDR Contrast', 1.00, 0.85, 1.20, 'Overall HDR contrast')
    slider('HDR Saturation', 1.00, 0.80, 1.20, 'Overall HDR colour intensity')
    pure.script.ui.addText('Works with every Exposure Engine.')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('Monitor black level (V1.5 finishing)')
    pure.script.ui.addSliderFloat("black_limit_low_exposure", 0.0, 0, 1, "Black crush prevention (bright scenes)")
    pure.script.ui.addSliderFloat("black_limit_high_exposure", 0.0, 0, 1, "Black crush prevention (dark scenes)")

    pure.script.ui.addPage('🌡️Color')
    pure.script.ui.addText('V1.2 ADAPTIVE WHITE BALANCE')
    slider('Day Color Temperature', 6400, 4800, 8000, 'YEBIS daytime color temperature in kelvin')
    slider('Night Color Temperature', 6100, 4000, 8000, 'YEBIS nighttime color temperature in kelvin')
    pure.script.ui.addCheckbox('Automatic White Balance', true, 'Adapt white balance to time, clouds, fog and rain within safe limits')
    slider('White Balance Strength', 0.55, 0.00, 1.00, 'Influence of automatic white balance')
    slider('White Balance Warmth Bias', 0, -600, 600, 'Creative warm or cool bias in kelvin')
    slider('White Balance Tint', 0.00, -0.03, 0.03, 'Restrained green-to-magenta correction')
    pure.script.ui.addCheckbox('Lock White Balance', false, 'Hold the currently calculated white balance for photography')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 DAY-DUSK-NIGHT TEMPERATURE')
    pure.script.ui.addSliderFloat("color_temp_day",   6500, 3000, 9000, "Color temperature for neutral daylight")
    pure.script.ui.addSliderFloat("color_temp_dusk",  5000, 3000, 9000, "Color temperature for a natural warm golden hour")
    pure.script.ui.addSliderFloat("color_temp_night", 6200, 3000, 9000, "Color temperature for clean night lighting")

    pure.script.ui.addPage('📹Lens')
    pure.script.ui.addRadioButtons('Lens Profile', 1, 'Clean,Cinematic,Vintage,Telephoto,Custom')
    slider('Lens Profile Strength', 0.70, 0.00, 1.00, 'Blend the selected physical lens response')
    pure.script.ui.addText('God rays')
    pure.script.ui.addSliderFloat("godray_length", 10.0, 0, 20.0, "Length of god ray shafts (0=disabled)")
    pure.script.ui.addCheckbox('Adaptive Godrays', true, 'Use Pure-safe sun, camera and FOV-aware godrays')
    slider('Godrays Strength', 0.35, 0.00, 1.00, 'Overall photographic godray strength')
    slider('Godrays FOV Response', 0.50, 0.00, 1.00, 'Scale ray length with camera field of view')
    slider('Godrays Sun Facing Response', 0.60, 0.00, 1.00, 'Increase rays smoothly while looking toward the sun')
    slider('Godrays Glare Ratio', 0.12, 0.00, 1.00, 'Godray contribution to visible glare')
    slider('Moon Godrays Strength', 0.00, 0.00, 1.00, 'Soft light shafts from a visible moon at night')
    pure.script.ui.addText('Vignette: finishing profile base x strength x lens profile x field of view')
    slider('Vignette Strength', 0.010, 0.00, 0.20, 'Edge darkening')
    slider('Vignette FOV Dependence', 0.25, 0.00, 1.00, 'Vignette response to field of view')
    pure.script.ui.addSliderFloat("Vignette Intensity", 0.1, 0, 5, "Vignette strength (0=off, higher=darker edges)")
    pure.script.ui.addText('Chromatic aberration')
    pure.script.ui.addCheckbox('Chromatic Aberration', false, 'Enable chromatic aberration; lens profiles add their character when enabled')
    sliderInt('Chromatic Samples', 5, 2, 12, 'Chromatic aberration sample count')
    slider('Chromatic Lateral', 0.0010, 0.0000, 0.0100, 'Lateral color displacement')
    slider('Chromatic Uniform', 0.0003, 0.0000, 0.0050, 'Uniform color displacement')
    pure.script.ui.addText('Lens distortion (Dashcam overrides the regular distortion when enabled)')
    pure.script.ui.addCheckbox('Lens Distortion', false, 'Enable geometric lens distortion; lens profiles add their character when enabled')
    slider('Lens Roundness', 0.05, 0.00, 1.00, 'Lens distortion roundness')
    slider('Lens Smoothness', 1.00, 0.10, 2.00, 'Lens distortion smoothness')
    pure.script.ui.addCheckbox("Dashcam", false)
    pure.script.ui.addSliderFloat("Lens Distortion Roundness", 0, 0, 1.5, "Amount of barrel/pincushion distortion")
    pure.script.ui.addSliderFloat("Lens Distortion Smoothness", 0, 0, 1, "Edge smoothness of distortion")
    pure.script.ui.addCheckbox('Depth of Field', false, 'Photographic depth of field for replays and screenshots')
    slider('DOF Focus Distance', 8.0, 0.5, 100.0, 'Focus distance in metres')
    slider('DOF Aperture', 2.8, 1.2, 22.0, 'Lens f-number; lower values give a shallower focus')
    sliderInt('DOF Quality', 3, 1, 5, 'Depth of field sampling quality')
    pure.script.ui.addText('Film grain (automatic in finishing profiles, manual in Manual)')
    pure.script.ui.addCheckbox("Enable Film Grain", false, "Toggle film grain effect on/off")
    pure.script.ui.addSliderFloat("Film Grain Strength", 1.0, 0, 10, "Film grain intensity multiplier")

    pure.script.ui.addPage('🔍HDR & Clarity')
    pure.script.ui.addText('Sharpness, clarity and HDR-style finishing (V1.5), active with every engine')
    pure.script.ui.addRadioButtons("hdr_clarity_preset", 2, "Off,Subtle HDR🌤,Full HDR☀️,Ultra HDR🔥,Cinematic Sharp🎥,Manual")
    pure.script.ui.addSliderFloat("hdr_sharpness", 0.35, 0.0, 1.0, "Sharpening intensity (0=off, 1=maximum)")
    pure.script.ui.addSliderFloat("hdr_clarity", 0.45, 0.0, 1.0, "Clarity amount (midtone contrast boost)")
    pure.script.ui.addSliderFloat("hdr_micro_contrast", 0.22, 0.0, 0.5, "Micro-contrast (fine texture detail)")
    pure.script.ui.addSliderFloat("hdr_brightness_boost", 1.14, 0.8, 1.5, "HDR brightness boost (widens highlight range)")
    pure.script.ui.addSliderFloat("hdr_color_vibrance", 0.18, 0.0, 0.5, "Color vibrance (selective saturation boost)")
    pure.script.ui.addSliderFloat("hdr_highlight_recovery", 0.28, 0.0, 0.6, "Highlight recovery (preserves bright detail)")

    pure.script.ui.addPage('🌌Skydomes')
    pure.script.ui.addRadioButtons("Skydome Preset", 1, "OFF,ST6IX Nebula,ST6IX MADARA,ST6IX blackhole,ST6IX black-matter,ST6IX Black matter Colored")
    pure.script.ui.addSliderFloat("Skydome Brightness", 1.0, 0.1, 5.0, "Skydome luminosity")
    pure.script.ui.addSliderFloat("Skydome Contrast", 1.0, 0.1, 3.0, "Skydome color contrast")
    pure.script.ui.addSliderFloat("Skydome Rotation", 0.5, 0, 3, "Horizontal rotation angle")
    pure.script.ui.addSliderFloat("Skydome Height", 1.0, 0.5, 2.0, "Vertical position adjustment")

    pure.script.ui.addPage('✨Reflections')
    pure.script.ui.addText('V1.2 ADAPTIVE ENGINE')
    pure.script.ui.addRadioButtons('Reflection Preset', 1, 'Normal,Cinematic,Photography,Custom')
    pure.script.ui.addCheckbox('Adaptive Reflections', true, 'Respond to clouds, fog, wetness, highlights and night lighting')
    pure.script.ui.addCheckbox('Wet Weather Rendering', true, 'Coordinate wet roads, standing water, night lights and color response')
    slider('Wet Reflection Gain', 0.45, 0.00, 1.00, 'Additional road reflection response from wetness and standing water')
    slider('Wet Headlight Bloom', 0.35, 0.00, 1.00, 'Additional restrained bloom from lights on wet nights')
    slider('Rain Saturation Retention', 0.80, 0.40, 1.00, 'Retain realistic color during rain')
    slider('Wet Black Depth', 0.25, 0.00, 1.00, 'Deepen wet surfaces without crushing shadow detail')
    slider('Reflection Weather Response', 0.30, 0.00, 1.00, 'Strength of weather-aware reflection changes')
    slider('Reflection CPL Strength', 0.15, 0.00, 1.00, 'Camera polarizer strength; reduced automatically in heavy weather')
    slider('Reflection Highlight Response', 0.20, 0.00, 1.00, 'Extra reflection definition from concentrated highlights')
    slider('Reflection Level', 1.05, 0.50, 1.80, 'Pure reflection brightness multiplier')
    slider('Reflection Saturation', 1.00, 0.60, 1.40, 'Pure reflection color multiplier')
    slider('Reflection Emissive Boost', 1.10, 0.00, 5.00, 'Emissive contribution to reflections')
    slider('Fresnel Strength', 0.00, 0.00, 1.00, 'Stronger reflections at grazing angles; wet roads add to it automatically')
    slider('VAO Amount', 1.00, 0.50, 1.50, 'Vertex ambient occlusion amount')
    slider('VAO Track Exponent', 1.00, 0.50, 1.50, 'Track VAO exponent multiplier')
    slider('VAO Dynamic Exponent', 1.00, 0.50, 1.50, 'Dynamic-object VAO exponent multiplier')
    slider('Weather VAO Adaptation', 0.45, 0.00, 1.00, 'Automatic VAO gain in overcast/cloud shadow')
    pure.script.ui.addSeparator()
    pure.script.ui.addText('V1.5 PRESETS ENGINE (ground fog gain also drives V1.5 fog)')
    pure.script.ui.addRadioButtons("reflections_preset", 7, "Pure Default,High Quality✨,Performance⚡,Cinematic🎥,Magical Shimmer✨,Ethereal Glow🌟,Manual")
    pure.script.ui.addSliderFloat("reflections_saturation", 1.0, 0, 2.0, "Color saturation in reflections")
    pure.script.ui.addSliderFloat("reflections_level", 1.0, 0, 2.0, "Overall reflection intensity")
    pure.script.ui.addSliderFloat("reflections_emissive_boost", 4.0, 0, 25.0, "Emissive reflection boost; realistic range is usually 1-16")
    pure.script.ui.addSliderFloat("vao_amount", 1.0, 0, 100.0, "VAO strength (adds depth to corners/crevices)")
    pure.script.ui.addSliderFloat("groundfog_gain", 1.053, 0, 3.0, "Ground fog influence on reflection clarity")

    pure.script.ui.addPage('🔧Status')
    pure.script.ui.addCheckbox('Diagnostics Enabled', false, 'Update live scene readings and warnings')
    pure.script.ui.addRadioButtons('Effect Preview', 1, 'Normal,Exposure,Glare,Reflections,Fog')
    slider('Effect Preview Strength', 0.50, 0.00, 1.00, 'Temporary diagnostic emphasis for the selected system')
    pure.script.ui.addStateFloat('Live Exposure', 0)
    pure.script.ui.addStateFloat('Live Highlights', 0)
    pure.script.ui.addStateFloat('Camera Occlusion', 0)
    pure.script.ui.addStateFloat('Wet Surface', 0)
    pure.script.ui.addStateFloat('World Fog', 0)
    pure.script.ui.addStateFloat('Sun Facing', 0)
    pure.script.ui.addStateFloat('Tunnel Response', 0)
    pure.script.ui.addStateFloat('Star Output', 0)
    pure.script.ui.addStateString('Render Status', 'Diagnostics disabled')
    pure.script.ui.addSeparator()
    pure.script.ui.addStateFloat("Status: Script OK", 0)
    pure.script.ui.addStateFloat("Status: Tonemap", 0)
    pure.script.ui.addStateFloat("Status: Bloom", 0)
    pure.script.ui.addStateFloat("Status: Exposure Mode", 0)
    pure.script.ui.addStateFloat("Status: Exposure", 0)
    pure.script.ui.addStateFloat("Status: Interior", 0)
    pure.script.ui.addStateFloat("Status: Wetness", 0)
    pure.script.ui.addStateFloat("Status: Rain", 0)
    pure.script.ui.addStateFloat("Status: Weather Adaptation", 0)
    pure.script.ui.addText('Tonemap 0 = CSP HDR output | Exposure Mode 1 = V1.5 Custom active')

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
    E.sky = FIXED_ENGINES.sky or uiChoice('Sky Engine', 1, 2)
    E.fog = uiChoice('Fog Engine', 1, 2)
    E.reflections = uiChoice('Reflection Engine', 1, 2)
    E.bloom = FIXED_ENGINES.bloom or uiChoice('Bloom Engine', 2, 2)
    E.exposure = FIXED_ENGINES.exposure or uiChoice('Exposure Engine', 2, 3)
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
    -- Sky level: the sky engine sets the base and the lighting engine trims it
    -- with its own sky level (V1.2 Day Sky Level or V1.5 Sky Level).
    local skyLevel
    if E.sky == 1 then
        skyLevel = numberOr(OUT12['config:light.sky.level'], 1)
        -- V1.2's sky already includes the V1.2 lighting's Day Sky Level.
        if E.lighting == 2 then skyLevel = skyLevel / math.max(0.05, numberOr(SIGNALS.daySky, 1)) end
    else
        skyLevel = numberOr(OUT15['config:light.sky.level'], 1)
        if E.lighting == 1 then skyLevel = skyLevel * numberOr(SIGNALS.daySky, 1) end
    end
    if E.lighting == 2 then skyLevel = skyLevel * numberOr(SIGNALS.v15SkyLevel, 1) end
    pure.config.set('light.sky.level', skyLevel, true)
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
