-- ST6IX Gamma V1.9 unified photographic rendering system
-- Pure Gamma 3.50 / CSP dynamic tonemapping
-- Twelve control pages. Every slider is live in every overall mode.

local VERSION = 1.90
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

-- GT7-style tone mapping after Polyphony Digital's published method: a
-- toe/linear/shoulder curve per channel, blended with a hue-preserving version
-- rebuilt in ICtCp, with chroma faded out as highlights approach peak white.
-- Framebuffer units follow GT7: 1.0 = 100 nits, SDR paper white = 2.5.
local GT7_PQ = { m1 = 0.1593017578125, m2 = 78.84375,
    c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875 }

local gt7Tonemap = {
    cacheKey = 7,
    values = { gtInputScale=2.5, gtPeak=2.5, gtMid=0.538, gtLinear=0.444, gtToe=1.28,
        gtKA=0, gtKB=0, gtKC=0, gtBlend=0.6, gtFadeStart=0.98, gtFadeEnd=1.16, gtTargetI=1 },
    shader = [[
    #define ST6IX_GT_M1 0.1593017578125
    #define ST6IX_GT_M2 78.84375
    #define ST6IX_GT_C1 0.8359375
    #define ST6IX_GT_C2 18.8515625
    #define ST6IX_GT_C3 18.6875

    static const float3x3 st6ixGt709To2020 = float3x3(
        0.6274040000, 0.3292820000, 0.0433136000,
        0.0690970000, 0.9195400000, 0.0113612000,
        0.0163916000, 0.0880132000, 0.8955950000);
    static const float3x3 st6ixGt2020To709 = float3x3(
        1.6604902958, -0.5876391058, -0.0728515982,
       -0.1245499701,  1.1328999220, -0.0083479642,
       -0.0181511189, -0.1005787239,  1.1187298782);
    static const float3x3 st6ixGt2020ToLms = float3x3(
        0.4121093750, 0.5239257812, 0.0639648438,
        0.1667480469, 0.7204589844, 0.1127929688,
        0.0241699219, 0.0754394531, 0.9003906250);
    static const float3x3 st6ixGtLmsTo2020 = float3x3(
        3.4366066943, -2.5064521187,  0.0698454243,
       -0.7913295556,  1.9836004518, -0.1922708962,
       -0.0259498997, -0.0989137147,  1.1248636144);
    static const float3x3 st6ixGtLmsToIctcp = float3x3(
        0.5000000000,  0.5000000000,  0.0000000000,
        1.6137695312, -3.3234863281,  1.7097167969,
        4.3781738281, -4.2456054688, -0.1325683594);
    static const float3x3 st6ixGtIctcpToLms = float3x3(
        1.0000000000,  0.0086090370,  0.1110296250,
        1.0000000000, -0.0086090370, -0.1110296250,
        1.0000000000,  0.5600313357, -0.3206271750);

    float3 st6ixGtPq(float3 n) {
        n = pow(max(n, 0.0), ST6IX_GT_M1);
        return pow((ST6IX_GT_C1 + ST6IX_GT_C2 * n) / (1.0 + ST6IX_GT_C3 * n), ST6IX_GT_M2);
    }

    float3 st6ixGtPqInverse(float3 p) {
        p = pow(max(p, 0.0), 1.0 / ST6IX_GT_M2);
        return pow(max(p - ST6IX_GT_C1, 0.0) / (ST6IX_GT_C2 - ST6IX_GT_C3 * p), 1.0 / ST6IX_GT_M1);
    }

    float3 st6ixGtToUcs(float3 rgb) {
        return mul(st6ixGtLmsToIctcp, st6ixGtPq(mul(st6ixGt2020ToLms, rgb) * 0.01));
    }

    float3 st6ixGtFromUcs(float3 ucs) {
        return mul(st6ixGtLmsTo2020, st6ixGtPqInverse(mul(st6ixGtIctcpToLms, ucs)) * 100.0);
    }

    float st6ixGtCurve(float x) {
        if (x < 0.0) return 0.0;
        if (x < gtLinear * gtPeak) {
            float toe = gtMid * pow(x / gtMid, gtToe);
            return lerp(toe, x, smoothstep(0.0, gtMid, x));
        }
        return gtKA + gtKB * exp(x * gtKC);
    }

    // Wide-gamut highlights can leave the Rec.709 range after conversion; they
    // are pulled toward their own luminance, keeping hue instead of clipping it.
    float3 st6ixGtFitDisplay(float3 c) {
        float peak = max(c.r, max(c.g, c.b));
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        if (peak > 1.0) {
            c = luma >= 1.0 ? float3(1.0, 1.0, 1.0) : luma + (c - luma) * ((1.0 - luma) / (peak - luma));
        }
        return saturate(c);
    }

    float3 tonemapping(float3 color) {
        float3 rgb = mul(st6ixGt709To2020, max(color, 0.0)) * gtInputScale;
        float3 ucs = st6ixGtToUcs(rgb);
        float3 skewed = float3(st6ixGtCurve(rgb.r), st6ixGtCurve(rgb.g), st6ixGtCurve(rgb.b));
        float3 skewedUcs = st6ixGtToUcs(skewed);
        float chroma = 1.0 - smoothstep(gtFadeStart, gtFadeEnd, ucs.x / gtTargetI);
        float3 scaled = st6ixGtFromUcs(float3(skewedUcs.x, ucs.y * chroma, ucs.z * chroma));
        float3 blended = lerp(skewed, scaled, gtBlend);
        return st6ixGtFitDisplay(max(mul(st6ixGt2020To709, min(blended, gtPeak) / gtPeak), 0.0));
    }
]]
}

-- Shoulder constants and the peak's ICtCp intensity are solved on the CPU once
-- per frame so the shader only evaluates the curve.
local function updateGt7Curve(v, exposure, peak, alpha, linear, toe, blend)
    local k = (linear - 1) / (alpha - 1)
    v.gtPeak = peak
    v.gtInputScale = exposure * peak
    v.gtLinear = linear
    v.gtToe = toe
    v.gtBlend = blend
    v.gtKA = peak * linear + peak * k
    v.gtKB = -peak * k * math.exp(linear / k)
    v.gtKC = -1 / (k * peak)
    local n = (peak * 0.01) ^ GT7_PQ.m1
    v.gtTargetI = ((GT7_PQ.c1 + GT7_PQ.c2 * n) / (1 + GT7_PQ.c3 * n)) ^ GT7_PQ.m2
end

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

-- Colour profiles are a grade layered after the look: saturation and contrast
-- multipliers, a Kelvin shift (+ is cooler), a hue tint, vibrance, a black
-- fade and sepia. The first entry of each list is the neutral manual base.
local DAY_COLOR_PROFILES = {
    [1] = {sat=1.00, contrast=1.00, temp=0,    tint=0,      vibrance=0,     fade=0,     sepia=0},
    [2] = {sat=1.02, contrast=1.02, temp=-80,  tint=0,      vibrance=0.04,  fade=0,     sepia=0},
    [3] = {sat=1.12, contrast=1.05, temp=-120, tint=0,      vibrance=0.12,  fade=0,     sepia=0},
    [4] = {sat=0.92, contrast=1.08, temp=150,  tint=0.004,  vibrance=-0.05, fade=0.012, sepia=0.03},
    [5] = {sat=1.06, contrast=1.03, temp=-400, tint=-0.002, vibrance=0.06,  fade=0,     sepia=0.02},
    [6] = {sat=0.94, contrast=1.02, temp=450,  tint=0.003,  vibrance=-0.02, fade=0.005, sepia=0},
    [7] = {sat=0.95, contrast=0.97, temp=-150, tint=0,      vibrance=0,     fade=0.025, sepia=0.06},
    [8] = {sat=1.05, contrast=1.04, temp=80,   tint=0,      vibrance=0.08,  fade=0,     sepia=0},
    [9] = {sat=0.85, contrast=0.95, temp=0,    tint=0,      vibrance=-0.10, fade=0.010, sepia=0},
}

local NIGHT_COLOR_PROFILES = {
    [1] = {sat=1.00, contrast=1.00, temp=0,    tint=0,      vibrance=0,     fade=0,     sepia=0},
    [2] = {sat=0.97, contrast=1.02, temp=150,  tint=0,      vibrance=0,     fade=0,     sepia=0},
    [3] = {sat=0.90, contrast=1.03, temp=700,  tint=0.004,  vibrance=-0.05, fade=0.005, sepia=0},
    [4] = {sat=1.04, contrast=1.04, temp=-500, tint=-0.003, vibrance=0.05,  fade=0,     sepia=0.03},
    [5] = {sat=1.14, contrast=1.06, temp=250,  tint=0.006,  vibrance=0.15,  fade=0,     sepia=0},
    [6] = {sat=0.90, contrast=1.08, temp=350,  tint=0.004,  vibrance=-0.04, fade=0.015, sepia=0},
    [7] = {sat=0.55, contrast=1.12, temp=200,  tint=0,      vibrance=-0.20, fade=0.020, sepia=0},
}

local GRADE_KEYS = { 'sat', 'contrast', 'temp', 'tint', 'vibrance', 'fade', 'sepia' }
local GRADE_NEUTRAL = {sat=1, contrast=1, temp=0, tint=0, vibrance=0, fade=0, sepia=0}
local grade = {sat=1, contrast=1, temp=0, tint=0, vibrance=0, fade=0, sepia=0}
local gradeExtrasWritten = false

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

local function ppTry(key, value)
    pcall(pure.pp.set, key, value, true)
end

-- Blends the night and day profiles by daylight, fades them toward neutral with
-- Grade Strength, then adds the manual Grade sliders, which are always live.
local function updateGrade(day)
    local dayProfile = DAY_COLOR_PROFILES[math.floor(number('Color Profile',1,1,9))]
        or DAY_COLOR_PROFILES[1]
    local nightProfile = NIGHT_COLOR_PROFILES[math.floor(number('Night Color Profile',1,1,7))]
        or NIGHT_COLOR_PROFILES[1]
    local strength = number('Grade Strength',1,0,1)
    for _, key in ipairs(GRADE_KEYS) do
        grade[key] = math.lerp(GRADE_NEUTRAL[key],
            math.lerp(nightProfile[key], dayProfile[key], day), strength)
    end
    grade.sat = grade.sat * number('Grade Saturation',1,0.7,1.3)
    grade.contrast = grade.contrast * number('Grade Contrast',1,0.85,1.15)
    grade.temp = grade.temp + number('Grade Temperature',0,-800,800)
    grade.tint = grade.tint + number('Grade Tint',0,-0.02,0.02)
    grade.vibrance = grade.vibrance + number('Grade Vibrance',0,-0.3,0.3)
    grade.fade = grade.fade + number('Grade Fade',0,0,0.05)
    grade.sepia = grade.sepia + number('Grade Sepia',0,0,0.3)
    return grade
end

-- Vibrance, fade and sepia have no ST6IX owner, so they are only written while
-- a grade uses them, and released to neutral once when it stops.
local function applyGradeExtras(g)
    local active = g.vibrance ~= 0 or g.fade ~= 0 or g.sepia ~= 0
    if active or gradeExtrasWritten then
        ppTry('pp.luma_saturation', 1 + g.vibrance)
        ppTry('pp.black_level', g.fade)
        yebisTry('sepia', g.sepia)
    end
    gradeExtrasWritten = active
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

function init_pure_script()
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
    gradeExtrasWritten = false

    pure.script.setVersion(VERSION)

    pure.script.ui.addPage('Daytime Control')
    pure.script.ui.addText('ST6IX Gamma V1.9 - unified photographic rendering controls.')
    pure.script.ui.addRadioButtons('Overall Mode', 2, 'Natural,Photorealistic,Manual')
    pure.script.ui.addText('Modes add a subtle finish; the sliders below always remain active.')
    pure.script.ui.addRadioButtons('Morning Preset', 1, 'Natural Morning,Bright Morning,Dark Morning,Cinematic Morning,Custom')
    slider('Morning Preset Strength', 1.00, 0.00, 1.00, 'Preset influence throughout daylight')
    slider('Daylight Multiplier', 1.15, 0.60, 1.80, 'Pure daylight multiplier during daytime')
    slider('Day Sun Level', 0.95, 0.50, 1.50, 'Direct sunlight level')
    slider('Day Sun Saturation', 1.00, 0.70, 1.30, 'Direct sunlight color strength')
    slider('Day Sun Speculars', 1.00, 0.50, 1.50, 'Sun specular response')
    slider('Day Ambient Level', 1.02, 0.60, 1.50, 'Ambient light level')
    slider('Day Sky Level', 1.02, 0.60, 1.50, 'Sky illumination level')
    slider('Day Advanced Ambient', 1.02, 0.50, 1.60, 'Pure advanced ambient light')
    slider('Day Color Saturation', 0.99, 0.75, 1.25, 'Final daytime saturation')
    slider('Day Contrast', 1.00, 0.85, 1.15, 'Final daytime contrast')
    slider('Day Color Temperature', 6400, 4800, 8000, 'YEBIS daytime color temperature in kelvin')
    pure.script.ui.addCheckbox('Automatic White Balance', true, 'Adapt white balance to time, clouds, fog and rain within safe limits')
    slider('White Balance Strength', 0.55, 0.00, 1.00, 'Influence of automatic white balance')
    slider('White Balance Warmth Bias', 0, -600, 600, 'Creative warm or cool bias in kelvin')
    slider('White Balance Tint', 0.00, -0.03, 0.03, 'Restrained green-to-magenta correction')
    pure.script.ui.addCheckbox('Lock White Balance', false, 'Hold the currently calculated white balance for photography')
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

    pure.script.ui.addPage('Nighttime Controls')
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
    slider('Night Color Saturation', 0.94, 0.70, 1.20, 'Final nighttime saturation')
    slider('Night Contrast', 0.98, 0.85, 1.15, 'Final nighttime contrast')
    slider('Night Color Temperature', 6100, 4000, 8000, 'YEBIS nighttime color temperature in kelvin')
    slider('Night CSP Light Bounce', 1.10, 0.50, 2.50, 'Dynamic-light bounce at night')
    slider('Night CSP Light Emissive', 1.05, 0.50, 3.00, 'Dynamic-light emissive intensity at night')
    slider('Night Display Brightness', 1.00, 0.50, 2.50, 'Dashboard and in-car screen brightness at night')
    pure.script.ui.addCheckbox('Adaptive Celestial Rendering', true, 'Coordinate moon and stars with elevation, clouds, fog and city light')
    slider('Celestial Weather Extinction', 0.65, 0.00, 1.00, 'Cloud and fog reduction of moon and stars')
    slider('Moon Elevation Response', 0.35, 0.00, 1.00, 'Reduce moon response close to the horizon')
    slider('Moon Star Suppression', 0.22, 0.00, 1.00, 'Dim stars beneath a bright elevated moon')
    slider('Deep Sky Visibility', 1.00, 0.00, 2.00, 'Overall deep-sky and Milky Way visibility where the sky texture supports it')

    pure.script.ui.addPage('Fog')
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

    pure.script.ui.addPage('Sky & Clouds')
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

    pure.script.ui.addPage('Bloom')
    pure.script.ui.addRadioButtons('Render Quality', 3, 'Performance,Balanced,High,Ultra')
    pure.script.ui.addText('Render Quality refines bloom and glare sampling without changing the look.')
    pure.script.ui.addCheckbox('Bloom Enabled', true, 'Enable YEBIS bloom')
    slider('Bloom Strength', 0.24, 0.00, 0.80, 'Bloom luminance; deliberately restrained')
    slider('Bloom Threshold', 0.52, 0.15, 1.20, 'Higher values restrict bloom to brighter sources')
    slider('Bloom Radius', 0.44, 0.15, 1.20, 'Bloom spread radius')
    sliderInt('Bloom Levels', 4, 1, 8, 'Number of bloom levels')
    slider('Bloom Gamma', 1.05, 0.80, 1.60, 'Bloom luminance response')
    slider('Bloom Filter Threshold', 0.0010, 0.0001, 0.0100, 'Bright-pass threshold used by YEBIS bloom')

    pure.script.ui.addPage('Glare')
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
    slider('Sun Blinding', 0.35, 0.00, 1.00, 'Veiling glare when looking straight into the sun')
    slider('Sun Blinding Iris', 0.15, 0.00, 1.00, 'Iris contraction around a bright sun disk')
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

    pure.script.ui.addPage('Exposure')
    pure.script.ui.addRadioButtons('Tunnel Preset', 1, 'Normal,Flash,Blinding,Cinematic')
    pure.script.ui.addText('Normal is neutral. Other modes adapt inside the tunnel and recover differently at the exit.')
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

    -- Pure choices are 1-based. A zero default prevents this page from being
    -- built correctly in Pure PP, so AgX is selection 1.
    pure.script.ui.addPage('Tone Mapping')
    pure.script.ui.addRadioButtons('Tone Curve', 1, 'AgX,Uchimura,Lottes,GT7')
    pure.script.ui.addCheckbox('Scene Aware Tone Mapping', true, 'Refine the selected curve using highlights, darkness and fog')
    slider('Tone Adaptation Strength', 0.45, 0.00, 1.00, 'Strength of scene-aware curve refinement')
    slider('Dynamic Highlight Rolloff', 0.55, 0.00, 1.00, 'Protect bright sky, sun and reflective highlights')
    slider('Dynamic Shadow Detail', 0.35, 0.00, 1.00, 'Retain restrained detail in dark scenes')
    slider('Fog Contrast Protection', 0.40, 0.00, 1.00, 'Prevent dense fog from flattening the complete image')
    slider('Tonemap Gamma', 1.10, 0.80, 1.40, 'Final display gamma')
    pure.script.ui.addText('AgX')
    slider('AgX Exposure', 1.00, 0.50, 2.00, 'Input exposure before AgX')
    slider('AgX Slope', 1.05, 0.70, 1.40, 'AgX contrast slope')
    slider('AgX Power', 1.05, 0.70, 1.60, 'AgX contrast power')
    slider('AgX Saturation', 0.96, 0.60, 1.30, 'AgX output saturation')
    pure.script.ui.addText('Uchimura')
    slider('Uchimura Peak', 1.05, 0.50, 3.00, 'Maximum display brightness')
    slider('Uchimura Contrast', 1.45, 0.60, 2.00, 'Tone curve contrast')
    slider('Uchimura Linear Start', 0.18, 0.01, 0.60, 'Linear section start')
    slider('Uchimura Linear Length', 0.42, 0.10, 0.80, 'Highlight shoulder length')
    slider('Uchimura Black', 1.00, 0.50, 1.50, 'Shadow toe strength')
    slider('Uchimura Gain', 0.90, 0.40, 1.50, 'Tone curve output gain')
    pure.script.ui.addText('Lottes')
    slider('Lottes Contrast', 0.82, 0.40, 1.50, 'Lottes contrast')
    slider('Lottes Gamma', 1.00, 0.60, 1.40, 'Lottes curve gamma')
    slider('Lottes HDR Max', 1.20, 0.10, 3.00, 'Highlight range')
    slider('Lottes Mid In', 0.25, 0.05, 0.80, 'Input middle gray')
    slider('Lottes Mid Out', 0.18, 0.05, 0.80, 'Output middle gray')
    slider('Lottes Gain', 0.95, 0.40, 1.50, 'Lottes output gain')
    pure.script.ui.addText('GT7')
    slider('GT7 Exposure', 1.00, 0.50, 2.00, 'Input exposure before the GT7 curve')
    slider('GT7 Highlight Range', 2.50, 1.00, 6.00, 'Peak white in GT7 framebuffer units; 2.5 is SDR paper white')
    slider('GT7 Shoulder', 0.25, 0.05, 0.60, 'Softness of the highlight shoulder')
    slider('GT7 Linear Section', 0.444, 0.20, 0.80, 'Share of the range kept linear before the shoulder')
    slider('GT7 Toe Strength', 1.28, 1.00, 1.80, 'Depth of the shadow toe')
    slider('GT7 Chroma Blend', 0.60, 0.00, 1.00, 'Hue-preserving share; higher keeps bright colours truer')

    pure.script.ui.addPage('Color Grading')
    pure.script.ui.addText('Colour profiles grade the final image. Neutral keeps the ST6IX look untouched.')
    pure.script.ui.addRadioButtons('Color Profile', 1,
        'Neutral,Natural,Vivid,Cinematic,Warm Summer,Cool Winter,Film,GT Broadcast,Raw')
    pure.script.ui.addRadioButtons('Night Color Profile', 1,
        'Neutral,Natural Night,Moonlight Blue,Sodium City,Neon,Cinematic Night,Noir')
    slider('Grade Strength', 1.00, 0.00, 1.00, 'Blend of the selected day and night profiles')
    pure.script.ui.addText('Manual grade, always active on top of the profiles')
    slider('Grade Saturation', 1.00, 0.70, 1.30, 'Final colour intensity')
    slider('Grade Contrast', 1.00, 0.85, 1.15, 'Final contrast')
    slider('Grade Temperature', 0, -800, 800, 'Kelvin shift; negative is warmer, positive is cooler')
    slider('Grade Tint', 0.000, -0.020, 0.020, 'Subtle hue tint')
    slider('Grade Vibrance', 0.00, -0.30, 0.30, 'Saturate muted colours more than strong ones')
    slider('Grade Fade', 0.000, 0.000, 0.050, 'Lift the blacks for a softer film finish')
    slider('Grade Sepia', 0.00, 0.00, 0.30, 'Warm monochrome toning')

    pure.script.ui.addPage('Lens Effects')
    pure.script.ui.addRadioButtons('Lens Profile', 1, 'Clean,Cinematic,Vintage,Telephoto,Custom')
    slider('Lens Profile Strength', 0.70, 0.00, 1.00, 'Blend the selected physical lens response')
    pure.script.ui.addCheckbox('Adaptive Godrays', true, 'Use Pure-safe sun, camera and FOV-aware godrays')
    slider('Godrays Strength', 0.35, 0.00, 1.00, 'Overall photographic godray strength')
    slider('Godrays FOV Response', 0.50, 0.00, 1.00, 'Scale ray length with camera field of view')
    slider('Godrays Sun Facing Response', 0.60, 0.00, 1.00, 'Increase rays smoothly while looking toward the sun')
    slider('Godrays Glare Ratio', 0.12, 0.00, 1.00, 'Godray contribution to visible glare')
    slider('Moon Godrays Strength', 0.00, 0.00, 1.00, 'Soft light shafts from a visible moon at night')
    slider('Vignette Strength', 0.010, 0.00, 0.20, 'Edge darkening')
    slider('Vignette FOV Dependence', 0.25, 0.00, 1.00, 'Vignette response to field of view')
    pure.script.ui.addCheckbox('Chromatic Aberration', false, 'Enable chromatic aberration; lens profiles add their character when enabled')
    sliderInt('Chromatic Samples', 5, 2, 12, 'Chromatic aberration sample count')
    slider('Chromatic Lateral', 0.0010, 0.0000, 0.0100, 'Lateral color displacement')
    slider('Chromatic Uniform', 0.0003, 0.0000, 0.0050, 'Uniform color displacement')
    pure.script.ui.addCheckbox('Lens Distortion', false, 'Enable geometric lens distortion; lens profiles add their character when enabled')
    slider('Lens Roundness', 0.05, 0.00, 1.00, 'Lens distortion roundness')
    slider('Lens Smoothness', 1.00, 0.10, 2.00, 'Lens distortion smoothness')
    slider('Filmic Contrast', 0.35, 0.00, 1.00, 'YEBIS filmic contrast')
    pure.script.ui.addCheckbox('Depth of Field', false, 'Photographic depth of field for replays and screenshots')
    slider('DOF Focus Distance', 8.0, 0.5, 100.0, 'Focus distance in metres')
    slider('DOF Aperture', 2.8, 1.2, 22.0, 'Lens f-number; lower values give a shallower focus')
    sliderInt('DOF Quality', 3, 1, 5, 'Depth of field sampling quality')

    pure.script.ui.addPage('Reflections')
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

    pure.script.ui.addPage('Diagnostics')
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

    pure.script.tools.handleExposure(0)
    pure.exposure.useCBE(true)
    pure.exposure.setBypass(0.25, 0)
    pure.config.set('light.ambient_model_V2', true, true)
end

function update_pure_script(dt)
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
    -- The colour grade composes into the same single writes, so it can never
    -- fight the ST6IX colour controls; a Neutral grade multiplies by exactly 1.
    local colorGrade = updateGrade(day)
    pure.config.set('pp.saturation', colorSat * colorGrade.sat, true)
    pure.config.set('pp.contrast', contrast * colorGrade.contrast, true)
    applyGradeExtras(colorGrade)
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
    pure.yebis.set('colorTemperature', clamp(whiteBalance + colorGrade.temp, 3500, 9500))
    pure.yebis.set('whiteBalance', NEUTRAL_WHITE_POINT)
    pure.yebis.set('hue', number('White Balance Tint',0,-0.03,0.03) + colorGrade.tint)

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

    local tonemapper = math.floor(number('Tone Curve',1,1,4))
    local toneStrength = check('Scene Aware Tone Mapping', true)
        and number('Tone Adaptation Strength',0.45,0,1) or 0
    local toneHighlight = highlightSignal * number('Dynamic Highlight Rolloff',0.55,0,1) * toneStrength
    local toneShadow = darknessSignal * number('Dynamic Shadow Detail',0.35,0,1) * toneStrength
    local toneFogContrast = math.max(worldFog, mist) * number('Fog Contrast Protection',0.40,0,1)
        * toneStrength
    if tonemapper == 1 then
        agxTonemap.values.exposure = number('AgX Exposure',1,0.5,2)
            * clamp(1 + toneShadow * 0.10 - toneHighlight * 0.08, 0.90, 1.10)
        agxTonemap.values.slope = number('AgX Slope',1.05,0.7,1.4)
            * clamp(1 + toneFogContrast * 0.08 - toneShadow * 0.04, 0.94, 1.10)
        agxTonemap.values.power = number('AgX Power',1.05,0.7,1.6)
            * clamp(1 + toneHighlight * 0.07 - toneShadow * 0.04, 0.94, 1.10)
        agxTonemap.values.saturation = number('AgX Saturation',0.96,0.6,1.3)
        pure.pp.setCustomRGBTonemapping(agxTonemap)
    elseif tonemapper == 2 then
        pure.pp.setTonemapping(ac.TonemapFunction.Uchimura)
        pure.config.set('ppTonemapUchimura.maxDisplayBrightness', number('Uchimura Peak',1.05,0.5,3)
            * (1 + toneHighlight * 0.20))
        pure.config.set('ppTonemapUchimura.contrast', number('Uchimura Contrast',1.45,0.6,2)
            * clamp(1 + toneFogContrast * 0.08 - toneShadow * 0.04, 0.94, 1.10))
        pure.config.set('ppTonemapUchimura.linearSectionStart', number('Uchimura Linear Start',0.18,0.01,0.6))
        pure.config.set('ppTonemapUchimura.linearSectionLength', number('Uchimura Linear Length',0.42,0.1,0.8)
            * (1 + toneHighlight * 0.16))
        pure.config.set('ppTonemapUchimura.black', number('Uchimura Black',1,0.5,1.5)
            * clamp(1 - toneShadow * 0.10, 0.88, 1))
        pure.config.set('ppTonemapUchimura.pedestal', 0)
        pure.config.set('ppTonemapUchimura.gain', number('Uchimura Gain',0.9,0.4,1.5))
    elseif tonemapper == 4 then
        -- GT7 takes the same scene-aware signals as the other curves: highlights
        -- widen the headroom, dark scenes lift the toe and fog deepens it.
        updateGt7Curve(gt7Tonemap.values,
            number('GT7 Exposure',1,0.5,2)
                * clamp(1 + toneShadow * 0.10 - toneHighlight * 0.08, 0.90, 1.10),
            number('GT7 Highlight Range',2.5,1,6) * (1 + toneHighlight * 0.20),
            number('GT7 Shoulder',0.25,0.05,0.6),
            number('GT7 Linear Section',0.444,0.2,0.8),
            number('GT7 Toe Strength',1.28,1,1.8)
                * clamp(1 + toneFogContrast * 0.08 - toneShadow * 0.10, 0.90, 1.10),
            number('GT7 Chroma Blend',0.6,0,1))
        pure.pp.setCustomRGBTonemapping(gt7Tonemap)
    else
        pure.pp.setTonemapping(ac.TonemapFunction.Lottes)
        pure.config.set('ppTonemapLottes.contrast', number('Lottes Contrast',0.82,0.4,1.5)
            * clamp(1 + toneFogContrast * 0.08 - toneShadow * 0.04, 0.94, 1.10))
        pure.config.set('ppTonemapLottes.gamma', number('Lottes Gamma',1,0.6,1.4))
        pure.config.set('ppTonemapLottes.hdrMax', number('Lottes HDR Max',1.2,0.1,3)
            * (1 + toneHighlight * 0.24))
        pure.config.set('ppTonemapLottes.midIn', number('Lottes Mid In',0.25,0.05,0.8))
        pure.config.set('ppTonemapLottes.midOut', number('Lottes Mid Out',0.18,0.05,0.8)
            * (1 + toneShadow * 0.10))
        pure.config.set('ppTonemapLottes.gain', number('Lottes Gain',0.95,0.4,1.5))
    end
    local gamma = number('Tonemap Gamma',1.1,0.8,1.4) * pure.pp.getGammaModulator()
    if math.abs(gamma - 1) < 0.0001 then gamma = 0.9999 end
    ac.setPpTonemapGamma(gamma)

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
        if sunRaysOn or moonRays > 0 then
            pure.yebis.set('godraysEnabled', true)
            pure.yebis.set('godraysLength', math.max(0.001, sunRays + moonRays))
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
    yebisTry('vignetteFovDependency', number('Vignette FOV Dependence',0.25,0,1))
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
    pure.yebis.set('filmicContrast', number('Filmic Contrast',0.35,0,1))

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
