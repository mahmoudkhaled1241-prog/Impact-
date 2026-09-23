-- Usage: luajit tests/hattrick_check.lua
-- Regression checks for ST6IX HAT-TRICK (both builds):
--   * every engine combination and tone curve runs without errors
--   * with an engine selected, the merged filter writes exactly what the
--     original ST6IX V1.2 / V1.5 (radios read 1-based) write for that engine
--   * the HDR build keeps YEBIS linear with neutral gamma and matches ST6IX
--     V1.2 HDR when every engine is V1.2
--   * V2 matches V1.0 run with V2's fixed engine choices

local here = arg[0]:gsub('[^/\\]+$', '')
package.path = here .. '?.lua;' .. package.path
local H = require('harness')
local root = here .. '../'
local SDR = root .. 'hattrick/ST6IX_HatTrick_V1.0.lua'
local HDR = root .. 'hattrick/ST6IX_HatTrick_V1.0_HDR.lua'
local SRC12 = root .. 'hattrick/build/src_ST6IX_V1.2.lua'
local SRC15 = root .. 'hattrick/build/src_ST6IX_V1.5.lua'
local HDR12 = root .. 'hdr/ST6IX_PP_V1.2_HDR.lua'
local tmp = os.getenv('TMPDIR') or '/tmp'

local failures = 0
local function fail(msg) failures = failures + 1; print('FAIL ' .. msg) end

local function readAll(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

-- V1.5 reference with its preset radios read 1-based, as Pure delivers them.
local REF15 = tmp .. '/st6ix_v15_1based_ref.lua'
do
    local src = readAll(SRC15):gsub('^\239\187\191', ''):gsub('\r\n', '\n')
    local shim = [[
local __realGet = pure.script.ui.getValue
local __RAD = { st6ix_profile=1, lighting_preset=1, night_preset=1, reflections_preset=1, sky_preset=1,
  ['FOG Type']=1, ini_eye_preset_v2=1, hdr_clarity_preset=1, ['Skydome Preset']=1, ['Tunnel Blinding Presets']=1 }
pure.script.ui.getValue = function(n)
  local x = __realGet(n)
  if __RAD[n] and type(x) == 'number' then return x - 1 end
  return x
end
]]
    local f = assert(io.open(REF15, 'wb'))
    f:write(shim .. src)
    f:close()
end

local function scene(w, i)
    local t = i / 120
    w.sun = math.max(0, math.cos(t * 3.1)); w.twilight = 0.3
    w.fog = 0.1 + 0.3 * t; w.rain = t > 0.5 and 0.6 or 0; w.wetness = w.rain; w.water = w.rain * 0.5
    w.occlusion = (i % 60 < 10) and 0.2 or 1; w.interior = (i % 90 > 45)
    w.cbeAvg = 0.2 + w.sun; w.cbeMax = 1 + 3 * w.sun; w.cloud = 0.2 + 0.5 * t
end

local function clean(S, label)
    for _, e in ipairs(S.errors) do fail(label .. ': ' .. e) end
    for _, e in ipairs(S.logs) do fail(label .. ' logged: ' .. e) end
end

-- 1. Every engine combination, tone curve and sun blinding mode runs cleanly.
for _, script in ipairs({ SDR, HDR }) do
    local runs = 0
    for li = 1, 2 do for sk = 1, 2 do for fo = 1, 2 do for re = 1, 2 do
    for bl = 1, 2 do for ex = 1, 3 do for co = 1, 2 do
        clean(H.run(script, { ['Lighting Engine'] = li, ['Sky Engine'] = sk, ['Fog Engine'] = fo,
            ['Reflection Engine'] = re, ['Bloom Engine'] = bl, ['Exposure Engine'] = ex,
            ['Color Engine'] = co }, scene, 40, 1 / 60), script .. ' engines ' .. table.concat({li, sk, fo, re, bl, ex, co}, ','))
        runs = runs + 1
    end end end end end end end
    for tone = 1, 9 do for sb = 0, 1 do
        clean(H.run(script, { ['Tone Curve'] = tone, sunblinding_allow_control = sb == 1 }, scene, 40, 1 / 60),
            script .. ' tone ' .. tone)
        runs = runs + 1
    end end
    print(string.format('combinations: %d runs of %s', runs, script:match('[^/]+$')))
end

-- 2. Engine parity: the selected engine writes what the original writes.
local COMPOSED = {
    ['config:pp.saturation'] = true, ['config:pp.contrast'] = true, ['config:light.sun.saturation'] = true,
    ['yebis:vignetteStrength'] = true, ['yebis:lensDistortionEnabled'] = true,
    ['yebis:lensDistortionRoundness'] = true, ['yebis:lensDistortionSmoothness'] = true,
    ['yebis:vignetteFovDependency'] = true, -- invalid YEBIS name, dropped on purpose
    ['ui.state:Status: Tonemap'] = true,     -- now shows the Tone Curve index
}
local function parity(label, merged, mv, ref, rv, skip, frames)
    local M = H.run(merged, mv, scene, frames or 240, 1 / 60)
    local R = H.run(ref, rv, scene, frames or 240, 1 / 60)
    clean(M, label)
    local diffs = {}
    for k, a in pairs(R.accum) do
        if not COMPOSED[k] and not (skip and skip(k)) then
            local b = M.accum[k]
            if not b then diffs[#diffs + 1] = k .. ' missing'
            else
                for i = 1, math.max(#a, #b) do
                    local x, y = a[i] or 0, b[i] or 0
                    if math.abs(x - y) > 1e-6 * (1 + math.abs(x) + math.abs(y)) then
                        diffs[#diffs + 1] = string.format('%s ref=%.6g merged=%.6g', k, x, y); break
                    end
                end
            end
        end
    end
    if #diffs > 0 then
        table.sort(diffs)
        fail(label .. ': ' .. #diffs .. ' differences, e.g. ' .. diffs[1])
    else
        print('identical: ' .. label)
    end
end

local ALL12 = { ['Lighting Engine'] = 1, ['Sky Engine'] = 1, ['Fog Engine'] = 1, ['Reflection Engine'] = 1,
    ['Bloom Engine'] = 1, ['Exposure Engine'] = 1, ['Color Engine'] = 1,
    sunblinding_allow_control = false, hdr_clarity_preset = 1 }
local function with(base, extra)
    local r = {}
    for k, v in pairs(base) do r[k] = v end
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

for tone = 1, 3 do
    parity('V1.2 engines, Tone Curve ' .. tone, SDR, with(ALL12, { ['Tone Curve'] = tone }),
        SRC12, { ['Tone Curve'] = tone })
end
for mode = 1, 3 do
    parity('V1.2 engines, Overall Mode ' .. mode, SDR, with(ALL12, { ['Tone Curve'] = 1, ['Overall Mode'] = mode }),
        SRC12, { ['Tone Curve'] = 1, ['Overall Mode'] = mode })
end
parity('HDR build, V1.2 engines vs ST6IX V1.2 HDR', HDR, ALL12, HDR12, {})

local ALL15 = { ['Lighting Engine'] = 2, ['Sky Engine'] = 2, ['Fog Engine'] = 2, ['Reflection Engine'] = 2,
    ['Bloom Engine'] = 2, ['Exposure Engine'] = 2, ['Color Engine'] = 2, ['Tone Curve'] = 6,
    sunblinding_allow_control = true }
local REF15_DEFAULTS = { exposure_mode = 1, st6ix_profile = 1, lighting_preset = 7, night_preset = 1,
    reflections_preset = 7, sky_preset = 4, ['FOG Type'] = 3, ini_eye_preset_v2 = 1,
    hdr_clarity_preset = 2, ['Skydome Preset'] = 1, ['Tunnel Blinding Presets'] = 2, Tonemapping = 3 }
local function toneKey(k)
    return k:find('ppTonemap') or k:find('Tonemapping') or k == 'ac.setPpTonemapGamma'
end
local PRESET_SETS = { {},
    { lighting_preset = 3, sky_preset = 5, ['FOG Type'] = 2, reflections_preset = 4 },
    { night_preset = 3, ini_eye_preset_v2 = 6, hdr_clarity_preset = 4, st6ix_profile = 3, ['Skydome Preset'] = 2 },
    { ['FOG Type'] = 1, ['Tunnel Blinding Presets'] = 1, lighting_preset = 1, sky_preset = 1 } }
for i, p in ipairs(PRESET_SETS) do
    parity('V1.5 engines, preset set ' .. i, SDR, with(ALL15, p), REF15, with(REF15_DEFAULTS, p), toneKey)
end
-- V1.5 curves: each Tone Curve id runs the V1.5 branch its name describes.
for merged, original in pairs({ [4] = 0, [5] = 2, [7] = 3, [8] = 4, [9] = 5 }) do
    parity(string.format('Tone Curve %d = V1.5 tonemapper branch %d', merged, original), SDR,
        with(ALL15, { ['Tone Curve'] = merged }), REF15, with(REF15_DEFAULTS, { Tonemapping = original }),
        function(k) return not toneKey(k) end, 200)
end
do
    local S = H.run(SDR, { ['Tone Curve'] = 6 }, scene, 30, 1 / 60)
    if not (S.tonemapTable and S.tonemapTable.values.agx_mix and S.last['pp.setCustomRGBTonemapping']) then
        fail('Hyperchrome does not set its custom curve')
    end
end

-- 3. HDR build: linear YEBIS, neutral gamma, no SDR curve writes, and the HDR
--    response reaches every exposure engine.
for tone = 0, 9 do for ex = 1, 3 do
    local S = H.run(HDR, { ['Exposure Engine'] = ex, ['Tone Curve'] = tone }, scene, 40, 1 / 60)
    clean(S, 'HDR tone ' .. tone .. ' exposure ' .. ex)
    for k in pairs(S.accum) do
        if k:find('ppTonemap') or k == 'pp.setCustomRGBTonemapping' then fail('HDR build wrote ' .. k) end
    end
    if S.accum['pp.setTonemapping'][1] ~= 0 or S.last['pp.setTonemapping'][1] ~= 0 then fail('HDR tone function not linear') end
    if math.abs(S.last['ac.setPpTonemapGamma'][1] - 0.9999) > 1e-9 then fail('HDR gamma not neutral') end
    if S.accum['yebis:filmicContrast'][1] ~= 0 then fail('HDR filmic contrast not 0') end
end end
for ex = 1, 3 do
    local a = H.run(HDR, { ['Exposure Engine'] = ex, ['HDR Brightness'] = 0 }, scene, 30, 1 / 60)
    local b = H.run(HDR, { ['Exposure Engine'] = ex, ['HDR Brightness'] = 1 }, scene, 30, 1 / 60)
    local ma, mb = a.last['exposure.cbe.setMultiplier'][1], b.last['exposure.cbe.setMultiplier'][1]
    if not (mb > ma * 1.8 and mb < ma * 2.2) then
        fail(string.format('HDR Brightness +1 stop in Exposure Engine %d: %.3f -> %.3f', ex, ma, mb))
    end
end
print('HDR pipeline checked')

-- 4. V2 (Exposure and Bloom/Glare on V1.2, Sky on V1.5, fog as ST6IX FOG 1/2)
--    writes exactly what V1.0 writes with the same engine choices.
local V2 = { SDR = root .. 'hattrick/ST6IX_HatTrick_V2.0.lua', HDR = root .. 'hattrick/ST6IX_HatTrick_V2.0_HDR.lua' }
local V1 = { SDR = SDR, HDR = HDR }
for _, kind in ipairs({ 'SDR', 'HDR' }) do
    local probe = H.run(V2[kind], {}, scene, 1, 1 / 60)
    clean(probe, 'V2 ' .. kind)
    for _, gone in ipairs({ 'Sky Engine', 'Bloom Engine', 'Exposure Engine', 'Fog Engine', 'Sky Preset',
        'ini_eye_preset_v2', 'Day Target Exposure', 'lighting_affects_bloom' }) do
        if probe.controls[gone] then fail('V2 ' .. kind .. ' still shows ' .. gone) end
    end
    if not probe.controls['ST6IX Fog'] or probe.controls['ST6IX Fog'].count ~= 2 then
        fail('V2 ' .. kind .. ' has no ST6IX FOG 1/2 selector')
    end
    local n = 0
    for fogSystem = 1, 2 do for li = 1, 2 do for re = 1, 2 do for co = 1, 2 do
        local shared = { ['Lighting Engine'] = li, ['Reflection Engine'] = re, ['Color Engine'] = co,
            ['Tone Curve'] = 6, sunblinding_allow_control = li == 2, hdr_clarity_preset = 2 + li }
        local a = H.run(V1[kind], with(shared, { ['Sky Engine'] = 2, ['Exposure Engine'] = 1,
            ['Bloom Engine'] = 1, ['Fog Engine'] = fogSystem }), scene, 120, 1 / 60)
        local b = H.run(V2[kind], with(shared, { ['ST6IX Fog'] = fogSystem }), scene, 120, 1 / 60)
        clean(b, 'V2 ' .. kind)
        local d = {}
        for _, k in ipairs(H.diff(a, b)) do
            if not k:find('^ui%.state:') then d[#d + 1] = k end
        end
        if #d > 0 then fail(string.format('V2 %s differs from V1.0 (fog %d, engines %d%d%d): %s', kind, fogSystem, li, re, co, table.concat(d, ', '))) end
        n = n + 1
    end end end end
    print(string.format('V2 %s matches V1.0 with the same engine choices (%d configurations)', kind, n))
end

print(failures == 0 and '\nALL HAT-TRICK CHECKS PASSED' or ('\n' .. failures .. ' FAILURES'))
os.exit(failures == 0 and 0 or 1)
