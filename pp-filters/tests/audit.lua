-- Usage: luajit tests/audit.lua <script.lua>
-- Reports script errors, dead controls and radio options that behave identically.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local script = assert(arg[1], 'script path required')

local FRAMES, DT = 160, 0.1

local SCENES = {
    { 'clear day', function(w) end },
    { 'facing low sun', function(w)
        w.sunElevation, w.camHeading, w.sunHeading, w.camElevation = 12, 90, 90, 10
        w.cbeMax = 9
    end },
    { 'twilight', function(w)
        w.sun, w.twilight, w.sunElevation, w.moonElevation = 0.5, 0.8, -2, 5
        w.exposure, w.cbeAvg = 0.45, 0.5
    end },
    { 'night', function(w)
        w.sun, w.sunElevation, w.moonElevation = 0, -30, 40
        w.exposure, w.cbeAvg, w.cbeMax, w.smog = 0.6, 0.2, 2, 0.5
    end },
    { 'heavy rain', function(w)
        w.sun, w.overcast, w.cloud, w.badness = 0.9, 0.9, 0.95, 0.7
        w.rain, w.wetness, w.water, w.fog, w.mist, w.cloudShadow = 0.8, 0.9, 0.6, 0.3, 0.3, 0.8
    end },
    { 'dense fog', function(w)
        w.sun, w.sunElevation, w.fog, w.mist, w.humidity = 0.8, 8, 0.85, 0.8, 0.95
    end },
    { 'tunnel exit', function(w, i)
        w.occlusion = i <= FRAMES / 2 and 0.15 or 0.95
        w.exposure = i <= FRAMES / 2 and 0.7 or 0.2
    end },
    { 'wet cockpit night', function(w)
        w.sun, w.sunElevation, w.moonElevation, w.interior = 0, -25, 10, true
        w.rain, w.wetness, w.water, w.cbeAvg, w.cbeMax, w.exposure = 0.5, 0.9, 0.7, 0.3, 10, 0.9
    end },
    { 'sunset timelapse', function(w, i)
        local t = i / FRAMES
        w.sun = 1 - t
        w.sunElevation = 20 - 30 * t
        w.moonElevation = -10 + 40 * t
        w.overcast, w.cloud = 0.6 * t, 0.3 + 0.5 * t
        w.exposure = 0.3 + 0.4 * t
    end },
    { 'camera switching telephoto', function(w, i)
        w.interior = math.floor(i / 20) % 2 == 1
        w.occlusion = w.interior and 0.55 or 1
        w.fov = w.interior and 75 or 22
        w.camHeading, w.sunHeading, w.sunElevation, w.camElevation = 100, 95, 15, 8
        w.cbeMax = w.interior and 12 or 4
    end },
}

local function merge(a, b)
    local r = {}
    for k, v in pairs(a) do r[k] = v end
    for k, v in pairs(b or {}) do r[k] = v end
    return r
end

-- Discover controls and catch init/update errors under defaults.
local probe = H.run(script, {}, SCENES[1][2], 2, DT)
local controls, order = probe.controls, probe.order
local fatal = false
for _, e in ipairs(probe.errors) do print('ERROR ' .. e); fatal = true end

for _, sc in ipairs(SCENES) do
    local s = H.run(script, {}, sc[2], FRAMES, DT)
    for _, e in ipairs(s.errors) do print('ERROR [' .. sc[1] .. '] ' .. e); fatal = true end
end

local allOn, allOff = {}, {}
for name, c in pairs(controls) do
    if c.kind == 'check' then allOn[name] = true; allOff[name] = false end
end

local contexts = { { 'defaults', {} }, { 'all toggles on', allOn }, { 'all toggles off', allOff } }
for _, name in ipairs(order) do
    local c = controls[name]
    if c.kind == 'radio' then
        for opt = 1, c.count do
            if opt ~= c.default then
                contexts[#contexts + 1] = { name .. '=' .. opt, merge(allOn, { [name] = opt }) }
                contexts[#contexts + 1] = { name .. '=' .. opt .. ' (defaults)', { [name] = opt } }
            end
        end
    end
end

local cache = {}
local function runCached(ctxIndex, sceneIndex, override)
    local key = ctxIndex .. '|' .. sceneIndex
    if not override then
        if not cache[key] then
            cache[key] = H.run(script, contexts[ctxIndex][2], SCENES[sceneIndex][2], FRAMES, DT)
        end
        return cache[key]
    end
    return H.run(script, merge(contexts[ctxIndex][2], override), SCENES[sceneIndex][2], FRAMES, DT)
end

local function probesFor(c)
    if c.kind == 'check' then return { true, false } end
    if c.kind == 'radio' then
        local p = {}
        for i = 1, c.count do p[#p + 1] = i end
        return p
    end
    local span = c.max - c.min
    local lo, hi = c.min + span * 0.15, c.min + span * 0.85
    if c.kind == 'int' then lo, hi = math.floor(lo + 0.5), math.floor(hi + 0.5) end
    return { lo, hi, c.min, c.max }
end

local function affects(name, value)
    for ci = 1, #contexts do
        local base = contexts[ci][2][name]
        if base == nil then base = controls[name].default end
        if value ~= base then
            for si = 1, #SCENES do
                local a = runCached(ci, si)
                local b = runCached(ci, si, { [name] = value })
                if #H.diff(a, b) > 0 then return contexts[ci][1], SCENES[si][1] end
            end
        end
    end
    return nil
end

local dead, deadOptions, twins = 0, 0, 0
for _, name in ipairs(order) do
    local c = controls[name]
    local anyEffect = false
    for _, v in ipairs(probesFor(c)) do
        local ctx = affects(name, v)
        if ctx then anyEffect = true
        elseif c.kind == 'radio' and v ~= c.default then
            print(string.format('DEAD OPTION  %-34s option %d never changes the output', name, v))
            deadOptions = deadOptions + 1
        end
        if anyEffect and c.kind ~= 'radio' then break end
    end
    if not anyEffect then
        print(string.format('DEAD CONTROL %-34s (%s) never changes the output', name, c.kind))
        dead = dead + 1
    end
end

for _, name in ipairs(order) do
    if not H.reads[name] then
        print('UNREAD       ' .. name .. ' is declared but never read')
    end
end

-- Radio options that are indistinguishable from each other in every scene.
for _, name in ipairs(order) do
    local c = controls[name]
    if c.kind == 'radio' then
        local runs = {}
        for opt = 1, c.count do
            runs[opt] = {}
            for ci, ctx in ipairs({ {}, allOn }) do
                for si = 1, #SCENES do
                    runs[opt][#runs[opt] + 1] =
                        H.run(script, merge(ctx, { [name] = opt }), SCENES[si][2], FRAMES, DT)
                end
            end
        end
        for i = 1, c.count do
            for j = i + 1, c.count do
                local same = true
                for k = 1, #runs[i] do
                    if #H.diff(runs[i][k], runs[j][k]) > 0 then same = false; break end
                end
                if same then
                    print(string.format('TWIN OPTIONS %-34s options %d and %d produce identical output', name, i, j))
                    twins = twins + 1
                end
            end
        end
    end
end

local n = 0
for _ in pairs(controls) do n = n + 1 end
print(string.format('\n%d controls audited: %d dead controls, %d dead radio options, %d identical option pairs%s',
    n, dead, deadOptions, twins, fatal and ', SCRIPT ERRORS PRESENT' or ''))
os.exit((dead + deadOptions + twins == 0 and not fatal) and 0 or 1)
