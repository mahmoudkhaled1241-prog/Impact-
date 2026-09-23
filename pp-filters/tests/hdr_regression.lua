-- Usage: luajit tests/hdr_regression.lua <baseline.lua> <candidate.lua>
-- Proves the HDR chain (exposure, tone curves, custom AgX, gamma, filmic, final
-- contrast/saturation) is bit-identical between two script versions.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local baseline, candidate = assert(arg[1]), assert(arg[2])
local FRAMES, DT = 160, 0.1

local function protected(key)
    return key == 'pp.setCustomRGBTonemapping'
        or key == 'pp.setTonemapping'
        or key == 'ac.setPpTonemapGamma'
        or key == 'yebis:filmicContrast'
        or key == 'config:pp.contrast'
        or key == 'config:pp.saturation'
        or key:find('^config:ppTonemap') ~= nil
        or key:find('^exposure%.') ~= nil
end

local SCENES = {
    function() end,
    function(w) w.sun, w.sunElevation, w.moonElevation, w.exposure, w.cbeAvg = 0, -30, 40, 0.6, 0.2 end,
    function(w) w.sun, w.sunElevation, w.twilight = 0.5, -2, 0.8 end,
    function(w) w.overcast, w.cloud, w.badness, w.rain, w.wetness, w.water, w.fog = 0.9, 0.95, 0.7, 0.8, 0.9, 0.6, 0.3 end,
    function(w) w.fog, w.mist, w.humidity, w.sunElevation = 0.85, 0.8, 0.95, 8 end,
    function(w, i) w.occlusion = i <= FRAMES / 2 and 0.15 or 0.95 end,
    function(w, i) w.interior = math.floor(i / 20) % 2 == 1; w.fov = w.interior and 75 or 22 end,
    function(w, i) local t = i / FRAMES; w.sun, w.sunElevation, w.cbeMax = 1 - t, 20 - 30 * t, 2 + 8 * t end,
    function(w) w.sunElevation, w.camHeading, w.sunHeading, w.camElevation, w.cbeMax = 12, 90, 90, 10, 9 end,
}

local seed = 12345
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

local probe = H.run(baseline, {}, SCENES[1], 1, DT)
local shared = {}
local cand = H.run(candidate, {}, SCENES[1], 1, DT)
for _, name in ipairs(probe.order) do
    if cand.controls[name] then shared[#shared + 1] = probe.controls[name] end
end

local configs = { {} }
for _ = 1, 40 do
    local cfg = {}
    for _, c in ipairs(shared) do
        if rnd() < 0.5 then
            if c.kind == 'check' then cfg[c.name] = rnd() < 0.5
            elseif c.kind == 'radio' then cfg[c.name] = 1 + math.floor(rnd() * c.count)
            elseif c.kind == 'int' then cfg[c.name] = c.min + math.floor(rnd() * (c.max - c.min + 1))
            else cfg[c.name] = c.min + rnd() * (c.max - c.min) end
        end
    end
    configs[#configs + 1] = cfg
end

local failures = 0
for ci, cfg in ipairs(configs) do
    for si, scene in ipairs(SCENES) do
        local a = H.run(baseline, cfg, scene, FRAMES, DT)
        local b = H.run(candidate, cfg, scene, FRAMES, DT)
        for _, e in ipairs(b.errors) do print('ERROR candidate: ' .. e); failures = failures + 1 end
        for _, key in ipairs(H.diff(a, b)) do
            if protected(key) then
                failures = failures + 1
                print(string.format('HDR CHANGE config %d scene %d: %s', ci, si, key))
            end
        end
    end
end

print(string.format('%d configurations x %d scenes compared: %s',
    #configs, #SCENES, failures == 0 and 'HDR chain identical' or (failures .. ' differences')))
os.exit(failures == 0 and 0 or 1)
