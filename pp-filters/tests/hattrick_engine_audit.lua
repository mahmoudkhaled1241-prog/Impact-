-- Usage: luajit tests/hattrick_engine_audit.lua <HAT-TRICK script> [v2]
-- audit.lua varies one setting at a time, so it cannot reach V1.5 controls
-- that need their engine selected AND a Manual preset. This check turns the
-- engine on first, then verifies those controls and that every preset option
-- gives a different result.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local script, isV2 = arg[1], arg[2] == 'v2'
local SCENES = {
    function(w) end,
    function(w) w.sun, w.twilight, w.sunElevation, w.moonElevation, w.exposure, w.cbeAvg = 0.5, 0.8, -2, 5, 0.45, 0.5 end,
    function(w) w.sun, w.sunElevation, w.moonElevation, w.exposure, w.cbeAvg, w.cbeMax, w.smog = 0, -30, 40, 0.6, 0.2, 2, 0.5 end,
    function(w) w.sun, w.overcast, w.cloud, w.badness, w.rain, w.wetness, w.fog = 0.9, 0.9, 0.95, 0.7, 0.8, 0.9, 0.3 end,
    function(w) w.sun, w.sunElevation, w.fog, w.mist, w.humidity = 0.8, 8, 0.85, 0.8, 0.95 end,
    function(w) w.sun, w.twilight, w.sunElevation, w.moonElevation = 0, 0.2, -30, 30
        w.exposure, w.cbeAvg, w.cbeMax, w.cloudShadow = 0.9, 0.05, 0.3, 0.5 end,
}
local ENGINE = {
    lighting = { ['Lighting Engine'] = 2 }, refl = { ['Reflection Engine'] = 2 },
    sky = isV2 and {} or { ['Sky Engine'] = 2 },
    fog = isV2 and { ['ST6IX Fog'] = 2 } or { ['Fog Engine'] = 2 },
}
local function with(a, b) local r = {} for k, v in pairs(a) do r[k] = v end for k, v in pairs(b or {}) do r[k] = v end return r end
local function differs(a, b)
    for _, sc in ipairs(SCENES) do
        if #H.diff(H.run(script, a, sc, 60, 0.1), H.run(script, b, sc, 60, 0.1)) > 0 then return true end
    end
    return false
end
local bad = 0
local function slider(name, eng, ctx, lo, hi)
    local base = with(ENGINE[eng], ctx)
    local ok = differs(with(base, { [name] = lo }), with(base, { [name] = hi }))
    if not ok then bad = bad + 1 end
    print(string.format('%-28s %s', name, ok and 'works' or 'DEAD'))
end
local nightManual = { night_preset = 6 }
for _, n in ipairs({ 'nlp_level', 'nlp_density', 'nlp_lowest_ambient', 'moon_light', 'moon_appearance',
    'stars_appearance', 'night_csp_lights_bounce', 'night_csp_lights_emissive' }) do
    slider(n, 'lighting', nightManual, 0.1, 2.5)
end
slider('stars_dynamic_adaption', 'lighting', nightManual, true, false)
if not isV2 then
    slider('Daytime Clouds Brightness', 'sky', { sky_preset = 10 }, 0.3, 1.8)
    slider('Daytime Sky Level', 'sky', { sky_preset = 10 }, 0.3, 2.5)
end
-- Preset lists: every pair of options must differ once their engine is on.
local function radio(name, eng, count)
    local twins = 0
    for i = 1, count do for j = i + 1, count do
        if not differs(with(ENGINE[eng], { [name] = i }), with(ENGINE[eng], { [name] = j })) then
            twins = twins + 1; print(string.format('   %s options %d and %d identical', name, i, j))
        end
    end end
    bad = bad + twins
    print(string.format('%-28s %s', name, twins == 0 and 'all options distinct' or twins .. ' identical pairs'))
end
radio('lighting_preset', 'lighting', 7)
radio('night_preset', 'lighting', 6)
radio('reflections_preset', 'refl', 7)
radio('FOG Type', 'fog', 3)
-- Monitor black level acts in dark scenes and under cloud shadow at twilight.
slider('black_limit_low_exposure', 'lighting', {}, 0, 1)
print(bad == 0 and 'ENGINE AUDIT PASSED' or ('ENGINE AUDIT FOUND ' .. bad))
os.exit(bad == 0 and 0 or 1)
