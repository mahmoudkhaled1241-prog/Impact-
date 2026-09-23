-- Usage: luajit tests/st6ix_pp_v11_check.lua
-- Regression checks for ST6IX PP V1.1 (SDR and HDR):
--   * with the extra FX at their defaults, it writes exactly what the ST6IX
--     V1.2 engine (and V1.2 HDR) write, across looks and scenes
--   * every radio option of every build runs without errors
--   * skydomes and film grain (and HDR & clarity in the HDR version) drive
--     real output; the SDR version has no HDR & Clarity tab

local here = arg[0]:gsub('[^/\\]+$', '')
package.path = here .. '?.lua;' .. package.path
local H = require('harness')
local root = here .. '../'
local BUILDS = {
    { name = 'ST6IX PP V1.1', script = root .. 'st6ix_pp_v1.1/ST6IX_PP_V1.1.lua',
      ref = root .. 'st6ix_pp_v1.1/build/src_ST6IX_V1.2.lua', hdr = false },
    { name = 'ST6IX PP V1.1 HDR', script = root .. 'st6ix_pp_v1.1/ST6IX_PP_V1.1_HDR.lua',
      ref = root .. 'st6ix_pp_v1.1/build/src_ST6IX_V1.2_HDR.lua', hdr = true },
}

local failures = 0
local function fail(msg) failures = failures + 1; print('FAIL ' .. msg) end
local function clean(S, label)
    for _, e in ipairs(S.errors) do fail(label .. ': ' .. e) end
    for _, e in ipairs(S.logs) do fail(label .. ' logged: ' .. e) end
end
local function with(a, b)
    local r = {}
    for k, v in pairs(a or {}) do r[k] = v end
    for k, v in pairs(b or {}) do r[k] = v end
    return r
end

local function scene(w, i)
    local t = i / 120
    w.sun = math.max(0, math.cos(t * 3.1)); w.twilight = 0.3
    w.fog = 0.1 + 0.3 * t; w.rain = t > 0.5 and 0.6 or 0; w.wetness = w.rain; w.water = w.rain * 0.5
    w.occlusion = (i % 60 < 10) and 0.2 or 1; w.interior = (i % 90 > 45)
    w.cbeAvg = 0.2 + w.sun; w.cbeMax = 1 + 3 * w.sun; w.cloud = 0.2 + 0.5 * t
    w.camHeading, w.sunHeading = 90 + 40 * t, 95
end

-- Keys only the extra FX write; everything else must match the V1.2 engine.
local function extraKey(k)
    return k:find('^pp:spice%.') or k == 'config:pp.brightness' or k:find('^cover%.')
end

for _, b in ipairs(BUILDS) do
    -- 1. V1.2 parity with the extra FX at their defaults.
    local looks = { {}, { ['Overall Mode'] = 1 }, { ['Overall Mode'] = 3 }, { ['Glare Style'] = 2 },
        { ['Sky Preset'] = 2, ['Morning Preset'] = 4 }, { ['Night Preset'] = 4, ['Reflection Preset'] = 2 },
        { ['Lens Profile'] = 2, ['Depth of Field'] = true, ['Chromatic Aberration'] = true } }
    if not b.hdr then
        looks[#looks + 1] = { ['Tone Curve'] = 2 }
        looks[#looks + 1] = { ['Tone Curve'] = 3 }
    end
    local same = 0
    for i, look in ipairs(looks) do
        local M = H.run(b.script, look, scene, 240, 1 / 60)
        local R = H.run(b.ref, look, scene, 240, 1 / 60)
        clean(M, b.name .. ' look ' .. i)
        local d = {}
        for _, k in ipairs(H.diff(M, R)) do
            if not extraKey(k) then d[#d + 1] = k end
        end
        if #d > 0 then fail(b.name .. ' look ' .. i .. ' differs from V1.2: ' .. table.concat(d, ', '))
        else same = same + 1 end
    end
    print(string.format('%s matches the V1.2 engine in %d/%d looks with the extra FX at defaults', b.name, same, #looks))

    -- 2. Every radio option runs cleanly.
    local probe = H.run(b.script, {}, scene, 1, 1 / 60)
    clean(probe, b.name .. ' init')
    if probe.controls['Render Quality'] then fail(b.name .. ' still shows Render Quality') end
    if (probe.controls['Clarity Preset'] ~= nil) ~= b.hdr then
        fail(b.name .. (b.hdr and ' lacks' or ' shows') .. ' the HDR & Clarity tab')
    end
    local runs = 0
    for _, name in ipairs(probe.order) do
        local c = probe.controls[name]
        if c.kind == 'radio' then
            for opt = 1, c.count do
                clean(H.run(b.script, { [name] = opt, ['Clarity Preset'] = 6, ['Film Grain'] = true },
                    scene, 30, 1 / 60), b.name .. ' ' .. name .. '=' .. opt)
                runs = runs + 1
            end
        end
    end
    print(string.format('%s: %d radio options run cleanly', b.name, runs))

    -- 3. Extra FX drive real output.
    local function last(values, key)
        local S = H.run(b.script, values, scene, 60, 1 / 60)
        clean(S, b.name .. ' fx')
        return S.last[key] and S.last[key][1], S
    end
    if b.hdr then
        local c0 = last({}, 'config:pp.contrast')
        local c3 = last({ ['Clarity Preset'] = 3 }, 'config:pp.contrast')
        if not (c3 > c0 * 1.05) then fail(b.name .. ' Full HDR clarity does not raise contrast') end
        local s0 = last({ ['Clarity Preset'] = 6, Sharpness = 0 }, 'pp:spice.Sharpen.strength')
        local s1 = last({ ['Clarity Preset'] = 6, Sharpness = 0.8 }, 'pp:spice.Sharpen.strength')
        if not (s0 == 0 and s1 > 0.3) then fail(b.name .. ' Sharpness has no effect') end
        local m0 = last({ ['Clarity Preset'] = 6, ['Highlight Recovery'] = 0 }, 'exposure.cbe.setMultiplier')
        local m1 = last({ ['Clarity Preset'] = 6, ['Highlight Recovery'] = 0.6 }, 'exposure.cbe.setMultiplier')
        if not (m1 < m0) then fail(b.name .. ' Highlight Recovery does not lower exposure') end
    end
    local g = last({ ['Film Grain'] = true, ['Film Grain Strength'] = 2 }, 'pp:spice.SensorNoise.strength')
    if not (g and g > 1) then fail(b.name .. ' Film Grain has no effect') end
    local textures = {}
    for index = 2, 7 do
        local _, dome = last({ ['Skydome Preset'] = index }, 'cover.colorMultiplier')
        if not (dome.accum['cover.setTexture'] and dome.last['cover.colorMultiplier'][1] > 5) then
            fail(b.name .. ' skydome ' .. index .. ' does not load')
        end
        local tex = dome.last['cover.setTexture'] and dome.last['cover.setTexture'][1]
        if textures[tex] then fail(b.name .. ' skydomes ' .. textures[tex] .. ' and ' .. index .. ' share a texture') end
        textures[tex] = index
    end
    print(b.name .. ': skydomes and film grain' .. (b.hdr and ', clarity, sharpness and recovery' or '') .. ' checked')
end

print(failures == 0 and '\nALL ST6IX PP V1.1 CHECKS PASSED' or ('\n' .. failures .. ' FAILURES'))
os.exit(failures == 0 and 0 or 1)
