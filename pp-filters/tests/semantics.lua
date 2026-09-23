-- Usage: luajit tests/semantics.lua <baseline.lua> <candidate.lua>
-- Behavioural checks for issues that a plain "does the output change" audit cannot see.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local baseline, candidate = assert(arg[1]), assert(arg[2])
local DT = 0.1
local failures = 0

local function check(ok, label, detail)
    print((ok and 'PASS ' or 'FAIL ') .. label .. (detail and ('  (' .. detail .. ')') or ''))
    if not ok then failures = failures + 1 end
end

local function last(S, key, i) return S.last[key] and S.last[key][i or 1] end
local day = function() end
local night = function(w) w.sun, w.sunElevation, w.moonElevation, w.exposure, w.cbeAvg = 0, -30, 40, 0.6, 0.2 end

-- 1. Saved-settings compatibility: every V1.1 control survives unchanged.
do
    local a = H.run(baseline, {}, day, 1, DT)
    local b = H.run(candidate, {}, day, 1, DT)
    local missing = {}
    for _, name in ipairs(a.order) do
        local x, y = a.controls[name], b.controls[name]
        -- Radios may gain options at the end; existing indexes keep their meaning.
        local radioOk = x.kind ~= 'radio' or (y and y.count >= x.count)
        local rangeOk = x.kind == 'radio' or (y and x.min == y.min and x.max == y.max)
        if not y or x.kind ~= y.kind or x.default ~= y.default or not rangeOk or not radioOk then
            missing[#missing + 1] = name
        end
    end
    check(#missing == 0, 'all V1.1 controls kept with identical name, type, default and range',
        #missing > 0 and table.concat(missing, ', ') or (#a.order .. ' controls'))
end

-- 2. White balance: the white point stays neutral and the scene temperature moves.
do
    local warm = H.run(candidate, { ['Day Color Temperature'] = 5200 }, day, 60, DT)
    local cool = H.run(candidate, { ['Day Color Temperature'] = 7600 }, day, 60, DT)
    check(last(warm, 'yebis:whiteBalance') == 6500 and last(cool, 'yebis:whiteBalance') == 6500,
        'white point fixed at 6500 K')
    check(last(warm, 'yebis:colorTemperature') < last(cool, 'yebis:colorTemperature'),
        'Day Color Temperature shifts the image',
        string.format('%.0f K vs %.0f K', last(warm, 'yebis:colorTemperature'), last(cool, 'yebis:colorTemperature')))
    local old = H.run(baseline, { ['Day Color Temperature'] = 5200 }, day, 60, DT)
    check(last(old, 'yebis:whiteBalance') == last(old, 'yebis:colorTemperature'),
        'V1.1 wrote equal colorTemperature/whiteBalance (the cancelled-out bug being fixed)')
end

-- 3. Lens checkboxes are the master switches under every profile.
do
    local ok = true
    for profile = 1, 5 do
        local s = H.run(candidate, { ['Lens Profile'] = profile, ['Chromatic Aberration'] = false,
            ['Lens Distortion'] = false }, day, 5, DT)
        if last(s, 'yebis:chromaticAberrationEnabled') ~= 0 or last(s, 'yebis:lensDistortionEnabled') ~= 0 then
            ok = false
        end
    end
    check(ok, 'unticked Chromatic Aberration / Lens Distortion stay off for every Lens Profile')
    local a = H.run(candidate, { ['Lens Profile'] = 3, ['Chromatic Aberration'] = true }, day, 5, DT)
    local b = H.run(candidate, { ['Lens Profile'] = 1, ['Chromatic Aberration'] = true }, day, 5, DT)
    check(last(a, 'yebis:chromaticAberrationLateralDisplacement') > last(b, 'yebis:chromaticAberrationLateralDisplacement'),
        'Vintage profile still adds its aberration when enabled')
end

-- 4. CPL strength works with Adaptive Reflections off.
do
    local a = H.run(candidate, { ['Adaptive Reflections'] = false, ['Reflection CPL Strength'] = 0.6 }, day, 5, DT)
    local b = H.run(candidate, { ['Adaptive Reflections'] = false, ['Reflection CPL Strength'] = 0.2 }, day, 5, DT)
    check((last(a, 'camera.setCPL') or 0) > (last(b, 'camera.setCPL') or 0),
        'Reflection CPL Strength is live without Adaptive Reflections')
end

-- 5. Star Streaks slider is live under a non-custom Glare Style.
do
    local a = H.run(candidate, { ['Glare Style'] = 3, ['Star Streaks'] = 2 }, day, 5, DT)
    local b = H.run(candidate, { ['Glare Style'] = 3, ['Star Streaks'] = 8 }, day, 5, DT)
    check(last(a, 'yebis:glareShapeStarStreaks') ~= last(b, 'yebis:glareShapeStarStreaks'),
        'Star Streaks slider changes streaks under Cinematic style',
        last(a, 'yebis:glareShapeStarStreaks') .. ' vs ' .. last(b, 'yebis:glareShapeStarStreaks'))
    local old = H.run(baseline, {}, day, 5, DT)
    local new = H.run(candidate, {}, day, 5, DT)
    check(last(old, 'yebis:glareShapeStarStreaks') == last(new, 'yebis:glareShapeStarStreaks'),
        'default streak count unchanged from V1.1')
end

-- 6. Stars stay stable if Pure echoes back the value written last frame.
do
    local plain = H.run(candidate, {}, night, 400, DT)
    local echo = H.run(candidate, {}, night, 400, DT, { starFeedback = true })
    local p, e = last(plain, 'stellar.setStarsBrightness'), last(echo, 'stellar.setStarsBrightness')
    check(math.abs(p - e) < 1e-6 * (1 + p), 'star brightness stable under Pure feedback',
        string.format('%.2f vs %.2f', p, e))
    local oldEcho = H.run(baseline, {}, night, 400, DT, { starFeedback = true })
    print(string.format('INFO V1.1 under the same feedback ends at %.6f (steady value %.2f)',
        last(oldEcho, 'stellar.setStarsBrightness'), p))
end

-- 7. Fog fine tuning off passes Pure's live fog straight through.
do
    local s = H.run(candidate, { ['Enable Fog Fine Tuning'] = false, ['Fog Density'] = 2,
        ['Fog Distance'] = 2.5 }, day, 5, DT)
    local fogDensity = 0.4 + 0.05
    check(math.abs(last(s, 'ac.setFogDensity') - fogDensity) < 1e-9 and last(s, 'ac.setFogDistance') == 25000,
        'fine tuning off = untouched Pure fog')
    local c = last(s, 'ac.setFogColor', 1)
    check(math.abs(c - 0.7) < 1e-9, 'fine tuning off = untouched Pure fog colour')
end

-- 8. Emissive Color Protection works with Source Aware Glare off.
do
    local nightLights = function(w) night(w); w.cbeMax = 8 end
    local a = H.run(candidate, { ['Source Aware Glare'] = false, ['Emissive Color Protection'] = 1 }, nightLights, 40, DT)
    local b = H.run(candidate, { ['Source Aware Glare'] = false, ['Emissive Color Protection'] = 0 }, nightLights, 40, DT)
    check(last(a, 'yebis:glareThreshold') > last(b, 'yebis:glareThreshold'),
        'Emissive Color Protection live without Source Aware Glare')
end

-- 9. New features default to V1.1 behaviour where they could change the look.
do
    local s = H.run(candidate, {}, night, 40, DT)
    local old = H.run(baseline, {}, night, 40, DT)
    check(last(s, 'yebis:godraysLength') == last(old, 'yebis:godraysLength'),
        'Moon Godrays at 0 leaves night godrays as in V1.1')
    local dofKeys = 0
    for k in pairs(s.accum) do if k:find('^yebis:dof') then dofKeys = dofKeys + 1 end end
    check(dofKeys == 0, 'Depth of Field off writes nothing to DOF')
    local on = H.run(candidate, { ['Moon Godrays Strength'] = 1 }, night, 40, DT)
    check(last(on, 'yebis:godraysLength') > last(s, 'yebis:godraysLength'), 'Moon Godrays produce rays at night')
end

-- 10. Missing Pure getters (older builds) do not break the filter.
do
    local S = H.new(candidate)
    for k, v in pairs(H.defaultWorld()) do S.world[k] = v end
    S.env.pure.world.getMist = nil
    S.env.pure.world.getSmog = nil
    S.env.pure.world.getRainFX_Water = nil
    S.env.pure.exposure.getCalculatedValue = nil
    S.env.pure.world.getPureGammaFogTable = nil
    local ok, err = pcall(S.env.init_pure_script)
    if ok then ok, err = pcall(S.env.update_pure_script, DT) end
    check(ok, 'runs on a Pure build without newer getters', err and tostring(err))
    local T = H.new(baseline)
    for k, v in pairs(H.defaultWorld()) do T.world[k] = v end
    T.env.pure.world.getMist = nil
    local okOld = pcall(T.env.init_pure_script) and pcall(T.env.update_pure_script, DT)
    print('INFO V1.1 on the same build ' .. (okOld and 'runs' or 'crashes'))
end

-- 11. Colour grading: neutral is invisible, profiles follow day/night, sliders always live.
do
    local neutral = H.run(candidate, {}, day, 40, DT)
    local extras = 0
    for k in pairs(neutral.accum) do
        if k == 'pp:pp.luma_saturation' or k == 'pp:pp.black_level' or k == 'yebis:sepia' then extras = extras + 1 end
    end
    check(extras == 0, 'Neutral grade writes no vibrance, fade or sepia')

    local vivid = H.run(candidate, { ['Color Profile'] = 3 }, day, 40, DT)
    check(last(vivid, 'config:pp.saturation') > last(neutral, 'config:pp.saturation'), 'Vivid profile raises saturation by day')
    local dayOnlyAtNight = H.run(candidate, { ['Color Profile'] = 3 }, night, 40, DT)
    local neutralNight = H.run(candidate, {}, night, 40, DT)
    check(math.abs(last(dayOnlyAtNight, 'config:pp.saturation') - last(neutralNight, 'config:pp.saturation')) < 1e-9,
        'day profile stays out of full night')
    local moon = H.run(candidate, { ['Night Color Profile'] = 3 }, night, 40, DT)
    check(last(moon, 'yebis:colorTemperature') > last(neutralNight, 'yebis:colorTemperature'),
        'Moonlight Blue cools the night image')

    local manual = H.run(candidate, { ['Grade Saturation'] = 1.2, ['Grade Temperature'] = -400 }, day, 40, DT)
    check(last(manual, 'config:pp.saturation') > last(neutral, 'config:pp.saturation')
        and last(manual, 'yebis:colorTemperature') < last(neutral, 'yebis:colorTemperature'),
        'manual grade sliders are live on the Neutral profile')

    local halfFilm = H.run(candidate, { ['Color Profile'] = 7, ['Grade Strength'] = 0.5 }, day, 40, DT)
    local fullFilm = H.run(candidate, { ['Color Profile'] = 7 }, day, 40, DT)
    check(last(halfFilm, 'yebis:sepia') < last(fullFilm, 'yebis:sepia'), 'Grade Strength scales the profile')

    local S = H.new(candidate)
    for k, v in pairs(H.defaultWorld()) do S.world[k] = v end
    S.env.init_pure_script()
    S.values['Color Profile'] = 7
    for _ = 1, 5 do S.env.update_pure_script(DT) end
    S.values['Color Profile'] = 1
    S.accum, S.last = {}, {}
    S.env.update_pure_script(DT)
    local released = last(S, 'yebis:sepia') == 0 and last(S, 'pp:pp.black_level') == 0
        and last(S, 'pp:pp.luma_saturation') == 1
    S.accum, S.last = {}, {}
    S.env.update_pure_script(DT)
    check(released and S.last['yebis:sepia'] == nil, 'switching back to Neutral releases the grade once, then stops writing')
end

-- 12. GT7 is a real, separate tone curve.
do
    local gt7 = H.run(candidate, { ['Tone Curve'] = 4 }, day, 5, DT)
    local agx = H.run(candidate, { ['Tone Curve'] = 1 }, day, 5, DT)
    check(gt7.tonemapTable and gt7.tonemapTable.shader:find('st6ixGtCurve') ~= nil, 'GT7 option installs the GT7 shader')
    check(agx.tonemapTable and agx.tonemapTable.shader:find('st6ixAgx') ~= nil, 'AgX option still installs AgX')
    local wide = H.run(candidate, { ['Tone Curve'] = 4, ['GT7 Highlight Range'] = 5 }, day, 5, DT)
    check(wide.tonemapTable.values.gtPeak > gt7.tonemapTable.values.gtPeak
        and math.abs(wide.tonemapTable.values.gtInputScale / wide.tonemapTable.values.gtPeak
            - gt7.tonemapTable.values.gtInputScale / gt7.tonemapTable.values.gtPeak) < 1e-9,
        'GT7 Highlight Range adds headroom without shifting mid-tones')
end

print(failures == 0 and '\nALL SEMANTIC CHECKS PASSED' or ('\n' .. failures .. ' SEMANTIC CHECKS FAILED'))
os.exit(failures == 0 and 0 or 1)
