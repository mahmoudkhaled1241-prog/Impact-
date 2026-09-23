-- Usage: luajit tests/gt7_math.lua <script.lua>
-- CPU port of the GT7 shader, fed with the exact uniforms the script sends to
-- Pure, used to check the curve's photographic behaviour.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local script = assert(arg[1], 'script path required')

local M709to2020 = {{0.6274040,0.3292820,0.0433136},{0.0690970,0.9195400,0.0113612},{0.0163916,0.0880132,0.8955950}}
local M2020to709 = {{1.6604902958,-0.5876391058,-0.0728515982},{-0.1245499701,1.1328999220,-0.0083479642},{-0.0181511189,-0.1005787239,1.1187298782}}
local M2020toLms = {{0.4121093750,0.5239257812,0.0639648438},{0.1667480469,0.7204589844,0.1127929688},{0.0241699219,0.0754394531,0.9003906250}}
local MLmsTo2020 = {{3.4366066943,-2.5064521187,0.0698454243},{-0.7913295556,1.9836004518,-0.1922708962},{-0.0259498997,-0.0989137147,1.1248636144}}
local MLmsToIctcp = {{0.5,0.5,0},{1.6137695312,-3.3234863281,1.7097167969},{4.3781738281,-4.2456054688,-0.1325683594}}
local MIctcpToLms = {{1,0.0086090370,0.1110296250},{1,-0.0086090370,-0.1110296250},{1,0.5600313357,-0.3206271750}}
local m1, m2, c1, c2, c3 = 0.1593017578125, 78.84375, 0.8359375, 18.8515625, 18.6875

local function mul(m, v)
    return { m[1][1]*v[1]+m[1][2]*v[2]+m[1][3]*v[3], m[2][1]*v[1]+m[2][2]*v[2]+m[2][3]*v[3],
        m[3][1]*v[1]+m[3][2]*v[2]+m[3][3]*v[3] }
end
local function map(v, f) return { f(v[1]), f(v[2]), f(v[3]) } end
local function smoothstep(a, b, x) local t = math.max(0, math.min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) end
local function pq(n) n = math.max(n, 0) ^ m1; return ((c1 + c2 * n) / (1 + c3 * n)) ^ m2 end
local function pqInv(p) p = math.max(p, 0) ^ (1 / m2); return (math.max(p - c1, 0) / (c2 - c3 * p)) ^ (1 / m1) end
local function toUcs(rgb) return mul(MLmsToIctcp, map(mul(M2020toLms, rgb), function(x) return pq(x * 0.01) end)) end
local function fromUcs(u) return mul(MLmsTo2020, map(mul(MIctcpToLms, u), function(x) return pqInv(x) * 100 end)) end

local function tonemap(v, color)
    local function curve(x)
        if x < 0 then return 0 end
        if x < v.gtLinear * v.gtPeak then
            local toe = v.gtMid * (x / v.gtMid) ^ v.gtToe
            local w = smoothstep(0, v.gtMid, x)
            return toe + (x - toe) * w
        end
        return v.gtKA + v.gtKB * math.exp(x * v.gtKC)
    end
    local rgb = map(mul(M709to2020, map(color, function(x) return math.max(x, 0) end)),
        function(x) return x * v.gtInputScale end)
    local ucs = toUcs(rgb)
    local skewed = map(rgb, curve)
    local skewedUcs = toUcs(skewed)
    local chroma = 1 - smoothstep(v.gtFadeStart, v.gtFadeEnd, ucs[1] / v.gtTargetI)
    local scaled = fromUcs({ skewedUcs[1], ucs[2] * chroma, ucs[3] * chroma })
    local blended = { skewed[1] + (scaled[1] - skewed[1]) * v.gtBlend,
        skewed[2] + (scaled[2] - skewed[2]) * v.gtBlend, skewed[3] + (scaled[3] - skewed[3]) * v.gtBlend }
    local c = map(mul(M2020to709, map(blended, function(x) return math.min(x, v.gtPeak) / v.gtPeak end)),
        function(x) return math.max(x, 0) end)
    local peak = math.max(c[1], c[2], c[3])
    local l = 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
    if peak > 1 then
        if l >= 1 then c = {1, 1, 1}
        else c = map(c, function(x) return l + (x - l) * ((1 - l) / (peak - l)) end) end
    end
    return map(c, function(x) return math.max(0, math.min(1, x)) end)
end

local failures = 0
local function check(ok, label, detail)
    print((ok and 'PASS ' or 'FAIL ') .. label .. (detail and ('  (' .. detail .. ')') or ''))
    if not ok then failures = failures + 1 end
end

local S = H.run(script, { ['Tone Curve'] = 4, ['Scene Aware Tone Mapping'] = false }, function() end, 5, 0.1)
local v = S.tonemapTable.values
local function luma(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end
local function sat(c) local hi, lo = math.max(c[1], c[2], c[3]), math.min(c[1], c[2], c[3]); return hi > 0 and (hi - lo) / hi or 0 end

check(luma(tonemap(v, {0, 0, 0})) < 1e-9, 'black stays black')
local grey = tonemap(v, {0.18, 0.18, 0.18})
check(math.abs(luma(grey) - 0.18) < 0.18 * 0.05, 'mid grey 0.18 is preserved within 5%', string.format('%.4f', luma(grey)))
check(sat(grey) < 1e-3, 'grey stays neutral (no colour cast)', string.format('%.5f', sat(grey)))

local prev, monotonic, maxOut = -1, true, 0
for i = 0, 400 do
    local x = (i / 400) ^ 3 * 20
    local out = luma(tonemap(v, {x, x, x}))
    if out < prev - 1e-6 then monotonic = false end
    prev, maxOut = out, math.max(maxOut, out)
end
check(monotonic, 'brightness never reverses across a 0..20 ramp')
check(maxOut <= 1 + 1e-6, 'output never exceeds display white', string.format('%.4f', maxOut))
check(luma(tonemap(v, {1, 1, 1})) > 0.7 and luma(tonemap(v, {1, 1, 1})) < 1, 'scene white rolls off smoothly below clip',
    string.format('%.3f', luma(tonemap(v, {1, 1, 1}))))
check(luma(tonemap(v, {20, 20, 20})) > 0.99, 'very bright light reaches white')

local x = v.gtLinear * v.gtPeak
local below = v.gtKA + v.gtKB * math.exp((x - 1e-6) * v.gtKC)
check(math.abs(below - x) < 1e-4, 'shoulder joins the linear section without a step', string.format('%.6f vs %.6f', below, x))

local inRange = true
for _, c in ipairs({ {4, 0.2, 0.1}, {0.05, 3, 0.2}, {0.1, 0.3, 6}, {0.8, 0.6, 0.02}, {12, 12, 0}, {0.02, 0.01, 0.4} }) do
    local o = tonemap(v, c)
    for i = 1, 3 do if o[i] ~= o[i] or o[i] < 0 or o[i] > 1.0001 then inRange = false end end
end
check(inRange, 'saturated colours stay finite and inside 0..1')
local hot = {4, 0.2, 0.1}
local hotOut = tonemap(v, hot)
check(hotOut[1] > hotOut[2] and hotOut[2] > hotOut[3], 'out-of-gamut highlights keep their hue order when fitted',
    string.format('%.3f %.3f %.3f', hotOut[1], hotOut[2], hotOut[3]))

local midRed, hotRed = tonemap(v, {0.3, 0.03, 0.03}), tonemap(v, {8, 0.8, 0.8})
check(sat(hotRed) < sat(midRed), 'bright saturated lights desaturate toward white like film',
    string.format('%.3f -> %.3f', sat(midRed), sat(hotRed)))

local soft = H.run(script, { ['Tone Curve'] = 4, ['Scene Aware Tone Mapping'] = false, ['GT7 Chroma Blend'] = 0 }, function() end, 5, 0.1)
local vSkew = soft.tonemapTable.values
local amber = {1.6, 0.9, 0.1}
local function hueRatio(c) return (c[2] - c[3]) / math.max(c[1] - c[3], 1e-6) end
local skewHue, blendHue, inHue = hueRatio(tonemap(vSkew, amber)), hueRatio(tonemap(v, amber)), hueRatio(amber)
check(math.abs(blendHue - inHue) < math.abs(skewHue - inHue), 'Chroma Blend keeps bright colours closer to their true hue',
    string.format('input %.3f, blended %.3f, per-channel %.3f', inHue, blendHue, skewHue))

print(failures == 0 and '\nGT7 CURVE CHECKS PASSED' or ('\n' .. failures .. ' GT7 CHECKS FAILED'))
os.exit(failures == 0 and 0 or 1)
