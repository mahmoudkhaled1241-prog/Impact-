-- Offline harness for ST6IX Pure PP scripts (LuaJIT).
-- Mocks the Pure / CSP API surface, runs the script through scripted scenes
-- and records every value the script writes to the game.

local H = { reads = {} }

local function fmt(v)
    local t = type(v)
    if t == 'number' then return v end
    if t == 'boolean' then return v and 1 or 0 end
    if t == 'table' then
        if v.__kind == 'rgb' then return {v.r, v.g, v.b} end
        if v.__kind == 'vec2' then return {v.x, v.y} end
        return 0
    end
    if t == 'string' then
        local h = 0
        for i = 1, #v do h = (h * 31 + v:byte(i)) % 1000003 end
        return h
    end
    return 0
end

local function flatten(args)
    local out = {}
    for i = 1, args.n do
        local f = fmt(args[i])
        if type(f) == 'table' then
            for _, x in ipairs(f) do out[#out + 1] = x end
        else
            out[#out + 1] = f
        end
    end
    return out
end

local function pack(...) return { n = select('#', ...), ... } end

function H.new(scriptPath)
    local S = {
        controls = {}, order = {}, values = {}, reads = {},
        accum = {}, last = {}, errors = {}, late = {},
        world = {}, frame = 0, starWritten = nil,
    }

    local function record(key, args)
        local flat = flatten(args)
        local acc = S.accum[key]
        if not acc then acc = {}; S.accum[key] = acc end
        for i, x in ipairs(flat) do
            if x ~= x or x == math.huge or x == -math.huge then
                S.errors[#S.errors + 1] = 'non-finite value written to ' .. key
                x = 0
            end
            acc[i] = (acc[i] or 0) + x
        end
        S.last[key] = flat
    end

    local function recorder(prefix)
        return setmetatable({}, { __index = function(t, k)
            local f = function(...) record(prefix .. k, pack(...)) end
            rawset(t, k, f)
            return f
        end })
    end

    local function addControl(kind, name, default, a, b)
        if S.controls[name] then
            S.errors[#S.errors + 1] = 'duplicate control name: ' .. name
        end
        local c = { kind = kind, name = name, default = default, min = a, max = b }
        if kind == 'radio' then
            local n = 0
            for _ in tostring(a):gmatch('[^,]+') do n = n + 1 end
            c.count = n
            c.min, c.max = 1, n
            if type(default) ~= 'number' or default < 1 or default > n then
                S.errors[#S.errors + 1] = 'radio default out of range: ' .. name
            end
        end
        if (kind == 'slider' or kind == 'int') and (default < a or default > b) then
            S.errors[#S.errors + 1] = 'slider default outside range: ' .. name
        end
        S.controls[name] = c
        S.order[#S.order + 1] = name
        S.values[name] = default
    end

    local ui = {
        addPage = function() end,
        addText = function() end,
        addSeparator = function() end,
        addSliderFloat = function(n, d, a, b) addControl('slider', n, d, a, b) end,
        addSliderInteger = function(n, d, a, b) addControl('int', n, d, a, b) end,
        addCheckbox = function(n, d) addControl('check', n, d) end,
        addRadioButtons = function(n, d, opts) addControl('radio', n, d, opts) end,
        addStateFloat = function(n) S.values[n] = 0 end,
        addStateString = function(n) S.values[n] = '' end,
        getValue = function(n)
            S.reads[n] = true
            H.reads[n] = true
            if S.controls[n] == nil and S.values[n] == nil then
                S.errors[#S.errors + 1] = 'getValue of undeclared control: ' .. tostring(n)
            end
            return S.values[n]
        end,
        setValue = function(n, v) record('ui.state:' .. n, pack(v)) end,
        setString = function(n, v) record('ui.state:' .. n, pack(v)) end,
    }

    local W = S.world
    local pure = {
        script = { ui = ui, setVersion = function() end, setAuthor = function() end,
            tools = recorder('script.tools.') },
        config = { set = function(k, v, rel) record('config:' .. k, pack(v)) end,
            get = function() return nil end },
        yebis = { set = function(k, v) record('yebis:' .. k, pack(v)) end },
        mod = {
            sun = function() return W.sun end,
            night = function() return 1 - W.sun end,
            twilight = function() return W.twilight or 0 end,
        },
        camera = setmetatable({
            getFOV = function() return W.fov end,
            getOcclusion = function() return W.occlusion end,
            getHeading = function() return W.camHeading end,
            getElevation = function() return W.camElevation end,
        }, { __index = recorder('camera.') }),
        world = {
            getOvercast = function() return W.overcast end,
            getCloudCoverage = function() return W.cloud end,
            getBadness = function() return W.badness end,
            getFog = function() return W.fog end,
            getHumidity = function() return W.humidity end,
            getMist = function() return W.mist end,
            getSmog = function() return W.smog end,
            getCloudShadow = function() return W.cloudShadow end,
            getRainFX_Intensity = function() return W.rain end,
            getRainFX_Wetness = function() return W.wetness end,
            getRainFX_Water = function() return W.water end,
            getPureGammaFogTable = function()
                return { distance = 25000, blend = 0.9, density = 0.4 + W.fog,
                    exponent = 0.6, height = 3000, backlit = 0.35,
                    color = { __kind = 'rgb', r = 0.7, g = 0.74, b = 0.8 },
                    horizont = { multiplier = 0.5, exponent = 1.2, height = 200 } }
            end,
        },
        stellar = setmetatable({
            getSunHeading = function() return W.sunHeading end,
            getSunElevation = function() return W.sunElevation end,
            getMoonElevation = function() return W.moonElevation end,
            getStarsBrightness = function()
                if S.starFeedback and S.starWritten then return S.starWritten end
                return 100 * (1 - W.sun)
            end,
            setStarsBrightness = function(v)
                S.starWritten = v
                record('stellar.setStarsBrightness', pack(v))
            end,
        }, { __index = recorder('stellar.') }),
        exposure = setmetatable({
            getCalculatedValue = function() return W.exposure end,
            getValue = function() return W.exposure end,
            cbe = recorder('exposure.cbe.'),
            yebis = recorder('exposure.yebis.'),
        }, { __index = recorder('exposure.') }),
        light = recorder('light.'),
        pp = setmetatable({
            set = function(k, v) record('pp:' .. k, pack(v)) end,
            getGammaModulator = function() return 1 end,
            getGodraysModulator = function() return W.godrayMod or 1 end,
            setCustomRGBTonemapping = function(t)
                S.tonemapTable = t
                local a = pack(t.shader and #t.shader or 0)
                local keys = {}
                for k in pairs(t.values) do keys[#keys + 1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do a.n = a.n + 1; a[a.n] = t.values[k] end
                record('pp.setCustomRGBTonemapping', a)
            end,
        }, { __index = recorder('pp.') }),
    }

    local acRec = recorder('ac.')
    local ac = setmetatable({
        TonemapFunction = { Linear = 0, Uchimura = 7, Lottes = 8, Sensitometric = 2 },
        isInteriorView = function() return W.interior end,
        getCubemapBrightnessEstimationAverage = function() return W.cbeAvg end,
        getCubemapBrightnessEstimationMaximum = function() return W.cbeMax end,
        onPostProcessing = function(fn) S.late[#S.late + 1] = fn end,
        debug = function() end,
    }, { __index = acRec })

    local env = setmetatable({
        pure = pure, ac = ac,
        rgb = function(r, g, b) return { __kind = 'rgb', r = r, g = g, b = b } end,
        vec2 = function(x, y) return { __kind = 'vec2', x = x, y = y } end,
        math = setmetatable({
            lerp = function(a, b, t) return a + (b - a) * t end,
        }, { __index = math }),
    }, { __index = _G })
    env._G = env

    local chunk, err = loadfile(scriptPath)
    if not chunk then error(err) end
    setfenv(chunk, env)
    chunk()
    S.env = env
    return S
end

function H.defaultWorld()
    return {
        sun = 1, twilight = 0, fov = 50, occlusion = 1, camHeading = 180, camElevation = 0,
        overcast = 0, cloud = 0.2, badness = 0, fog = 0.05, humidity = 0.3, mist = 0,
        smog = 0.1, cloudShadow = 0, rain = 0, wetness = 0, water = 0,
        sunHeading = 90, sunElevation = 45, moonElevation = -20,
        exposure = 0.3, cbeAvg = 1, cbeMax = 3, interior = false,
    }
end

-- Runs a full session: init, then `frames` updates while `scene(world, i)` mutates the world.
function H.run(scriptPath, controlValues, scene, frames, dt, opts)
    opts = opts or {}
    local S = H.new(scriptPath)
    S.starFeedback = opts.starFeedback
    for k, v in pairs(H.defaultWorld()) do S.world[k] = v end
    local ok, e = pcall(S.env.init_pure_script)
    if not ok then S.errors[#S.errors + 1] = 'init: ' .. tostring(e); return S end
    for k, v in pairs(controlValues or {}) do S.values[k] = v end
    S.accum, S.last = {}, {}
    for i = 1, frames do
        S.frame = i
        scene(S.world, i)
        ok, e = pcall(S.env.update_pure_script, dt)
        if not ok then S.errors[#S.errors + 1] = 'update frame ' .. i .. ': ' .. tostring(e); break end
        for _, fn in ipairs(S.late) do
            ok, e = pcall(fn, {})
            if not ok then S.errors[#S.errors + 1] = 'late hook: ' .. tostring(e); break end
        end
    end
    return S
end

function H.diff(a, b)
    local changed = {}
    for k, va in pairs(a.accum) do
        local vb = b.accum[k]
        if not vb then changed[#changed + 1] = k
        else
            for i = 1, math.max(#va, #vb) do
                local x, y = va[i] or 0, vb[i] or 0
                if math.abs(x - y) > 1e-7 * (1 + math.abs(x) + math.abs(y)) then
                    changed[#changed + 1] = k
                    break
                end
            end
        end
    end
    for k in pairs(b.accum) do
        if not a.accum[k] then changed[#changed + 1] = k end
    end
    return changed
end

return H
