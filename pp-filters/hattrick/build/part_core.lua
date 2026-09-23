-- ST6IX HAT-TRICK V1.0
-- One filter, two engines: ST6IX V1.2 (Gamma V1.8 photographic engine) and
-- ST6IX V1.5 (Professional Edition). Each page chooses which engine drives it;
-- only the selected engine may write to the game, so the two never fight.
-- Pure radio buttons are 1-based throughout this file.

local BUILD = { name = 'ST6IX HAT-TRICK V1.0', hdr = false }
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
