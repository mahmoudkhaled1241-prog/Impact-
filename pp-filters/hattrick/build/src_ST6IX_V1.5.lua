-- ST6IX V1.5: weather-aware finishing, based on V1.4. INI unchanged.
-- ============================================================================
-- CONFIGURATION TABLES
-- ============================================================================

local _l_exposure_LUT = {
--  CBE    exp    day   twi   ngt   fog   ref   amb
    { 0.00,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 1.00 },
    { 0.02,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 1.00 },
    { 0.05,  0.10, 0.0,  1.00, 1.00, 0.00, 1.00, 0.55 },
    { 0.063, 0.17, 0.0,  1.00, 0.90, 0.00, 1.00, 0.35 },
    { 0.075, 0.25, 0.0,  1.00, 0.60, 0.00, 0.95, 0.15 },
    { 0.087, 0.60, 0.0,  1.00, 0.30, 0.00, 0.90, 0.00 },
    { 0.1,   0.90, 0.0,  1.00, 0.15, 0.05, 0.80, 0.00 },
    { 0.15,  1.00, 0.0,  0.75, 0.05, 0.15, 0.65, 0.00 },
    { 0.2,   0.50, 0.1,  0.25, 0.00, 0.30, 0.40, 0.00 },
    { 0.3,   0.25, 0.7,  0.00, 0.00, 0.60, 0.20, 0.00 },
    { 0.5,   0.05, 1.0,  0.00, 0.00, 1.00, 0.05, 0.00 },
    { 1.0,   0.00, 1.0,  0.00, 0.00, 1.00, 0.00, 0.00 },
}
local _l_ExposureCPP = LUT:new(_l_exposure_LUT)
local _l_Exposure_lut = _l_ExposureCPP:get(0.03)

-- ============================================================================
-- TONEMAPPING CONFIGURATION
-- ============================================================================

local tonemap__custom = {
    values = {
        P = 2.00,
        a = 1.00,
        m = 0.29,
        l = 0.40,
        c = 1.00,
        b = 0.00,
        gain = 1.00,
        agx_mix = 0.85,
        agx_mix_exp = 0.40,
        agx_slope = 1.25,
        agx_power = 1.75,
        agx_sat = 0.99,
    },
    shader = [[
    #define luminosityFactor float3(0.2126, 0.7152, 0.0722)

    float3 agxDefaultContrastApprox(float3 x) {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        return + 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4
               - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    }

    float3 agx(float3 val) {
        float3x3 agx_mat = float3x3(
          0.842479062253094, 0.0423282422610123, 0.0423756549057051,
          0.0784335999999992, 0.878468636469772, 0.0784336,
          0.0792237451477643, 0.0791661274605434, 0.879142973793104);
        float min_ev = -12.47393f;
        float max_ev = 4.026069f;
        val = mul(agx_mat, val);
        // Avoid log2(0) and invalid negative values in deep shadows.
        val = max(val, float3(1e-6, 1e-6, 1e-6));
        val = clamp(log2(val), min_ev, max_ev);
        val = (val - min_ev) / (max_ev - min_ev);
        val = agxDefaultContrastApprox(val);
        return val;
    }

    float3 agxEotf(float3 val) {
        float3x3 agx_mat_inv = float3x3(
          1.19687900512017, -0.0528968517574562, -0.0529716355144438,
          -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
          -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
        return mul(agx_mat_inv, val);
    }

    float3 agxLook(float3 val) {
        float luma = dot(val, luminosityFactor);
        float3 offset = float3(0.0, 0.0, 0.0);
        float3 slope = float3(agx_slope, agx_slope, agx_slope);
        float3 power = float3(agx_power, agx_power, agx_power);
        float sat = agx_sat;
        val = pow(max(0, val * slope + offset), power);
        return luma + sat * (val - luma);
    }

    float uchimura(float x) {
        float l0 = ((P - m) * l) / a;
        float L0 = m - m / a;
        float L1 = m + (1.0 - m) / a;
        float S0 = m + l0;
        float S1 = m + a * l0;
        float C2 = (a * P) / (P - S1);
        float CP = -C2 / P;
        float w0 = 1.0 - smoothstep(0.0, m, x);
        float w2 = step(m + l0, x);
        float w1 = 1.0 - w0 - w2;
        float T = m * pow(abs(x / m), c) + b;
        float S = P - (P - S1) * exp(CP * (x - S0));
        float L = m + a * (x - m);
        return T * w0 + L * w1 + S * w2;
    }

    float3 RGB_Uchimura_AgX(float3 x){
        float luma = saturate(dot(x, luminosityFactor));
        float3 col = agx(x);
        col = agxLook(col);
        col = agxEotf(col);
        x = lerp(x, col, agx_mix * pow(luma, agx_mix_exp));
        x *= gain;
        x = float3(uchimura(x.r), uchimura(x.g), uchimura(x.b));
        return x;
    }

    float3 tonemapping(float3 x){
        return RGB_Uchimura_AgX(x);
    }
]]
}

local tonemap__aces = {
    values = {
        exposure = 1.0,
    },
    shader = [[
    float3 ACESFitted(float3 x) {
        float3 a = x*(2.51*x + 0.03);
        float3 b = x*(2.43*x + 0.59) + 0.14;
        return saturate(a / b);
    }
    float3 tonemapping(float3 x){
        x = max(x, float3(0,0,0));
        x *= exposure;
        return ACESFitted(x);
    }
]]
}

-- ============================================================================
-- GLOBAL VARIABLES
-- ============================================================================

local CSP_VERSION = ac.getPatchVersionCode()
local _l_init = true
local _l_current_tonemapping = 2

-- Retrograde intro smoothing (seconds)
local retro_intro_time = 0.0
local retro_intro_duration = 2.5

local cloud_shadow = 0
local cloud_shadow_sun = 0
local cloud_shadow_twilight = 0
local cam_sun_face = 0
local badness = 0
local fog = 0
local occlusion = 0
local gamma = 1.0
local photo_realistic = 0.0
local interior = true
local color_mod = 1.0
local hsv_fog = hsv(0, 0, 0)
local rgb_fog = rgb(0, 0, 0)

-- Local cache for sun/moon size binding (keeps UI and engine config in sync)
local _last_cfg_sun_moon = nil
local _last_ui_sun_moon = nil
local _last_exposure_error = nil
local _last_godray_length = nil


local fogdensity = 0
local fogsat = 1
local fogtype = 2
local daycurvefog = 1

-- Unified preset tracker
-- unified preset tracker removed (reverted preset additions)


cover = cover or ac.SkyCloudsCover()
ac.addWeatherCloudCover(cover)

-- ============================================================================
-- PRESET DEFINITIONS
-- ============================================================================

-- LIGHTING PRESETS (0=Pure Default, 1=Sunrise/Sunset, 2=Midday, 3=Natural, 4=Golden Hour, 5=Crisp Clear, 6=Manual) - Daylight only
local LIGHTING_PRESETS = {
    [0] = { daylight_multiplier=1.00, sun_level=1.00, sun_speculars=1.00, ambient_level=1.00, advanced_ambient_light=1.00, sky_level=1.00, advanced_ambient_lightV2_sun=1.00, csp_lights_bounce=1.00, csp_lights_emissive=1.00 },  -- Pure Default: neutral
    [1] = { daylight_multiplier=1.62, sun_level=0.73, sun_speculars=1.077, ambient_level=0.952, advanced_ambient_light=1.077, sky_level=1.038, advanced_ambient_lightV2_sun=0.724, csp_lights_bounce=1.132, csp_lights_emissive=1.00 },  -- Sunrise/Sunset
    [2] = { daylight_multiplier=1.05, sun_level=0.95, sun_speculars=1.00, ambient_level=1.00, advanced_ambient_light=1.05, sky_level=1.03, advanced_ambient_lightV2_sun=0.98, csp_lights_bounce=1.00, csp_lights_emissive=1.00 },  -- Midday: neutral physical balance
    [3] = { daylight_multiplier=1.12, sun_level=0.92, sun_speculars=0.95, ambient_level=1.04, advanced_ambient_light=1.08, sky_level=1.06, advanced_ambient_lightV2_sun=1.01, csp_lights_bounce=1.05, csp_lights_emissive=1.00 }, -- Natural
    [4] = { daylight_multiplier=1.45, sun_level=0.85, sun_speculars=1.20, ambient_level=1.05, advanced_ambient_light=1.10, sky_level=1.12, advanced_ambient_lightV2_sun=0.90, csp_lights_bounce=1.10, csp_lights_emissive=1.05, bloom_preset=6 }, -- Golden Hour
    [5] = { daylight_multiplier=1.18, sun_level=1.00, sun_speculars=1.06, ambient_level=1.00, advanced_ambient_light=1.02, sky_level=1.08, advanced_ambient_lightV2_sun=1.00, csp_lights_bounce=1.02, csp_lights_emissive=1.00, pp_contrast=1.05, pp_sharpness=0.12, bloom_preset=7 }, -- Crisp Clear
}

-- REFLECTIONS PRESETS (0=Pure Default, 1=High Quality, 2=Performance, 3=Cinematic, 4=Manual)
local REFLECTIONS_PRESETS = {
    [0] = { reflections_saturation=1.00, reflections_level=1.00, reflections_emissive_boost=1.0, vao_amount=1.00, groundfog_gain=1.00 },  -- Pure Default: neutral
    [1] = { reflections_saturation=1.05, reflections_level=1.12, reflections_emissive_boost=4.0, vao_amount=1.08, groundfog_gain=1.00 },
    [2] = { reflections_saturation=0.95, reflections_level=0.82, reflections_emissive_boost=2.0, vao_amount=0.85, groundfog_gain=0.80 },  -- Performance
    [3] = { reflections_saturation=1.06, reflections_level=1.25, reflections_emissive_boost=8.0, vao_amount=1.10, groundfog_gain=1.10 },

    -- Richer looks remain available, but are capped to photographic values.
    [4] = { reflections_saturation=1.12, reflections_level=1.35, reflections_emissive_boost=12.0, vao_amount=1.15, groundfog_gain=1.12 },
    [5] = { reflections_saturation=1.10, reflections_level=1.45, reflections_emissive_boost=16.0, vao_amount=1.20, groundfog_gain=1.18 },
}

-- BLOOM & GLARE PRESETS (0=Pure Default, 1=Subtle, 2=Cinematic, 3=Intense, 4=Neon City, 5=Wet Night, 6=Golden Hour, 7=Crisp Clear, 8=Manual)
local BLOOM_PRESETS = {
    -- Values are calibrated against ST6IX PP V1.1(2).ini. Bloom filter
    -- thresholds are intentionally separate and remain in the INI-sized
    -- 0.0001-0.005 range instead of being fed the master 0-1 threshold.
    [0] = { bloom_intensity=0.34, bloom_threshold=0.46, bloom_filter=0.0010, bloom_radius=0.46, bloom_levels=4, bloom_gamma=1.02 },
    [1] = { bloom_intensity=0.22, bloom_threshold=0.54, bloom_filter=0.0015, bloom_radius=0.34, bloom_levels=3, bloom_gamma=1.00 },
    [2] = { bloom_intensity=0.40, bloom_threshold=0.43, bloom_filter=0.0008, bloom_radius=0.52, bloom_levels=4, bloom_gamma=1.03 },
    [3] = { bloom_intensity=0.48, bloom_threshold=0.50, bloom_filter=0.0007, bloom_radius=0.48, bloom_levels=4, bloom_gamma=1.04 },
    [4] = { bloom_intensity=0.36, bloom_threshold=0.48, bloom_filter=0.0008, bloom_radius=0.40, bloom_levels=3, bloom_gamma=1.02 },
    [5] = { bloom_intensity=0.46, bloom_threshold=0.44, bloom_filter=0.0006, bloom_radius=0.56, bloom_levels=4, bloom_gamma=1.03 },
    [6] = { bloom_intensity=0.32, bloom_threshold=0.47, bloom_filter=0.0010, bloom_radius=0.44, bloom_levels=3, bloom_gamma=1.01 },
    [7] = { bloom_intensity=0.18, bloom_threshold=0.58, bloom_filter=0.0020, bloom_radius=0.28, bloom_levels=2, bloom_gamma=1.00 },
}

-- Compatibility failures in optional YEBIS fields are logged once, never allowed
-- to abort the update before tonemapping. No exposure or tone changes.
local st6ix_bloom_field_errors = {}


-- EXPOSURE PRESETS (0=Pure Default, 1=Balanced, 2=High Dynamic, 3=Low Light, 4=Manual)
-- Using handleExposure parameters: method, target, minimumexposure, superexposure, fixedexposure, mix
local EXPOSURE_PRESETS = {
    [0] = { method=5, target=4.0,  minimumexposure=0.01,  superexposure=0.50, fixedexposure=0.25, mix=1.0 },  -- Pure Default: Neutral balanced
    [1] = { method=5, target=3.0,  minimumexposure=0.01,  superexposure=0.70, fixedexposure=0.30, mix=1.0 },  -- Balanced: Even distribution
    [2] = { method=5, target=2.5,  minimumexposure=0.005, superexposure=1.00, fixedexposure=0.35, mix=0.85 }, -- High Dynamic: Wide range
    [3] = { method=5, target=2.0,  minimumexposure=0.02,  superexposure=1.50, fixedexposure=0.50, mix=1.0 },  -- Low Light: Bright for dark scenes
}

-- CUSTOM EXPOSURE PRESETS (ST6IX-style with direct CBE/Yebis control)
-- Each preset defines: day_target, night_target, day_interior_target, night_interior_target, day_sensitivity, night_sensitivity, ae_mix, tunnel_blinding_strength
local CUSTOM_EXPOSURE_PRESETS = {
    [0] = { day_target=4.0, night_target=3.0, day_interior_target=4.0, night_interior_target=3.0, day_sensitivity=3.0, night_sensitivity=1.0, ae_mix=0.5, tunnel_blinding=1.25, day_exp_target=0.1, night_exp_target=0.75, day_interior_exp=0.12, night_interior_exp=0.5 },  -- Balanced
    [1] = { day_target=4.5, night_target=3.5, day_interior_target=4.5, night_interior_target=3.5, day_sensitivity=2.5, night_sensitivity=1.2, ae_mix=0.6, tunnel_blinding=1.0, day_exp_target=0.08, night_exp_target=0.60, day_interior_exp=0.10, night_interior_exp=0.45 },  -- Bright/Vivid
    [2] = { day_target=3.5, night_target=2.5, day_interior_target=3.5, night_interior_target=2.5, day_sensitivity=3.5, night_sensitivity=0.8, ae_mix=0.4, tunnel_blinding=1.5, day_exp_target=0.12, night_exp_target=0.90, day_interior_exp=0.14, night_interior_exp=0.60 },  -- Dark/Moody
    [3] = { day_target=5.0, night_target=4.0, day_interior_target=5.0, night_interior_target=4.0, day_sensitivity=2.0, night_sensitivity=1.5, ae_mix=0.7, tunnel_blinding=0.8, day_exp_target=0.06, night_exp_target=0.50, day_interior_exp=0.08, night_interior_exp=0.40 },  -- High Contrast
}

-- HDR & CLARITY PRESETS (0=Off, 1=Subtle HDR, 2=Full HDR, 3=Ultra HDR, 4=Cinematic Sharp, 5=Manual)
local HDR_CLARITY_PRESETS = {
    [0] = { sharpness=0.0, clarity=0.0, micro_contrast=0.0, hdr_brightness=1.0, color_vibrance=0.0, highlight_recovery=0.0 },
    [1] = { sharpness=0.12, clarity=0.14, micro_contrast=0.06, hdr_brightness=1.00, color_vibrance=0.03, highlight_recovery=0.12 },
    [2] = { sharpness=0.18, clarity=0.22, micro_contrast=0.10, hdr_brightness=1.02, color_vibrance=0.06, highlight_recovery=0.18 },
    [3] = { sharpness=0.25, clarity=0.30, micro_contrast=0.14, hdr_brightness=1.04, color_vibrance=0.08, highlight_recovery=0.24 },
    [4] = { sharpness=0.20, clarity=0.20, micro_contrast=0.12, hdr_brightness=1.01, color_vibrance=0.04, highlight_recovery=0.16 },
}

-- Overall finishing profiles. They scale post-processing and lighting controls
-- without replacing the selected tonemapping or skydome.
local ST6IX_PROFILES = {
    [0] = { bloom=0.72, cockpit_bloom=0.58, exterior_bloom=0.82, glare=0.38, bloom_radius=0.85, sharpness=0.68, clarity=0.74, vignette=0.025, grain=0.00 },
    [1] = { bloom=0.82, cockpit_bloom=0.64, exterior_bloom=0.90, glare=0.52, bloom_radius=0.90, sharpness=0.78, clarity=0.82, vignette=0.05,  grain=0.025 },
    [2] = { bloom=0.92, cockpit_bloom=0.72, exterior_bloom=0.98, glare=0.70, bloom_radius=0.95, sharpness=0.88, clarity=0.90, vignette=0.075, grain=0.04 },
    [3] = { bloom=1.00, cockpit_bloom=1.00, exterior_bloom=1.00, glare=1.00, bloom_radius=1.00, sharpness=1.00, clarity=1.00, vignette=nil, grain=nil },
}

-- SKY PRESETS (0=Pure Default, 1=Vivid, 2=Cinematic, 3=Natural, 4=Golden Hour, 5=Overcast Soft, 6=Pastel Dawn, 7=Smog/City Haze, 8=Storm Incoming, 9=Manual)
local SKY_PRESETS = {
    [0] = { day = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.0, clouds_contrast=1.0, sky_level=1.0, sky_saturation=1.0 }, night = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.0, clouds_contrast=1.0, sky_level=1.0, sky_saturation=1.0 }, duskdawn_sky_level=0.25 },
    [1] = { day = { sky_light_level=1.3, ["sun.sun_moon_size"]=1.5, clouds_brightness=0.481, clouds_contrast=1.115, sky_level=1.2, sky_saturation=1.3 }, night = { sky_light_level=1.3, ["sun.sun_moon_size"]=1.5, clouds_brightness=1.3, clouds_contrast=1.0, sky_level=1.2, sky_saturation=1.3 }, duskdawn_sky_level=0.35 },
    [2] = { day = { sky_light_level=1.125, ["sun.sun_moon_size"]=2.0, clouds_brightness=0.9, clouds_contrast=1.2, sky_level=0.9, sky_saturation=0.85 }, night = { clouds_brightness=0.8, clouds_contrast=1.1, sky_level=0.9, sky_saturation=0.85 }, duskdawn_sky_level=0.4 },
    [3] = { day = { sky_light_level=1.05, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.1, clouds_contrast=0.95, sky_level=1.1, sky_saturation=1.05 }, night = { sky_light_level=1.15, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.15, clouds_contrast=0.9, sky_level=1.1, sky_saturation=1.05 }, duskdawn_sky_level=0.3 },
    [4] = { day = { sky_light_level=1.1, ["sun.sun_moon_size"]=1.2, clouds_brightness=0.95, clouds_contrast=1.05, sky_level=1.12, sky_saturation=1.25 }, night = { sky_light_level=1.1, ["sun.sun_moon_size"]=1.2, clouds_brightness=1.1, clouds_contrast=1.0, sky_level=1.12, sky_saturation=1.25 }, duskdawn_sky_level=0.55 }, -- Golden Hour

    -- Requested additional presets
    [5] = { day = { sky_light_level=0.9, ["sun.sun_moon_size"]=0.95, clouds_brightness=1.6, clouds_contrast=0.6, sky_level=0.9, sky_saturation=0.7 }, night = { sky_light_level=0.9, ["sun.sun_moon_size"]=0.95, clouds_brightness=1.6, clouds_contrast=0.6, sky_level=0.9, sky_saturation=0.7 } }, -- Overcast Soft
    [6] = { day = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.05, clouds_brightness=0.8, clouds_contrast=0.8, sky_level=1.0, sky_saturation=1.1 }, night = { sky_light_level=1.0, ["sun.sun_moon_size"]=1.05, clouds_brightness=0.8, clouds_contrast=0.8, sky_level=1.0, sky_saturation=1.1 }, duskdawn_sky_level=0.45 }, -- Pastel Dawn
    [7] = { day = { sky_light_level=0.8, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.2, clouds_contrast=0.7, sky_level=0.8, sky_saturation=0.6 }, night = { sky_light_level=0.8, ["sun.sun_moon_size"]=1.0, clouds_brightness=1.2, clouds_contrast=0.7, sky_level=0.8, sky_saturation=0.6 } }, -- Smog / City Haze
    [8] = { day = { sky_light_level=0.7, ["sun.sun_moon_size"]=1.0, clouds_brightness=0.45, clouds_contrast=1.4, sky_level=0.7, sky_saturation=0.6 }, night = { sky_light_level=0.7, ["sun.sun_moon_size"]=1.0, clouds_brightness=0.45, clouds_contrast=1.4, sky_level=0.7, sky_saturation=0.6 } }, -- Storm Incoming
}

-- NIGHT PRESETS (0=Bright Night, 1=Dark Night, 2=Cinematic, 3=Neon City, 4=Wet Night, 5=Adjust-N)
local NIGHT_PRESETS = {
    [0] = { nlp_level=0.5, nlp_density=0.7, nlp_lowest_ambient=0.6, moon_light=0.8, moon_appearance=0.9, stars_appearance=1.5, stars_dynamic=true, csp_lights_bounce=0.7, csp_lights_emissive=0.6 },
    [1] = { nlp_level=1.5, nlp_density=1.2, nlp_lowest_ambient=1.3, moon_light=1.5, moon_appearance=1.2, stars_appearance=1.3, stars_dynamic=true, csp_lights_bounce=1.3, csp_lights_emissive=1.4 },
    [2] = { nlp_level=1.1, nlp_density=1.05, nlp_lowest_ambient=0.95, moon_light=1.35, moon_appearance=1.25, stars_appearance=1.35, stars_dynamic=true, csp_lights_bounce=1.18, csp_lights_emissive=1.25 }, -- Improved Cinematic
    [3] = { nlp_level=0.9, nlp_density=1.1, nlp_lowest_ambient=0.5, moon_light=0.6, moon_appearance=0.6, stars_appearance=0.8, stars_dynamic=true, csp_lights_bounce=0.9, csp_lights_emissive=1.2, reflections_saturation=1.4, bloom_preset=4 }, -- Neon City
    [4] = { nlp_level=1.0, nlp_density=0.9, nlp_lowest_ambient=0.7, moon_light=0.9, moon_appearance=0.8, stars_appearance=1.0, stars_dynamic=true, csp_lights_bounce=1.1, csp_lights_emissive=1.25, reflections_saturation=1.1, bloom_preset=5, glare_star_luminance=0.7 }, -- Wet Night
}

-- ============================================================================
-- TONEMAPPING FUNCTION
-- ============================================================================

local function set_tonemapping(dt, mode)
    if mode < 2 then
        if pure.system.isHDR then
            pure.pp.setTonemapping(ac.TonemapFunction.Sensitometric)
        else
            pure.pp.setTonemapping(ac.TonemapFunction.Sensitometric)
        end
    elseif mode < 4 then
        local dyn_range_adjust = _l_Exposure_lut[1]^1.5
        local dyn_range_adjust_inv = 1-dyn_range_adjust
        local dyn_range_adjust_dark = _l_Exposure_lut[6]^2
        local dyn_range_adjust_dark_inv = 1-dyn_range_adjust_dark

        local uchimura__maxDisplayBrightness = -0.95 + 0.15*cam_sun_face
        local uchimura__contrast = math.lerp(0.7 + 0.20*_l_Exposure_lut[7], 1.4 - 0.6*(1-_l_Exposure_lut[3]), photo_realistic)
        local uchimura__linearSessionStart = math.lerp(-0.257, (interior and -0.275 or -0.265), photo_realistic^0.34)
        local uchimura__linearSectionLength = math.lerp(0.3, 0.3 - 0.1*dyn_range_adjust_dark - 0.3*dyn_range_adjust, photo_realistic)
        local uchimura__black = math.lerp(0.2 - 0.2*_l_Exposure_lut[7] + 0.07*cam_sun_face, 0.00 + 0.07*cam_sun_face, photo_realistic)
        local uchimura__gain = math.lerp(-0.325 - 0.08*cam_sun_face, -0.325 - 0.08*cam_sun_face - (interior and 0.2 or 0.2)*_l_Exposure_lut[7] + 0.3*(1-_l_Exposure_lut[3]), photo_realistic)

        if mode < 3 then
            pure.pp.setTonemapping(ac.TonemapFunction.Uchimura)
            pure.config.set("ppTonemapUchimura.maxDisplayBrightness", uchimura__maxDisplayBrightness, true)
            pure.config.set("ppTonemapUchimura.contrast", uchimura__contrast, true)
            pure.config.set("ppTonemapUchimura.linearSectionStart", uchimura__linearSessionStart, true)
            pure.config.set("ppTonemapUchimura.linearSectionLength", uchimura__linearSectionLength, true)
            pure.config.set("ppTonemapUchimura.black", uchimura__black, true)
            pure.config.set("ppTonemapUchimura.gain", uchimura__gain, true)
        else
            -- Retrograde / Custom tonemapper: distinct from Hyperchrome with intro smoothing
            if mode == 3 then
                -- Reset intro when switching in
                if _l_current_tonemapping ~= 3 then retro_intro_time = 0.0 end
                retro_intro_time = math.min(retro_intro_time + dt, retro_intro_duration)
                local intro_fac = 1.0 - (retro_intro_time / retro_intro_duration)

                -- Retrograde base values (distinct defaults)
                local base_P = 2.00 + uchimura__maxDisplayBrightness
                local base_a = 1.10 + uchimura__contrast
                local base_m = math.max(0.001, 0.18 + uchimura__linearSessionStart)
                local base_l = math.min(1-math.max(0, base_m), 0.42 + uchimura__linearSectionLength)
                local base_c = 1.00 + uchimura__black
                local base_b = 0.01
                local base_gain = 1.05 + uchimura__gain
                local base_agx_mix = 0.75
                local base_agx_mix_exp = 0.45
                local base_agx_slope = 1.10
                local base_agx_power = 1.80
                local base_agx_sat = 0.92

                -- Intro punches that decay over time
                local intro_P_add = 0.40
                local intro_a_add = 0.20
                local intro_agx_mix_add = 0.20
                local intro_agx_power_add = 0.60

                if _l_init then
                    -- During init, apply a stronger starting look (with intro factor)
                    tonemap__custom.values.P = base_P + intro_P_add * intro_fac
                    tonemap__custom.values.a = base_a + intro_a_add * intro_fac
                    tonemap__custom.values.m = base_m
                    tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                    tonemap__custom.values.l = base_l
                    tonemap__custom.values.c = base_c
                    tonemap__custom.values.b = base_b
                    tonemap__custom.values.gain = base_gain
                    tonemap__custom.values.agx_mix = base_agx_mix + intro_agx_mix_add * intro_fac
                    tonemap__custom.values.agx_mix_exp = base_agx_mix_exp
                    tonemap__custom.values.agx_slope = base_agx_slope
                    tonemap__custom.values.agx_power = base_agx_power + intro_agx_power_add * intro_fac
                    tonemap__custom.values.agx_sat = base_agx_sat
                else
                    -- When running, blend UI sliders toward Retrograde base to differentiate from Hyperchrome
                    local uiP = pure.script.ui.getValue("TONEMAPPING__maxDisplayBrightness")
                    local uiA = pure.script.ui.getValue("TONEMAPPING__contrast")
                    local uim = pure.script.ui.getValue("TONEMAPPING__linearSectionStart")
                    local uil = pure.script.ui.getValue("TONEMAPPING__linearSectionLength")
                    local uiC = pure.script.ui.getValue("TONEMAPPING__black")
                    local uiB = pure.script.ui.getValue("TONEMAPPING__pedestal")
                    local uiGain = pure.script.ui.getValue("TONEMAPPING__gain")

                    tonemap__custom.values.P = uiP + uchimura__maxDisplayBrightness
                    tonemap__custom.values.a = uiA + uchimura__contrast
                    tonemap__custom.values.m = math.max(0.001, uim + uchimura__linearSessionStart)
                    tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                    tonemap__custom.values.l = math.min(1-math.max(0, tonemap__custom.values.m), uil + uchimura__linearSectionLength)
                    tonemap__custom.values.c = uiC + uchimura__black
                    tonemap__custom.values.b = uiB
                    tonemap__custom.values.gain = uiGain + uchimura__gain

                    -- Bias AGX/contrast/gain toward Retrograde base and apply intro punches
                    tonemap__custom.values.agx_mix = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_mix"), base_agx_mix, 0.65) + intro_agx_mix_add * intro_fac
                    tonemap__custom.values.agx_mix_exp = pure.script.ui.getValue("TONEMAPPING__agx_mix_luma_exp")
                    tonemap__custom.values.agx_slope = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_slope"), base_agx_slope, 0.5)
                    tonemap__custom.values.agx_power = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_power") * 2.2, base_agx_power, 0.65) + intro_agx_power_add * intro_fac
                    tonemap__custom.values.agx_sat = math.lerp(pure.script.ui.getValue("TONEMAPPING__agx_sat"), base_agx_sat, 0.4)
                end
            else
                -- Not Retrograde mode: reset intro timer and fallback to UI values
                retro_intro_time = 0.0
                tonemap__custom.values.P = pure.script.ui.getValue("TONEMAPPING__maxDisplayBrightness") + uchimura__maxDisplayBrightness
                tonemap__custom.values.a = pure.script.ui.getValue("TONEMAPPING__contrast") + uchimura__contrast
                tonemap__custom.values.m = math.max(0.001, pure.script.ui.getValue("TONEMAPPING__linearSectionStart") + uchimura__linearSessionStart)
                tonemap__custom.values.P = math.max(tonemap__custom.values.P, tonemap__custom.values.m + 0.01)
                tonemap__custom.values.l = math.min(1-math.max(0, tonemap__custom.values.m), pure.script.ui.getValue("TONEMAPPING__linearSectionLength") + uchimura__linearSectionLength)
                tonemap__custom.values.c = pure.script.ui.getValue("TONEMAPPING__black") + uchimura__black
                tonemap__custom.values.b = pure.script.ui.getValue("TONEMAPPING__pedestal")
                tonemap__custom.values.gain = pure.script.ui.getValue("TONEMAPPING__gain") + uchimura__gain
                tonemap__custom.values.agx_mix = pure.script.ui.getValue("TONEMAPPING__agx_mix")
                tonemap__custom.values.agx_mix_exp = pure.script.ui.getValue("TONEMAPPING__agx_mix_luma_exp")
                tonemap__custom.values.agx_slope = pure.script.ui.getValue("TONEMAPPING__agx_slope")
                tonemap__custom.values.agx_power = pure.script.ui.getValue("TONEMAPPING__agx_power") * 2.2
                tonemap__custom.values.agx_sat = pure.script.ui.getValue("TONEMAPPING__agx_sat")
            end
            pure.pp.setCustomRGBTonemapping(tonemap__custom)
        end
    elseif mode < 5 then
        -- ACES (BABAYAGA) custom tonemapper
        if not _l_init then
            tonemap__aces.values.exposure = pure.script.ui.getValue("TONEMAPPING__aces_exposure")
            pure.pp.setCustomRGBTonemapping(tonemap__aces)
        end
    elseif mode < 6 then
        local exp_mod = (1-_l_Exposure_lut[4])
        local exp_mod2 = (1-_l_Exposure_lut[6])^2
        pure.pp.setTonemapping(ac.TonemapFunction.Lottes)
        pure.config.set("ppTonemapLottes.contrast", 0.75, true)
        pure.config.set("ppTonemapLottes.gamma", math.lerp(-0.03, -0.03 - 0.05*exp_mod2, photo_realistic^0.50), true)
        pure.config.set("ppTonemapLottes.hdrMax", 0.1, true)
        pure.config.set("ppTonemapLottes.midIn", math.lerp(-0.25 + 0.04*exp_mod, -0.25 - 0.05*exp_mod2, photo_realistic^0.50), true)
        pure.config.set("ppTonemapLottes.midOut", -0.24 + 0.07*exp_mod, true)
        pure.config.set("ppTonemapLottes.gain", 0.05, true)
    end
    
    local tmp_gamma = gamma * pure.pp.getGammaModulator()
    if tmp_gamma > 0.9999 and tmp_gamma < 1.0001 then
        tmp_gamma = 0.9999
    end
    ac.setPpTonemapGamma(tmp_gamma)
    _l_current_tonemapping = mode
end

-- ============================================================================
-- INITIALIZATION - CREATES ALL UI SLIDERS
-- ============================================================================

function init_pure_script()
    pure.light.setVAOAdaption(1.0)
    pure.light.setLambertGamma(1.10)
    
    pure.script.ui.addPage("Info")
    -- Force Pure to rebuild saved UI state for the corrected tonemap controls.
    pure.script.setVersion(4.1)
    pure.script.setAuthor("ST6IX Professional Edition v1.0 - Modern UI")
    pure.script.resetSettingsWithNewVersion()

    -- ========================================================================
    -- GUIDE PAGE - Reference guide for tested combinations
    -- ========================================================================
    pure.script.ui.addPage("🎯Guide")
    
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🎯 TESTED PRESET COMBINATIONS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Use this guide to set up each page manually.")
    pure.script.ui.addText("Go to each tab and select the preset shown below.")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("")
    pure.script.ui.addText("🌅 MORNING CLEAR ☀️ - Crisp sunrise")
    pure.script.ui.addText("  Daytime→ Crisp Clear | Bloom→ Crisp Clear")
    pure.script.ui.addText("  Reflections→ High Quality | Sky→ Natural")
    pure.script.ui.addText("  Exposure→ Balanced/Bright | Fog→ None")
    pure.script.ui.addText("  Tonemap→ Photoreal Neutral | Photo-Realistic: 0.6")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("🌫️ MORNING HAZY - Soft morning fog")
    pure.script.ui.addText("  Daytime→ Natural | Bloom→ Subtle")
    pure.script.ui.addText("  Reflections→ Pure Default | Sky→ Overcast Soft")
    pure.script.ui.addText("  Fog→ Realistic (0.08 amount, 0.02 thickness)")
    pure.script.ui.addText("  Tonemap→ Photoreal Neutral | Photo-Realistic: 0.7")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("🌇 DUSK/DAWN 🌅 - Golden hour magic")
    pure.script.ui.addText("  Daytime→ Golden Hour | Bloom→ Golden Hour")
    pure.script.ui.addText("  Reflections→ Cinematic | Sky→ Golden Hour")
    pure.script.ui.addText("  Exposure→ High Dynamic/High Contrast")
    pure.script.ui.addText("  Fog→ Immersive (0.035 amt) | Tonemap→ Retrograde")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("🌙 NIGHT CLEAR - Well-lit night")
    pure.script.ui.addText("  Night→ Bright Night | Bloom→ Subtle")
    pure.script.ui.addText("  Reflections→ High Quality | Sky→ Natural")
    pure.script.ui.addText("  Exposure→ Low Light | Fog→ None")
    pure.script.ui.addText("  Tonemap→ Photoreal Neutral | Photo-Realistic: 0.8")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("🌃 NIGHT CITY - Neon urban atmosphere")
    pure.script.ui.addText("  Night→ Neon City | Bloom→ Neon City")
    pure.script.ui.addText("  Reflections→ Magical Shimmer | Sky→ Smog/City Haze")
    pure.script.ui.addText("  Exposure→ Low Light/Dark Moody")
    pure.script.ui.addText("  Fog→ Immersive (0.05) | Tonemap→ Photoreal Neutral")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("🌧️ WET DAY - Rainy with enhanced reflections")
    pure.script.ui.addText("  Daytime→ Natural | Bloom→ Cinematic")
    pure.script.ui.addText("  Reflections→ Ethereal Glow | Sky→ Storm Incoming")
    pure.script.ui.addText("  Exposure→ High Dynamic/Dark Moody")
    pure.script.ui.addText("  Fog→ Realistic (0.15 amt, 0.03 thickness)")
    pure.script.ui.addSeparator()
    
    pure.script.ui.addText("💧 WET NIGHT - Cinematic wet streets")
    pure.script.ui.addText("  Night→ Wet Night | Bloom→ Wet Night")
    pure.script.ui.addText("  Reflections→ Ethereal Glow | Sky→ Storm Incoming")
    pure.script.ui.addText("  Exposure→ Low Light/Dark Moody")
    pure.script.ui.addText("  Fog→ Realistic (0.12 amt, 0.025 thickness)")
    pure.script.ui.addText("")
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("💡 Set each page to match a preset above, or")
    pure.script.ui.addText("   mix and match any presets you like!")
    pure.script.ui.addText("")
    pure.script.ui.addText("🔍 HDR & CLARITY TIP:")
    pure.script.ui.addText("  Full HDR☀️ works great for most daytime")
    pure.script.ui.addText("  Subtle HDR🌤 for night to avoid noise")
    pure.script.ui.addText("  Cinematic Sharp🎥 for replays & screenshots")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    -- ========================================================================
    -- ST6IX MASTER PROFILE
    -- ========================================================================
    pure.script.ui.addPage("🎬ST6IX Profile")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🎯 MASTER FINISHING PROFILE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addRadioButtons("st6ix_profile", 0, "Photoreal Drive🏎,Photoreal Cinema🎥,Photoreal Photo📸,Manual⚙")
    pure.script.ui.addText("Photoreal Drive: neutral, clean and driver-focused")
    pure.script.ui.addText("Photoreal Cinema: restrained camera depth")
    pure.script.ui.addText("Photoreal Photo: detailed but naturally graded")
    pure.script.ui.addText("Manual: individual sliders stay authoritative")
    pure.script.ui.addSliderFloat("weather_realism_v15", 0.75, 0, 1, "Weather adaptation strength; zero restores static profile effects")
    pure.script.ui.addText("Weather changes are smoothed; exposure and tonemapping stay independent.")

    -- ========================================================================
    -- DAYTIME LIGHTING PAGE - Redesigned with better organization
    -- ========================================================================
    pure.script.ui.addPage("☀️Daytime")
    
    -- === DAYTIME PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("⚡ DAYTIME LIGHTING PRESETS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Quick presets for different times of day and conditions")
    pure.script.ui.addRadioButtons("lighting_preset", 6, "Pure Default,Sunrise/Sunset🌅,Midday☀,Natural🌿,Golden Hour🌇,Crisp Clear❄,Manual")
    pure.script.ui.addSeparator()
    pure.script.ui.addCheckbox("lighting_affects_bloom", false)
    pure.script.ui.addText("↳ Allow presets to control bloom & glare effects")
    
    -- === SUN & DAYLIGHT ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("☀️ SUN & DAYLIGHT INTENSITY")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("daylight_multiplier", 1.0, 0.1, 10.0, "Overall daylight brightness multiplier")
    pure.script.ui.addSliderFloat("sun_level", 1.0, 0, 10.0, "Direct sunlight intensity")
    pure.script.ui.addSliderFloat("sun_speculars", 1.0, 0, 10.0, "Specular highlights from sun (reflections & shine)")
    
    -- === AMBIENT LIGHTING ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("💡 AMBIENT & SKY LIGHTING")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("ambient_level", 1.0, 0, 10.0, "Indirect/ambient light strength")
    pure.script.ui.addSliderFloat("advanced_ambient_light", 1.0, 0, 10.0, "Advanced ambient system multiplier")
    pure.script.ui.addSliderFloat("advanced_ambient_lightV2_sun", 1.0, 0.5, 10.0, "V2 ambient from sun contribution")
    pure.script.ui.addSliderFloat("sky_level", 1.0, 0, 10.0, "Sky illumination intensity")
    
    -- === CSP LIGHTS ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🔦 CSP LIGHTS (Custom Shaders Patch)")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("csp_lights_bounce", 1.0, 0.5, 10.0, "Light bounce/GI intensity")
    pure.script.ui.addSliderFloat("csp_lights_emissive", 1.0, 1.0, 10.0, "Emissive materials brightness")
    
    -- ========================================================================
    -- NIGHT LIGHTING PAGE - New separate page
    -- ========================================================================
    pure.script.ui.addPage("🌙Night")
    
    -- === NIGHT PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌃 NIGHT LIGHTING PRESETS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Optimized presets for different nighttime scenarios")
    pure.script.ui.addRadioButtons("night_preset", 0, "Bright Night🌕,Dark Night🌑,Cinematic🎥,Neon City🌃,Wet Night🌧,Manual")
    
    -- === LIGHT POLLUTION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🏙️ NIGHT LIGHT POLLUTION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("City/artificial light intensity in nighttime scenes")
    pure.script.ui.addSliderFloat("nlp_level", 1.0, 0.0, 10.0, "Overall light pollution intensity")
    pure.script.ui.addSliderFloat("nlp_density", 1.0, 0.0, 10.0, "Light pollution density/concentration")
    pure.script.ui.addSliderFloat("nlp_lowest_ambient", 1.0, 0.0, 10.0, "Minimum ambient light level (prevents pure black)")
    
    -- === MOON ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌙 MOON SETTINGS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("moon_light", 1.0, 0.0, 3.0, "Moonlight illumination strength")
    pure.script.ui.addSliderFloat("moon_appearance", 1.0, 0.0, 10.0, "Moon visual brightness in sky")
    
    -- === STARS ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("⭐ STARS & NIGHT SKY")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("stars_appearance", 1.0, 0.0, 100.0, "Star visibility & brightness")
    pure.script.ui.addCheckbox("stars_dynamic_adaption", true)
    pure.script.ui.addText("↳ Dynamically adjust stars based on exposure/lighting")
    
    -- === NIGHT CSP LIGHTS ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🔦 CSP LIGHTS (NIGHTTIME)")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Artificial light sources (headlights, street lights, etc.)")
    pure.script.ui.addSliderFloat("night_csp_lights_bounce", 1.0, 0.0, 10.0, "Light bounce/GI at night")
    pure.script.ui.addSliderFloat("night_csp_lights_emissive", 1.0, 0.0, 10.0, "Emissive materials at night")
    
    -- ========================================================================
    -- REFLECTIONS PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("✨Reflections")
    
    -- === REFLECTION PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🔮 REFLECTION QUALITY PRESETS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Photographic reflection balance from efficient to rich")
    pure.script.ui.addRadioButtons("reflections_preset", 6, "Pure Default,High Quality✨,Performance⚡,Cinematic🎥,Magical Shimmer✨,Ethereal Glow🌟,Manual")
    
    -- === REFLECTION PROPERTIES ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🪩 REFLECTION PROPERTIES")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("reflections_saturation", 1.0, 0, 2.0, "Color saturation in reflections")
    pure.script.ui.addSliderFloat("reflections_level", 1.0, 0, 2.0, "Overall reflection intensity")
    pure.script.ui.addSliderFloat("reflections_emissive_boost", 4.0, 0, 25.0, "Emissive reflection boost; realistic range is usually 1-16")
    
    -- === AMBIENT OCCLUSION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("👁️ AMBIENT OCCLUSION (VAO)")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Contact shadows & depth enhancement")
    pure.script.ui.addSliderFloat("vao_amount", 1.0, 0, 100.0, "VAO strength (adds depth to corners/crevices)")
    
    -- === ATMOSPHERIC INTERACTION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌫️ ATMOSPHERIC INTERACTION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("How fog affects reflections and surfaces")
    pure.script.ui.addSliderFloat("groundfog_gain", 1.053, 0, 3.0, "Ground fog influence on reflection clarity")
    
    -- ========================================================================
    -- FOG & WEATHER PAGE (hidden - fog logic remains active)
    -- ========================================================================
    -- Fog UI hidden but fog logic remains active (groundfog_gain moved to Reflections page)
    -- pure.script.ui.addPage("Fog & Weather")
    -- pure.script.ui.addText("Ground Fog Settings")
    -- pure.script.ui.addCheckbox("groundfog_active", true)
    -- pure.script.ui.addSliderFloat("groundfog_quality", 4, 1, 8)
    -- pure.script.ui.addCheckbox("groundfog_expand_width", true)
    -- pure.script.ui.addCheckbox("groundfog_interpolate_near", true)
    -- pure.script.ui.addSliderFloat("groundfog_render_distance", 2.0, 0.5, 10.0)
    -- pure.script.ui.addSliderFloat("groundfog_size", 1.0, 0.1, 3.0)
    -- pure.script.ui.addSliderFloat("groundfog_scale", 1.0, 0.1, 3.0)
    -- pure.script.ui.addSliderFloat("groundfog_structure", 1.0, 0.1, 2.0)
    -- pure.script.ui.addSliderFloat("groundfog_gain", 1.053, 0, 3.0)  -- Now in Reflections page
    -- pure.script.ui.addSliderFloat("groundfog_nearby_fadeout", 1.0, 0, 2.0)
    -- pure.script.ui.addSliderFloat("groundfog_sun_influence", 0.010, 0, 1.0)
    -- pure.script.ui.addCheckbox("groundfog_car_turbulences", true)
    
    -- ========================================================================
    -- SUN BLINDING PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("🌞SunEffects")
    
    -- === SUN BLINDING CORE ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("☀️ SUN BLINDING EFFECT")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Realistic eye adaptation when looking at the sun")
    pure.script.ui.addText("⚠️ NOTE: Works Only when sun blinding is enabled in CSP settings  ")
    pure.script.ui.addCheckbox("sunblinding_active", true)
    pure.script.ui.addText("↳ Enable sun blinding effect")
    pure.script.ui.addCheckbox("sunblinding_allow_control", true)
    pure.script.ui.addText("↳ Allow manual control of blinding parameters")
    pure.script.ui.addSliderFloat("sunblinding_sensitivity", 1.0, 0, 2.0, "How sensitive the effect is to sun exposure")
    pure.script.ui.addSliderFloat("sunblinding_time_up", 0.75, 0.1, 2.0, "Fade-in time when looking at sun (seconds)")
    pure.script.ui.addSliderFloat("sunblinding_time_down", 1.875, 0.5, 3.0, "Fade-out time when looking away (seconds)")
    
    -- === GOD RAYS ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("✨ GOD RAYS / VOLUMETRIC LIGHTING")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Light shafts through atmosphere (crepuscular rays)")
    pure.script.ui.addSliderFloat("godray_length", 10.0, 0, 20.0, "Length of god ray shafts (0=disabled)")
    pure.script.ui.addSliderFloat("sunblinding_cover", 0.063, 0, 1.0, "Sun corona/coverage intensity")
    pure.script.ui.addSliderFloat("sunblinding_blinding", 0.031, 0, 1.0, "Direct blinding intensity")
    pure.script.ui.addSliderFloat("sunblinding_iris", 0.625, 0, 2.0, "Iris/lens flare intensity")
    
    -- === STAR EFFECT ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("⭐ SUN STAR FLARE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Lens star pattern around bright sun")
    pure.script.ui.addSliderFloat("sunblinding_star_opacity", 0.400, 0, 2.0, "Star flare visibility")
    pure.script.ui.addSliderFloat("sunblinding_star_size", 2.0, 0.5, 10.0, "Star pattern size")
    pure.script.ui.addSliderFloat("sunblinding_star_blur", 0.548, 0, 10.0, "Star blur/softness")
    
    -- ========================================================================
    -- SKY LIGHT PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("🌤️Sky&Weather")
    
    -- === SKY PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("☁️ SKY ATMOSPHERE PRESETS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Different sky conditions from vivid to stormy")
    pure.script.ui.addRadioButtons("sky_preset", 3, "Pure Default,Vivid🌈,Cinematic🎥,Natural🌿,Golden Hour🌇,Overcast Soft☁️,Pastel Dawn🌅,Smog/City Haze🏙️,Storm Incoming⛈️,Manual")
    
    -- === SKY LIGHTING ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("☀️ SKY ILLUMINATION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("sky_light_level", 1.125, 0, 2.0, "Overall sky contribution to scene lighting")
    
    -- === SUN & MOON ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌞 SUN & MOON SIZE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Visual size of sun/moon disc in the sky")
    pure.script.ui.addSliderFloat("sun.sun_moon_size", 1.5, 0.5, 30.0, "Larger = more dramatic sun/moon appearance")
    -- Initialize sun/moon binding state: prefer engine config if present and keep UI synced
    local _cfg_init_sun_moon = pure.config.get("sun.sun_moon_size") or 0
    if _cfg_init_sun_moon and _cfg_init_sun_moon > 0 then
        if pure.script.ui.setValue then pure.script.ui.setValue("sun.sun_moon_size", _cfg_init_sun_moon) end
        _last_cfg_sun_moon = _cfg_init_sun_moon
        _last_ui_sun_moon = _cfg_init_sun_moon
    else
        _last_ui_sun_moon = pure.script.ui.getValue("sun.sun_moon_size")
        _last_cfg_sun_moon = _last_ui_sun_moon
    end
    pure.script.ui.addSeparator()
    
    -- === CLOUDS ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("☁️ CLOUD APPEARANCE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Daytime Clouds:")
    pure.script.ui.addSliderFloat("Daytime Clouds Brightness", 1.0, 0.0, 3.0, "Cloud brightness during day")
    pure.script.ui.addSliderFloat("Daytime Clouds Contrast", 1.0, 0.0, 3.0, "Cloud edge definition during day")
    pure.script.ui.addText("Nighttime Clouds:")
    pure.script.ui.addSliderFloat("Nighttime Clouds Brightness", 1.0, 0.0, 3.0, "Cloud visibility at night")
    pure.script.ui.addSliderFloat("Nighttime Clouds Contrast", 1.0, 0.0, 3.0, "Cloud edge definition at night")
    
    -- === SKY COLOR & SATURATION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌌 SKY COLOR & ATMOSPHERE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("Daytime Sky Level", 1.0, 0.0, 3.0, "Sky brightness during daytime")
    pure.script.ui.addSliderFloat("Duskdawn Sky Level", 0.25, 0.0, 10.0, "Sky intensity during sunrise/sunset")
    pure.script.ui.addSliderFloat("Daytime Sky Saturation", 1.0, 0.0, 3.0, "Sky color intensity (vivid vs washed out)")

    -- === SUNSET SUN SATURATION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌅 SUNSET SUN SATURATION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Extra saturation applied to the sun disc at sunset/sunrise only")
    pure.script.ui.addSliderFloat("sunset_sun_sat", 1.4, 1.0, 3.0, "Sun disc saturation at sunset/dawn (peaks at twilight, neutral at midday/night)")
    
    -- ========================================================================
    -- TONEMAPPING PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("🎨Tonemap")
    
    if CSP_VERSION >= 2349 then
        -- === TONEMAP MODES ===
        pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        pure.script.ui.addText("🌈 TONEMAPPING MODES")
        pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        pure.script.ui.addText("Each mode has unique color & dynamic range characteristics")
        pure.script.ui.addRadioButtons("Tonemapping", _l_current_tonemapping, "Neon Noir🖤,ST6IX Dusk🌆,Hyperchrome🌈,Retrograde🔁,BABAYAGA✨")
        pure.script.ui.addSeparator()
        set_tonemapping(1, _l_current_tonemapping)
        
        -- === ADVANCED TONEMAP CONTROLS ===
        pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        pure.script.ui.addText("⚙️ ADVANCED TONE CURVE CONTROLS")
        pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        pure.script.ui.addText("Fine-tune the tone response curve:")
        pure.script.ui.addSliderFloat("TONEMAPPING__maxDisplayBrightness", tonemap__custom.values.P, 0, 5, "Peak white point")
        pure.script.ui.addSliderFloat("TONEMAPPING__contrast", tonemap__custom.values.a, 0, 2, "Overall contrast")
        pure.script.ui.addSliderFloat("TONEMAPPING__linearSectionStart", tonemap__custom.values.m, 0.001, 1.00, "Linear region start (mid-gray point)")
        pure.script.ui.addSliderFloat("TONEMAPPING__linearSectionLength", tonemap__custom.values.l, 0, 0.98, "Linear region length")
        pure.script.ui.addSliderFloat("TONEMAPPING__black", tonemap__custom.values.c, 0, 2, "Black level/lift")
        pure.script.ui.addSliderFloat("TONEMAPPING__pedestal", tonemap__custom.values.b, -0.1, 0.1, "Black point offset")
        pure.script.ui.addSliderFloat("TONEMAPPING__gain", tonemap__custom.values.gain, 0, 10, "Overall brightness gain")
        
        pure.script.ui.addSeparator()
        pure.script.ui.addText("AGX Film Emulation:")
        pure.script.ui.addSliderFloat("TONEMAPPING__agx_mix", tonemap__custom.values.agx_mix, 0, 1, "AGX blend amount")
        pure.script.ui.addSliderFloat("TONEMAPPING__agx_mix_luma_exp", tonemap__custom.values.agx_mix_exp, 0, 1, "AGX luminance exponent")
        pure.script.ui.addSliderFloat("TONEMAPPING__agx_slope", tonemap__custom.values.agx_slope, 0, 2, "AGX slope (brightness)")
        pure.script.ui.addSliderFloat("TONEMAPPING__agx_power", tonemap__custom.values.agx_power, 0, 10, "AGX power (gamma)")
        pure.script.ui.addSliderFloat("TONEMAPPING__agx_sat", tonemap__custom.values.agx_sat, 0, 2, "AGX saturation")
        
        pure.script.ui.addSeparator()
        pure.script.ui.addText("ACES/BABAYAGA Settings:")
        pure.script.ui.addSliderFloat("TONEMAPPING__aces_exposure", 1.0, 0.1, 10.0, "ACES exposure compensation")
    else
        set_tonemapping(1, 0)
        pure.script.ui.addText("CSP version too old for advanced tonemapping")
    end

    -- === COLOR TEMPERATURE ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌡️ COLOR TEMPERATURE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Warm/cool tint per time of day (Kelvin: 3000=warm, 7500=neutral white, 9000=cool)")
    pure.script.ui.addSliderFloat("color_temp_day",   6500, 3000, 9000, "Color temperature for neutral daylight")
    pure.script.ui.addSliderFloat("color_temp_dusk",  5000, 3000, 9000, "Color temperature for a natural warm golden hour")
    pure.script.ui.addSliderFloat("color_temp_night", 6200, 3000, 9000, "Color temperature for clean night lighting")

    -- === REALISM & ADAPTATION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("📸 REALISM & ADAPTATION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("photo_realistic", 0.9, 0.0, 1.0, "Photo-realistic vs stylized (0=stylized, 1=realistic)")
    pure.script.ui.addSliderFloat("spectrum_adaption", 1.0, 0, 2, "Color spectrum shift with exposure")
    pure.script.ui.addSliderFloat("sun_blinding", 0.5, 0, 1.0, "Sun blinding influence on tonemapping")
    
    -- === MONITOR CALIBRATION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🖥️ MONITOR BLACK LEVEL ADJUSTMENTS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Compensate for monitor black levels (avoid pure black)")
    pure.script.ui.addSliderFloat("black_limit_low_exposure", 0.0, 0, 1, "Black crush prevention (bright scenes)")
    pure.script.ui.addSliderFloat("black_limit_high_exposure", 0.0, 0, 1, "Black crush prevention (dark scenes)")

    -- ========================================================================
    -- ADVANCED FOG SYSTEM PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("🌫️Fog")
    
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌫️ ATMOSPHERIC FOG SYSTEM")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Atmospheric fog modes with different characteristics")
    pure.script.ui.addRadioButtons("FOG Type", fogtype, "None,Immersive,Realistic")
    pure.script.ui.addText("↳ None: Disabled | Immersive: Heavy fog | Realistic: Natural")
    
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("⚙️ FOG PROPERTIES")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("Fog amount", 0.025, 0, 5, "Overall fog density")
    pure.script.ui.addSliderFloat("Fog Thickness", 0.005, -0.01, 0.09, "Fog layer thickness/vertical distribution")
    pure.script.ui.addSliderFloat("Fog Color mixer", 0.5, 0, 1, "Mix between sky color and fog color (0=sky, 1=fog)")

    -- ========================================================================
    -- BLOOM PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("✴️Bloom")
    pure.script.ui.addText("NATURAL BLOOM AND GLARE")
    pure.script.ui.addRadioButtons("ini_eye_preset_v2", 0, "Natural,Subtle,Soft Night,Bright Sources,City Lights,Wet Night,Golden Hour,Crisp Clear,Manual")
    pure.script.ui.addText("INI-matched bloom: compact halos with independent brightness and cutoff.")
    pure.script.ui.addCheckbox("ini_eye_bloom_enabled_v2", true)
    pure.script.ui.addSliderFloat("ini_eye_bloom_strength_v2", 1, 0, 2.0, "Visible bloom strength; 0 disables bloom only")
    pure.script.ui.addSliderFloat("ini_eye_bloom_threshold_v2", 0, -0.18, 0.20, "Bright-source cutoff offset; lower affects more pixels")
    pure.script.ui.addSliderFloat("ini_eye_bloom_radius_v2", 1, 0.45, 1.60, "Halo radius; 1 is the preset default")
    pure.script.ui.addSliderFloat("ini_eye_bloom_levels_v2", 0, -2, 2, "Bloom pass offset; kept within 2-6 passes")
    pure.script.ui.addSliderFloat("ini_eye_bloom_gamma_v2", 1, 0.85, 1.15, "Bloom response; 1 is neutral")
    pure.script.ui.addSeparator()
    pure.script.ui.addText("GLARE: INI-matched star controls, independent of bloom and profiles")
    pure.script.ui.addCheckbox("ini_eye_glare_enabled_v2", true)
    pure.script.ui.addSliderFloat("ini_eye_glare_brightness_v2", 0.12, 0, 0.60, "Star brightness; 0 disables the star component")
    pure.script.ui.addSliderFloat("ini_eye_glare_length_v2", 0.07, 0, 0.30, "Streak length; 0 removes streaks")
    pure.script.ui.addSliderFloat("ini_eye_glare_streaks_v2", 4, 2, 8, "Number of streaks; rounded to a whole number")
    pure.script.ui.addSliderFloat("ini_eye_glare_threshold_v2", 0.42, 0.10, 0.80, "Bright-source cutoff; higher restricts glare to brighter lights")
    pure.script.ui.addSliderFloat("ini_eye_glare_softness_v2", 0.80, 0.20, 1.50, "Star softness; matches the INI at 0.80")
    pure.script.ui.addText("Natural defaults are deliberately visible. Raise brightness briefly to test response.")
    pure.script.ui.addText("Lighting affects bloom may select a bloom preset; glare sliders remain independent.")

    -- ========================================================================
    -- LENS EFFECTS PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("📹LensFX")
    
    -- === LENS DISTORTION ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("📹 LENS DISTORTION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Simulate camera lens curvature (wide-angle/fisheye)")
    pure.script.ui.addCheckbox("Dashcam", false)
    pure.script.ui.addText("↳ Enable lens distortion effect ")
    pure.script.ui.addSliderFloat("Lens Distortion Roundness", 0, 0, 1.5, "Amount of barrel/pincushion distortion")
    pure.script.ui.addSliderFloat("Lens Distortion Smoothness", 0, 0, 1, "Edge smoothness of distortion")
    
    -- === VIGNETTE ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("📷 VIGNETTE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Darkening around image edges (natural lens falloff)")
    pure.script.ui.addSliderFloat("Vignette Intensity", 0.1, 0, 5, "Vignette strength (0=off, higher=darker edges)")
    
    -- === FILM GRAIN ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🎬 FILM GRAIN")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Analog film grain texture for cinematic look")
    pure.script.ui.addCheckbox("Enable Film Grain", false, "Toggle film grain effect on/off")
    pure.script.ui.addSliderFloat("Film Grain Strength", 1.0, 0, 10, "Film grain intensity multiplier")

    -- ========================================================================
    -- HDR & CLARITY PAGE - Enhanced visual quality
    -- ========================================================================
    pure.script.ui.addPage("🔍HDR&Clarity")
    
    -- === HDR PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🔍 HDR & CLARITY ENHANCEMENT")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Enhance image quality with HDR-grade sharpness & clarity")
    pure.script.ui.addRadioButtons("hdr_clarity_preset", 1, "Off,Subtle HDR🌤,Full HDR☀️,Ultra HDR🔥,Cinematic Sharp🎥,Manual")
    pure.script.ui.addSeparator()
    
    -- === SHARPNESS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🔪 SHARPNESS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Enhances edge definition and fine detail")
    pure.script.ui.addSliderFloat("hdr_sharpness", 0.35, 0.0, 1.0, "Sharpening intensity (0=off, 1=maximum)")
    pure.script.ui.addSeparator()
    
    -- === CLARITY & LOCAL CONTRAST ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("💎 CLARITY & LOCAL CONTRAST")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Boosts midtone contrast for a vivid, HDR-like look")
    pure.script.ui.addSliderFloat("hdr_clarity", 0.45, 0.0, 1.0, "Clarity amount (midtone contrast boost)")
    pure.script.ui.addSliderFloat("hdr_micro_contrast", 0.22, 0.0, 0.5, "Micro-contrast (fine texture detail)")
    pure.script.ui.addSeparator()
    
    -- === HDR ENHANCEMENT ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("✨ HDR ENHANCEMENT")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Expands perceived dynamic range and color depth")
    pure.script.ui.addSliderFloat("hdr_brightness_boost", 1.14, 0.8, 1.5, "HDR brightness boost (widens highlight range)")
    pure.script.ui.addSliderFloat("hdr_color_vibrance", 0.18, 0.0, 0.5, "Color vibrance (selective saturation boost)")
    pure.script.ui.addSliderFloat("hdr_highlight_recovery", 0.28, 0.0, 0.6, "Highlight recovery (preserves bright detail)")

    -- ========================================================================
    -- SKYDOMES PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("🌌Skydomes")
    
    -- === SKYDOME PRESETS ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🌌 CUSTOM SKYDOME PRESETS")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Replace sky with artistic cosmic backgrounds")
    pure.script.ui.addRadioButtons("Skydome Preset", 0, "OFF,ST6IX Nebula,ST6IX MADARA,ST6IX blackhole,ST6IX black-matter,ST6IX Black matter Colored")
    pure.script.ui.addText("↳ OFF: Normal sky | Others: Custom sky textures")
    
    -- === APPEARANCE ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("🎨 SKYDOME APPEARANCE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("Skydome Brightness", 1.0, 0.1, 5.0, "Skydome luminosity")
    pure.script.ui.addSliderFloat("Skydome Contrast", 1.0, 0.1, 3.0, "Skydome color contrast")
    
    -- === POSITION ===
    pure.script.ui.addSeparator()
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("📍 SKYDOME POSITION")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addSliderFloat("Skydome Rotation", 0.5, 0, 3, "Horizontal rotation angle")
    pure.script.ui.addSliderFloat("Skydome Height", 1.0, 0.5, 2.0, "Vertical position adjustment")

    -- ========================================================================
    -- EXPOSURE PAGE - Redesigned
    -- ========================================================================
    pure.script.ui.addPage("📷Exposure")
    
    pure.script.ui.addStateFloat("Final Exposure", 0)
    pure.script.ui.addStateFloat("CBE Exposure", 0)
    pure.script.ui.addStateFloat("Yebis Exposure", 0)
    pure.script.ui.addStateFloat("Occlusion", 0)
    pure.script.ui.addSeparator()

    pure.script.ui.addText("🌅  Morning / Day — Auto Exposure")
    pure.script.ui.addSliderFloat("Day Target Exposure", 0.08, 0.001, 0.25, "target for final exposure for day")
    pure.script.ui.addSliderFloat("Day Exposure Sensitivity", 2, 0.01, 10, "raise higher for more sensitive day exposure")
    pure.script.ui.addSliderFloat("AE Day Target", 4, 1.0, 16.0, "adjusts auto exposure target for day")
    pure.script.ui.addSliderFloat("Day AE Mix", 0.75, 0.01, 1.0, "adjusts auto exposure mix for day")
    pure.script.ui.addSeparator()

    pure.script.ui.addText("🌙  Night — Auto Exposure")
    pure.script.ui.addSliderFloat("Night Target Exposure", 0.75, 0.01, 2, "target for final exposure for night")
    pure.script.ui.addSliderFloat("Night Exposure Sensitivity", 1, 0.01, 10, "raise higher for more sensitive night exposure")
    pure.script.ui.addSliderFloat("AE Night Target", 6, 1.0, 16.0, "adjusts auto exposure target for night")
    pure.script.ui.addSliderFloat("Night AE Mix", 0.95, 0.01, 1.0, "adjusts auto exposure mix for night")
    pure.script.ui.addText("--- Interior Exposure Adjustments ---")
    pure.script.ui.addSliderFloat("Day Interior Exposure", 0.08, 0.01, 0.25, "day final exposure target")
    pure.script.ui.addSliderFloat("Night Interior Exposure", 0.75, 0.01, 3, "night final exposure target")
    pure.script.ui.addSliderFloat("AE Interior Day Target", 4, 1.0, 16.0, "adjusts auto exposure target for day")
    pure.script.ui.addSliderFloat("AE Interior Night Target", 6, 1.0, 16.0, "adjusts auto exposure target for night")

    pure.script.ui.addText("🌉  Tunnel Exposure")
    pure.script.ui.addRadioButtons("Tunnel Blinding Presets", 1, "Flash⚡,Blinding☀️,Normal")
    pure.script.ui.addText("Note: 'Blinding' isn't recommended, especially for occluded maps")
    pure.script.ui.addSliderFloat("Tunnel Blinding Strength", 1.35, 1, 2, "adjusts the strength of the tunnel blinding")

    -- keep engine exposure flags
    pure.config.set("light.ambient_model_V2", true, true)
    pure.config.set("AI_headlights.ambient_light", 0.5, true)
    
    -- Removed Pure's handleExposure initializer to avoid extra engine 'Method' UI
    -- (We use the consolidated Exilitay-style exposure controls instead.)
    
    -- === EXPOSURE MODE ===
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("📷 EXPOSURE MODE")
    pure.script.ui.addText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    pure.script.ui.addText("Choose exposure workflow")
    pure.script.ui.addRadioButtons("exposure_mode", 0, "Pure Native,ST6IX Custom")
    pure.script.ui.addText("↳ Pure Native preserves Pure/CSP EV and eye adaptation")
    pure.script.ui.addSeparator()
    
    -- Legacy ST6IX custom exposure UI 

    -- ========================================================================
    -- GOD RAYS PAGE (hidden - moved to Sun/Blinding page)
    -- ========================================================================
    -- pure.script.ui.addPage("God/Rays☀")
    -- pure.script.ui.addText("God Ray Settings☀")
    -- pure.script.ui.addSliderFloat("godray_length", 10.0, 0, 20.0)

    -- ========================================================================
    -- LIVE DIAGNOSTICS
    -- ========================================================================
    pure.script.ui.addPage("🔧Status")
    pure.script.ui.addText("Live values for testing this filter in-game")
    pure.script.ui.addStateFloat("Status: Script OK", 0)
    pure.script.ui.addStateFloat("Status: Tonemap", 0)
    pure.script.ui.addStateFloat("Status: Bloom", 0)
    pure.script.ui.addStateFloat("Status: Exposure Mode", 0)
    pure.script.ui.addStateFloat("Status: Exposure", 0)
    pure.script.ui.addStateFloat("Status: Interior", 0)
    pure.script.ui.addStateFloat("Status: Wetness", 0)
    pure.script.ui.addStateFloat("Status: Rain", 0)
    pure.script.ui.addStateFloat("Status: Weather Adaptation", 0)
    pure.script.ui.addText("Tonemap 0-4 | Bloom 0-8 | Exposure 0=Pure, 1=ST6IX")

    pure.pp.UseSpice()
    -- Also set multiple possible engine keys so slider always takes effect
    local _init_godray_length = pure.script.ui.getValue("godray_length")
    local _init_godray_intensity = math.min(2.0, math.max(0.0, _init_godray_length / 10.0))
    local _init_godray_active = (_init_godray_length > 0) and 1 or 0
    pure.config.set("godrays.active", _init_godray_active, true)
    pure.config.set("godrays.length", _init_godray_length, true)
    pure.config.set("godrays.intensity", _init_godray_intensity, true)

    -- Shader-prefixed variants (some engine builds expect these)
    pure.config.set("shaders.godrays.active", _init_godray_active, true)
    pure.config.set("shaders.godrays.length", _init_godray_length, true)
    pure.config.set("shaders.godrays.intensity", _init_godray_intensity, true)

    -- Alternative keys observed in some setups
    pure.config.set("shaders.sunrays.active", _init_godray_active, true)
    pure.config.set("shaders.sunrays.length", _init_godray_length, true)
    pure.config.set("shaders.sunrays.intensity", _init_godray_intensity, true)

    -- Post-processing namespace variants
    pure.config.set("pp.godrays.length", _init_godray_length, true)
    pure.config.set("pp.godrays.intensity", _init_godray_intensity, true)
    
    _l_init = false
end

-- ============================================================================
-- UPDATE FUNCTION - APPLIES ALL SLIDER VALUES
-- ============================================================================

-- V1.5: bounded, time-based environment adaptation. Missing optional telemetry
-- falls back to dry conditions, never to invented road wetness from humidity.
local st6ix_weather = {}
local function st6ix_unit(v, fallback)
    if type(v) ~= "number" or v ~= v then return fallback or 0 end
    return math.max(0, math.min(1, v))
end
local function st6ix_sample(fn, fallback)
    local ok, value = pcall(fn)
    return st6ix_unit(ok and value or nil, fallback)
end
local function st6ix_smooth(key, target, dt, seconds)
    local previous = st6ix_weather[key]
    if previous == nil then previous = target end
    local step = type(dt) == "number" and dt == dt and math.max(0, math.min(dt, 0.25)) or 0
    local value = previous + (target - previous) * (1 - math.exp(-step / seconds))
    st6ix_weather[key] = value
    return value
end
local function st6ix_environment(dt)
    local e = {}
    e.cloud = st6ix_smooth("cloud", st6ix_sample(function() return pure.world.getCloudCoverage() end), dt, 3)
    e.humidity = st6ix_smooth("humidity", st6ix_sample(function() return pure.world.getHumidity() end), dt, 4)
    e.shadow = st6ix_smooth("shadow", st6ix_sample(function() return pure.world.getCloudShadow() end), dt, 1.5)
    e.fog = st6ix_smooth("fog", st6ix_sample(function() return pure.world.getFog() end), dt, 4)
    e.wet = st6ix_smooth("wet", st6ix_sample(function() return ac.getSim().rainWetness end), dt, 4)
    e.rain = st6ix_smooth("rain", st6ix_sample(function() return ac.getSim().rainIntensity end), dt, 3)
    e.day = st6ix_smooth("day", st6ix_sample(function() return pure.mod.sun(0) * 10 end), dt, 2)
    e.golden = st6ix_smooth("golden", st6ix_sample(function() return pure.mod.twilight(0) end), dt, 2) * e.day
    e.cockpit = st6ix_smooth("cockpit", interior and 1 or 0, dt, 0.35)
    return e
end

function update_pure_script(dt)
    interior = ac.isInteriorView()
    photo_realistic = pure.script.ui.getValue("photo_realistic")

    local profile_index = math.floor(pure.script.ui.getValue("st6ix_profile"))
    local profile = ST6IX_PROFILES[profile_index] or ST6IX_PROFILES[3]
    local environment = st6ix_environment(dt)
    local realism = profile_index == 3 and 0 or st6ix_unit(pure.script.ui.getValue("weather_realism_v15"), 0.75)
    -- Copy before scaling: never mutate the preset table and compound per frame.
    if realism > 0 then
        local adjusted = {}
        for key, value in pairs(profile) do adjusted[key] = value end
        adjusted.bloom = profile.bloom * (1 + realism * (-0.10 * environment.day + 0.06 * environment.golden + 0.10 * environment.wet * (1 - environment.day)))
        adjusted.glare = profile.glare * (1 - 0.22 * realism * environment.cockpit)
        profile = adjusted
    end

    -- Preset overrides must be declared before either the day or night
    -- lighting blocks assign them. Declaring them later creates a separate
    -- local variable and silently discards the daytime override.
    local day_bloom_override
    local lighting_contrast_override, lighting_sharpness_override
    local night_bloom_override, night_refl_sat_override, night_glare_lum_override

    -- Helper: smooth morning/day and night compensation across twilight
    local function day_compensate(_)
        local sunpos = pure.mod.sun(0)
        if sunpos > 0.15 then return 1 end
        if sunpos < 0.10 then return 0 end
        return (sunpos - 0.10) / (0.05)
    end
    local function night_compensate(x)
        return 1 - day_compensate(x)
    end

    -- (preset handlers reverted)
    
    -- ========================================================================
    -- LIGHTING CONTROLS (with Preset Support) - Only apply during daytime
    -- ========================================================================
    local is_daytime = pure.mod.sun(0) > 0.1  -- Check if sun is above horizon
    local lighting_preset = math.floor(pure.script.ui.getValue("lighting_preset"))
    local daylight_multi, sun_level, sun_speculars, ambient_level, advanced_ambient, sky_level, ambient_v2_sun, csp_bounce, csp_emissive
    
    if lighting_preset == 3 and LIGHTING_PRESETS[3] then
        -- Always enforce Natural preset
        local p = LIGHTING_PRESETS[3]
        daylight_multi = p.daylight_multiplier
        sun_level = p.sun_level
        sun_speculars = p.sun_speculars
        ambient_level = p.ambient_level
        advanced_ambient = p.advanced_ambient_light
        sky_level = p.sky_level
        ambient_v2_sun = p.advanced_ambient_lightV2_sun
        csp_bounce = p.csp_lights_bounce
        csp_emissive = p.csp_lights_emissive
    elseif LIGHTING_PRESETS[lighting_preset] then
        -- Apply other presets only during daytime
        local p = LIGHTING_PRESETS[lighting_preset]
        daylight_multi = p.daylight_multiplier
        sun_level = p.sun_level
        sun_speculars = p.sun_speculars
        ambient_level = p.ambient_level
        advanced_ambient = p.advanced_ambient_light
        sky_level = p.sky_level
        ambient_v2_sun = p.advanced_ambient_lightV2_sun
        csp_bounce = p.csp_lights_bounce
        csp_emissive = p.csp_lights_emissive
    else
        -- Manual mode - use slider values
        daylight_multi = pure.script.ui.getValue("daylight_multiplier")
        sun_level = pure.script.ui.getValue("sun_level")
        sun_speculars = pure.script.ui.getValue("sun_speculars")
        ambient_level = pure.script.ui.getValue("ambient_level")
        advanced_ambient = pure.script.ui.getValue("advanced_ambient_light")
        sky_level = pure.script.ui.getValue("sky_level")
        ambient_v2_sun = pure.script.ui.getValue("advanced_ambient_lightV2_sun")
        csp_bounce = pure.script.ui.getValue("csp_lights_bounce")
        csp_emissive = pure.script.ui.getValue("csp_lights_emissive")
    end
    
    -- Small trims complement Pure's own weather lighting; no exposure changes.
    if realism > 0 and LIGHTING_PRESETS[lighting_preset] then
        sun_speculars = sun_speculars * (1 - 0.08 * realism * environment.cloud)
        ambient_level = ambient_level * (1 + 0.025 * realism * environment.cloud)
    end
    -- Only apply daylight settings when sun is up
    if is_daytime then
        pure.config.set("light.daylight_multiplier", daylight_multi, true)
        pure.config.set("light.sun.level", sun_level, true)
        pure.config.set("light.sun.speculars", sun_speculars, true)
        pure.config.set("light.ambient.level", ambient_level, true)
        pure.config.set("light.advanced_ambient_light", advanced_ambient, true)
        -- Sky level and cloud brightness are owned by the Sky & Weather block
        -- below, preventing these lighting values from being overwritten later.
        pure.config.set("light.advanced_ambient_lightV2_sun", ambient_v2_sun, true)
        pure.config.set("csp_lights.bounce", csp_bounce, true)
        pure.config.set("csp_lights.emissive", csp_emissive, true)

        -- Lighting preset specific post-processing overrides (contrast/sharpness/bloom)
        if LIGHTING_PRESETS[lighting_preset] then
            local lp = LIGHTING_PRESETS[lighting_preset]
            -- Apply finishing overrides once in the final HDR/clarity block.
            lighting_contrast_override = lp.pp_contrast
            lighting_sharpness_override = lp.pp_sharpness
            -- Respect user toggle: only allow lighting presets to override Bloom/Glare if enabled
            if pure.script.ui.getValue("lighting_affects_bloom") then
                day_bloom_override = lp.bloom_preset
            else
                day_bloom_override = nil
            end
        end
    end
    
    -- Nightlight settings (with Preset Support) - Only apply at night
    local is_night = pure.mod.sun(0) < 0.1  -- Check if sun is below horizon
    local night_preset = math.floor(pure.script.ui.getValue("night_preset"))
    local nlp_level, nlp_density, nlp_lowest_ambient, moon_light, moon_appearance, stars_appearance, stars_dynamic
    
    local night_csp_lights_bounce, night_csp_lights_emissive

    if night_preset == 2 and NIGHT_PRESETS[2] then
        -- Always enforce Cinematic night preset
        local p = NIGHT_PRESETS[2]
        nlp_level = p.nlp_level
        nlp_density = p.nlp_density
        nlp_lowest_ambient = p.nlp_lowest_ambient
        moon_light = p.moon_light
        moon_appearance = p.moon_appearance
        stars_appearance = p.stars_appearance
        stars_dynamic = p.stars_dynamic
        night_csp_lights_bounce = p.csp_lights_bounce
        night_csp_lights_emissive = p.csp_lights_emissive
    elseif NIGHT_PRESETS[night_preset] then
        -- Apply other presets only at night
        local p = NIGHT_PRESETS[night_preset]
        nlp_level = p.nlp_level
        nlp_density = p.nlp_density
        nlp_lowest_ambient = p.nlp_lowest_ambient
        moon_light = p.moon_light
        moon_appearance = p.moon_appearance
        stars_appearance = p.stars_appearance
        stars_dynamic = p.stars_dynamic
        night_csp_lights_bounce = p.csp_lights_bounce
        night_csp_lights_emissive = p.csp_lights_emissive
    else
        -- Manual mode (index 5 or not found) - use slider values
        nlp_level = pure.script.ui.getValue("nlp_level")
        nlp_density = pure.script.ui.getValue("nlp_density")
        nlp_lowest_ambient = pure.script.ui.getValue("nlp_lowest_ambient")
        moon_light = pure.script.ui.getValue("moon_light")
        moon_appearance = pure.script.ui.getValue("moon_appearance")
        stars_appearance = pure.script.ui.getValue("stars_appearance")
        stars_dynamic = pure.script.ui.getValue("stars_dynamic_adaption")
        night_csp_lights_bounce = pure.script.ui.getValue("night_csp_lights_bounce")
        night_csp_lights_emissive = pure.script.ui.getValue("night_csp_lights_emissive")
    end
    
    -- Apply stars settings always (Pure handles day/night visibility automatically)
    pure.config.set("stars.appearance", stars_appearance, true)
    pure.config.set("stars.dynamic_adaption", stars_dynamic and 1 or 0, true)
    
    -- Only apply night-specific presets when sun is down (nlp/csp)
    if is_night then
        pure.config.set("nlp.level", nlp_level, true)
        pure.config.set("nlp.density", nlp_density, true)
        pure.config.set("nlp.lowest_ambient", nlp_lowest_ambient, true)
        pure.config.set("csp_lights.bounce", night_csp_lights_bounce, true)
        pure.config.set("csp_lights.emissive", night_csp_lights_emissive, true)
    end

    -- Moon settings: ramp in/out smoothly during twilight so they visibly take effect over frames
    local _sun_pos_for_moon = pure.mod.sun(0)
    local _moon_factor = 0
    if _sun_pos_for_moon < 0.1 then
        _moon_factor = 1
    elseif _sun_pos_for_moon > 0.15 then
        _moon_factor = 0
    else
        local _blend2 = (_sun_pos_for_moon - 0.1) / 0.05 -- 0 at night, 1 at day
        _moon_factor = math.max(0, math.min(1, 1 - _blend2))
    end
    local _moon_light_set = (moon_light or 0) * _moon_factor
    local _moon_appearance_set = math.lerp(1.0, (moon_appearance or 1.0), _moon_factor)
    pure.config.set("moon.light", _moon_light_set, true)
    pure.config.set("moon.appearance", _moon_appearance_set, true)

    -- Night preset specific overrides (bloom/reflection/etc.)
    if is_night and NIGHT_PRESETS[night_preset] then
        local np = NIGHT_PRESETS[night_preset]
        -- Respect user toggle: only allow night presets to override Bloom/Glare if enabled
        if pure.script.ui.getValue("lighting_affects_bloom") then
            night_bloom_override = np.bloom_preset
            night_glare_lum_override = np.glare_star_luminance
        else
            night_bloom_override = nil
            night_glare_lum_override = nil
        end
        night_refl_sat_override = np.reflections_saturation
    end
    
    -- ========================================================================
    -- REFLECTIONS (with Preset Support)
    -- ========================================================================
    local reflections_preset = math.floor(pure.script.ui.getValue("reflections_preset"))
    local refl_sat, refl_level, refl_emissive, vao_amount, fog_gain_val
    
    if REFLECTIONS_PRESETS[reflections_preset] then
        -- Apply preset values every frame
        local p = REFLECTIONS_PRESETS[reflections_preset]
        refl_sat = p.reflections_saturation
        refl_level = p.reflections_level
        refl_emissive = p.reflections_emissive_boost
        vao_amount = p.vao_amount
        fog_gain_val = p.groundfog_gain
    else
        -- Manual mode - use slider values
        refl_sat = pure.script.ui.getValue("reflections_saturation")
        refl_level = pure.script.ui.getValue("reflections_level")
        refl_emissive = pure.script.ui.getValue("reflections_emissive_boost")
        vao_amount = pure.script.ui.getValue("vao_amount")
        fog_gain_val = pure.script.ui.getValue("groundfog_gain")
    end

    -- Night preset can override reflections saturation
    if is_night and night_refl_sat_override then
        refl_sat = night_refl_sat_override
    end

    if realism > 0 and REFLECTIONS_PRESETS[reflections_preset] then
        refl_level = refl_level * (1 + realism * (0.12 * environment.wet - 0.04 * environment.day * (1 - environment.wet)))
        refl_emissive = refl_emissive * (1 + realism * (-0.18 * environment.day + 0.12 * environment.wet * (1 - environment.day)))
        refl_sat = 1 + (refl_sat - 1) * (1 - 0.35 * realism)
    end
    pure.config.set("reflections.saturation", refl_sat, true)
    pure.config.set("reflections.level", refl_level, true)
    pure.config.set("reflections.emissive_boost", refl_emissive, true)
    pure.config.set("vao.amount", vao_amount, true)
    
    -- ========================================================================
    -- GROUND FOG (UI hidden but fog remains active)
    -- ========================================================================
    local fog_active = math.floor(pure.script.ui.getValue("FOG Type")) ~= 0
    local fog_quality = 4    -- Default quality
    local fog_size = 0.5     -- Reduced size for less aggressive fog
    local fog_scale = 0.6    -- Reduced scale
    local fog_structure = 0.8 -- Slightly reduced structure
    local fog_gain = fog_gain_val  -- From Reflections preset/slider
    if realism > 0 then
        local moisture = math.max(environment.fog, environment.rain, math.max(0, (environment.humidity - 0.65) / 0.35))
        fog_gain = fog_gain * (1 + realism * (0.30 + 0.70 * moisture - 1))
    end
    local fog_nearby = 1.5   -- Increased fadeout near camera
    local fog_sun = 0.005    -- Reduced sun influence
    local fog_render_dist = 1.5 -- Reduced render distance
    local fog_car_turb = true   -- Default car turbulences
    
    pure.config.set("shaders.groundfog.active", fog_active and 1 or 0, true)
    pure.config.set("shaders.groundfog.Quality", fog_quality, true)
    pure.config.set("shaders.groundfog.Size", fog_size, true)
    pure.config.set("shaders.groundfog.Scale", fog_scale, true)
    pure.config.set("shaders.groundfog.Structure", fog_structure, true)
    pure.config.set("shaders.groundfog.Gain", fog_gain, true)
    pure.config.set("shaders.groundfog.Nearby_fadeout", fog_nearby, true)
    pure.config.set("shaders.groundfog.Sun_influence", fog_sun, true)
    pure.config.set("shaders.groundfog.Render_distance", fog_render_dist, true)
    pure.config.set("shaders.groundfog.Car_turbulences", fog_car_turb and 1 or 0, true)
    
    -- ========================================================================
    -- SUN BLINDING (matches SDK screenshot)
    -- ========================================================================
    local sun_blind_active = pure.script.ui.getValue("sunblinding_active")
    local sun_blind_sensitivity = pure.script.ui.getValue("sunblinding_sensitivity")
    local sun_blind_time_up = pure.script.ui.getValue("sunblinding_time_up")
    local sun_blind_time_down = pure.script.ui.getValue("sunblinding_time_down")
    local sun_blind_cover = pure.script.ui.getValue("sunblinding_cover")
    local sun_blind_blinding = pure.script.ui.getValue("sunblinding_blinding")
    local sun_blind_iris = pure.script.ui.getValue("sunblinding_iris")
    local sun_star_opacity = pure.script.ui.getValue("sunblinding_star_opacity")
    local sun_star_size = pure.script.ui.getValue("sunblinding_star_size")
    local sun_star_blur = pure.script.ui.getValue("sunblinding_star_blur")
    
    if pure.shader.isRunning("sunblinding") then
        pure.config.set("shaders.sunblinding.active", sun_blind_active and 1 or 0, true)
        pure.config.set("shaders.sunblinding.sensitivity", sun_blind_sensitivity, true)
        pure.config.set("shaders.sunblinding.time_up", sun_blind_time_up, true)
        pure.config.set("shaders.sunblinding.time_down", sun_blind_time_down, true)
        pure.config.set("shaders.sunblinding.cover", sun_blind_cover, true)
        pure.config.set("shaders.sunblinding.blinding", sun_blind_blinding, true)
        pure.config.set("shaders.sunblinding.iris", sun_blind_iris, true)
        pure.config.set("shaders.sunblinding.star_opacity", sun_star_opacity, true)
        pure.config.set("shaders.sunblinding.star_size", sun_star_size, true)
        pure.config.set("shaders.sunblinding.star_blur", sun_star_blur, true)
        
        cam_sun_face = pure.utils.CamFacesSun() * pure.script.ui.getValue("sun_blinding") * 0.6666667
    else
        cam_sun_face = 0
    end
    
    -- ========================================================================
    -- SKY & SUN/MOON (with Preset Support)
    -- ========================================================================
    local sky_preset = math.floor(pure.script.ui.getValue("sky_preset"))
    local sky_light, sun_moon, day_clouds_bright, day_clouds_contrast, night_clouds_bright, night_clouds_contrast
    local day_sky_level, dusk_sky_level, day_sky_sat
    
    if SKY_PRESETS[sky_preset] then
        -- Apply preset values every frame
        local p = SKY_PRESETS[sky_preset]
        if p.day and p.night then
            -- New day/night structured presets
            sky_light = p.day.sky_light_level or p.day.sky_level or 1.0
            -- Support distinct day/night sun/moon size values and fall back to day when missing
            day_sun_moon = p.day["sun.sun_moon_size"] or p.day.sun_moon_size or p.day.sun_moon or 1.0
            night_sun_moon = p.night["sun.sun_moon_size"] or p.night.sun_moon_size or p.night.sun_moon or day_sun_moon
            day_clouds_bright = p.day.clouds_brightness
            day_clouds_contrast = p.day.clouds_contrast
            night_clouds_bright = p.night.clouds_brightness
            night_clouds_contrast = p.night.clouds_contrast
            day_sky_level = p.day.sky_level
            dusk_sky_level = p.duskdawn_sky_level
            day_sky_sat = p.day.sky_saturation
        else
            -- Backwards-compatible legacy fields
            sky_light = p.sky_light_level
            -- Legacy presets only have a single sun_moon value; use it for both day and night
            day_sun_moon = p["sun.sun_moon_size"] or p.sun_moon_size or p.sun_moon or 1.0
            night_sun_moon = day_sun_moon
            day_clouds_bright = p.daytime_clouds_brightness
            day_clouds_contrast = p.daytime_clouds_contrast
            night_clouds_bright = p.nighttime_clouds_brightness
            night_clouds_contrast = p.nighttime_clouds_contrast
            day_sky_level = p.daytime_sky_level
            dusk_sky_level = p.duskdawn_sky_level
            day_sky_sat = p.daytime_sky_saturation
        end
    else
        -- Manual mode - use slider values
        sky_light = pure.script.ui.getValue("sky_light_level")

        -- Two-way binding between UI slider and engine config 'sun.sun_moon_size':
        -- * If engine config exists/changes, update UI and use it
        -- * If user changes UI, write back to engine config
        local cfg_sun_moon = pure.config.get("sun.sun_moon_size") or 0
        local ui_sun_moon = pure.script.ui.getValue("sun.sun_moon_size")

        -- Detect external config change -> prefer config and update UI
        if cfg_sun_moon > 0 and (_last_cfg_sun_moon == nil or cfg_sun_moon ~= _last_cfg_sun_moon) then
            day_sun_moon = cfg_sun_moon
            night_sun_moon = cfg_sun_moon
            if pure.script.ui.setValue then pure.script.ui.setValue("sun.sun_moon_size", cfg_sun_moon) end
            _last_cfg_sun_moon = cfg_sun_moon
            _last_ui_sun_moon = cfg_sun_moon
        -- Detect UI change by user -> write to config and use it
        elseif ui_sun_moon ~= _last_ui_sun_moon then
            day_sun_moon = ui_sun_moon
            night_sun_moon = ui_sun_moon
            pure.config.set("sun.sun_moon_size", ui_sun_moon, true)
            _last_ui_sun_moon = ui_sun_moon
            _last_cfg_sun_moon = ui_sun_moon
        else
            -- Stable state: prefer config when present, otherwise UI
            if cfg_sun_moon and cfg_sun_moon > 0 then
                day_sun_moon = cfg_sun_moon
                night_sun_moon = cfg_sun_moon
            else
                day_sun_moon = ui_sun_moon
                night_sun_moon = ui_sun_moon
            end
        end

        day_clouds_bright = pure.script.ui.getValue("Daytime Clouds Brightness")
        day_clouds_contrast = pure.script.ui.getValue("Daytime Clouds Contrast")
        night_clouds_bright = pure.script.ui.getValue("Nighttime Clouds Brightness")
        night_clouds_contrast = pure.script.ui.getValue("Nighttime Clouds Contrast")
        day_sky_level = pure.script.ui.getValue("Daytime Sky Level")
        dusk_sky_level = pure.script.ui.getValue("Duskdawn Sky Level")
        day_sky_sat = pure.script.ui.getValue("Daytime Sky Saturation")
    end
    
    -- Apply sky settings (non-cloud related). Use one authoritative level so a
    -- second write cannot silently cancel the first one.
    -- Smoothly interpolate sun/moon size between day and night across twilight for frame-accurate changes
    local _sun_pos_for_size = pure.mod.sun(0)
    local _sun_size = day_sun_moon or 1.0
    local _night_size = night_sun_moon or _sun_size
    if _sun_pos_for_size > 0.15 then
        _sun_size = day_sun_moon
    elseif _sun_pos_for_size < 0.1 then
        _sun_size = _night_size
    else
        local _blend = (_sun_pos_for_size - 0.1) / 0.05 -- 0 at night, 1 at day
        _sun_size = math.lerp(_night_size, day_sun_moon, _blend)
    end
    pure.config.set("sun.size", _sun_size, true)
    pure.config.set("light.sky.level", day_sky_level or sky_light or 1.0, true)
    pure.config.set("light.sky.dusk_dawn_level", dusk_sky_level, true)
    pure.config.set("light.sky.day_saturation", day_sky_sat, true)

    -- Sunset sun saturation: peaks at twilight, falls back to 1.0 at midday and night
    local _sunset_tw = math.max(0, 1.0 - pure.mod.dayCurve(1, 0, 1) - pure.mod.nightCurve(1, 0, 1))
    local _sunset_sun_sat_target = pure.script.ui.getValue("sunset_sun_sat")
    local _sunset_sun_sat = math.lerp(1.0, _sunset_sun_sat_target, _sunset_tw)
    pure.config.set("light.sun.saturation", _sunset_sun_sat, true)
    
    -- Apply cloud settings based on time of day
    local sun_pos = pure.mod.sun(0)
    local is_day_clouds = sun_pos > 0.15  -- Daytime threshold
    local is_night_clouds = sun_pos < 0.1  -- Nighttime threshold
    local is_transition = not is_day_clouds and not is_night_clouds  -- Twilight
    
    if is_day_clouds then
        -- Apply daytime cloud settings
        pure.config.set("clouds2D.brightness", day_clouds_bright, true)
        pure.config.set("clouds2D.contrast", day_clouds_contrast, true)
    elseif is_night_clouds then
        -- Apply nighttime cloud settings
        pure.config.set("clouds2D.brightness", night_clouds_bright, true)
        pure.config.set("clouds2D.contrast", night_clouds_contrast, true)
    else
        -- Twilight transition - blend between day and night
        local blend = (sun_pos - 0.1) / 0.05  -- 0 at night, 1 at day
        local blended_bright = math.lerp(night_clouds_bright, day_clouds_bright, blend)
        local blended_contrast = math.lerp(night_clouds_contrast, day_clouds_contrast, blend)
        pure.config.set("clouds2D.brightness", blended_bright, true)
        pure.config.set("clouds2D.contrast", blended_contrast, true)
    end
    
    -- (unified preset handler and duplicate binary helpers reverted)

    local exposure_ok, exposure_err = true, nil
    if math.floor(pure.script.ui.getValue("exposure_mode")) == 1 then
        exposure_ok, exposure_err = pcall(function()
        local AETargetDay = pure.script.ui.getValue("AE Day Target")*day_compensate(0)
        local AETargetNight = pure.script.ui.getValue("AE Night Target")*night_compensate(0)

        local AETargetDayInterior = pure.script.ui.getValue("AE Interior Day Target")*day_compensate(0)
        local AETargetNightInterior = pure.script.ui.getValue("AE Interior Night Target")*night_compensate(0)

        local DaySensitivity = 1* pure.script.ui.getValue("Day Exposure Sensitivity")*day_compensate(0)
        local NightSensitivity = 1* pure.script.ui.getValue("Night Exposure Sensitivity")*night_compensate(0)

        local AESensitivity = (DaySensitivity)+(NightSensitivity)

        local yebisDay = 1
        local yebisNight = 0.5

        local yebisDayInterior = 1
        local yebisNightInterior = 0.5

        local yebisTarget = (yebisDay)+(yebisNight)
        local yebisInteriorTarget = (yebisDayInterior)+(yebisNightInterior)

        local dayMix = pure.script.ui.getValue("Day AE Mix")
        local nightMix = pure.script.ui.getValue("Night AE Mix")

        local finalAEMix = (day_compensate(0) * dayMix) + (night_compensate(0) * nightMix)

        local AEFinal = math.lerp(pure.exposure.getValue(), 0.015, 0.050)

        --exposure presets--
        local TunnelBlinding = 1
        local FlashPreset = pure.script.ui.getValue("Tunnel Blinding Presets")
        local BlindingStrength = pure.script.ui.getValue("Tunnel Blinding Strength")
        -- derive TunnelBlinding using ST6IX occlusion LUT if available, else keep 1
        local oc = pure.camera.getOcclusion()
        if FlashPreset == 0 then
            TunnelBlinding = math.lerp(2* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.55, 0.775))
        elseif FlashPreset == 1 then
            TunnelBlinding = math.lerp(3* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.575, 0.75))
        else
            TunnelBlinding = math.lerp(1* BlindingStrength, 1.0, math.lerpInvSat(oc, 0.575, 0.75))
        end

        if pure.exposure and pure.exposure.cbe and pure.exposure.yebis then
            pure.exposure.cbe.setTarget((AETargetDay*TunnelBlinding)+(AETargetNight))
            pure.exposure.cbe.setSensitivity(AESensitivity)
            pure.exposure.cbe.setLimits((0.025 + 0.05),(5 + 5))
            pure.exposure.cbe.setAdaptionSpeeds(20, 4)
            pure.exposure.yebis.setTarget(yebisTarget)
            pure.exposure.yebis.setLimits(0.15, 0.75)
            pure.exposure.yebis.setAdaptionSpeeds(50, 15)
            pure.exposure.setCBEMix(finalAEMix)
            pure.exposure.setBypass(math.lerp(
                AEFinal,
                (pure.script.ui.getValue("Day Target Exposure") * day_compensate(0) +
                 pure.script.ui.getValue("Night Target Exposure") * night_compensate(0)),
                pure.mod.day(0) + pure.mod.night(0)
            ), finalAEMix)
        end

        -- Interior exposure uses the same locally calculated values. Keeping
        -- this block inside the pcall prevents nil-variable failures when
        -- switching to cockpit view.
        if ac.isInteriorView() == true and pure.exposure and pure.exposure.cbe and pure.exposure.yebis then
            pure.exposure.cbe.setTarget((AETargetDayInterior*TunnelBlinding)+(AETargetNightInterior))
            pure.exposure.cbe.setSensitivity(AESensitivity)
            pure.exposure.cbe.setLimits((0.025 + 0.05),(5 + 5))
            pure.exposure.cbe.setAdaptionSpeeds(20, 4)
            pure.exposure.yebis.setTarget(yebisInteriorTarget)
            pure.exposure.yebis.setLimits(0.15, 0.75)
            pure.exposure.yebis.setAdaptionSpeeds(50, 15)
            pure.exposure.setCBEMix(finalAEMix)
            pure.exposure.setBypass(math.lerp(
                AEFinal,
                (pure.script.ui.getValue("Day Interior Exposure") * day_compensate(0) +
                 pure.script.ui.getValue("Night Interior Exposure") * night_compensate(0)),
                pure.mod.day(0) + pure.mod.night(0)
            ), finalAEMix)
        end

        -- Update readout state floats so the UI shows live values
        if pure.script.ui.setValue then
            -- Final exposure from Pure's exposure system
            pcall(function()
                if pure.exposure and pure.exposure.getValue then
                    pure.script.ui.setValue("Final Exposure", pure.exposure.getValue())
                end
            end)
            -- Occlusion (tunnel) value
            pcall(function()
                pure.script.ui.setValue("Occlusion", pure.camera.getOcclusion())
            end)
        end
        end)
    end

    if not exposure_ok then
        local error_text = tostring(exposure_err)
        if error_text ~= _last_exposure_error then
            ac.log("ST6IX V1.3 exposure: " .. error_text)
            _last_exposure_error = error_text
        end
    else
        _last_exposure_error = nil
    end
    
    -- ========================================================================
    -- BLOOM CONTROLS (with Preset Support)
    -- ========================================================================
    local function bounded(x, lo, hi) return math.max(lo, math.min(hi, x)) end
    local function knob(key, default)
        local x = pure.script.ui.getValue(key)
        return type(x) == "number" and x == x and x or default
    end
    local bloom_preset_ui = bounded(math.floor(knob("ini_eye_preset_v2", 0)), 0, 8)
    local bloom_preset = bloom_preset_ui
    if bloom_preset_ui ~= 8 then
        if is_night and night_bloom_override then bloom_preset = night_bloom_override end
        if not is_night and day_bloom_override then bloom_preset = day_bloom_override end
    end
    local p = BLOOM_PRESETS[bloom_preset] or {
        bloom_intensity=0.34, bloom_threshold=0.46, bloom_filter=0.001,
        bloom_radius=0.46, bloom_levels=4, bloom_gamma=1.02
    }
    local bloom_enabled = pure.script.ui.getValue("ini_eye_bloom_enabled_v2") == true
    local glare_enabled = pure.script.ui.getValue("ini_eye_glare_enabled_v2") == true
    local bloom_int = p.bloom_intensity * bounded(knob("ini_eye_bloom_strength_v2", 1), 0, 2)
    if not bloom_enabled then bloom_int = 0 end
    local bloom_thresh = bounded(p.bloom_threshold + bounded(knob("ini_eye_bloom_threshold_v2", 0), -0.18, 0.20), 0.20, 0.80)
    local bloom_filter = bounded(p.bloom_filter or 0.001, 0.0001, 0.005)
    local bloom_rad = bounded(p.bloom_radius * bounded(knob("ini_eye_bloom_radius_v2", 1), 0.45, 1.60), 0.12, 0.90)
    local bloom_levels = bounded(math.floor(p.bloom_levels + bounded(knob("ini_eye_bloom_levels_v2", 0), -2, 2) + 0.5), 2, 6)
    local bloom_gamma = bounded(p.bloom_gamma * knob("ini_eye_bloom_gamma_v2", 1), 0.85, 1.20)

    -- Keep only a subtle camera difference. The old profile stack reduced
    -- Drive-mode bloom to roughly 49%, hiding slider changes against this INI.
    local camera_bloom = interior and 0.82 or 1.0
    local bloom_output = bloom_int * camera_bloom

    -- Direct glare values are not multiplied by profile or weather strength.
    local star_len = bounded(knob("ini_eye_glare_length_v2", 0.07), 0, 0.30)
    local star_lum = bounded(knob("ini_eye_glare_brightness_v2", 0.12), 0, 0.60)
    local star_streaks = bounded(math.floor(knob("ini_eye_glare_streaks_v2", 4) + 0.5), 2, 8)
    local star_threshold_ui = bounded(knob("ini_eye_glare_threshold_v2", 0.42), 0.10, 0.80)
    local star_filter = 0.0001 + star_threshold_ui * 0.0030
    local star_softness = bounded(knob("ini_eye_glare_softness_v2", 0.80), 0.20, 1.50)
    if not glare_enabled or star_len == 0 then star_lum = 0 end

    -- Every runtime property is isolated. A CSP/Pure build rejecting one
    -- optional property must never stop the rest of bloom, glare or tonemapping.
    local function safe_yebis(key, value)
        if st6ix_bloom_field_errors[key] then return end
        local ok, err = pcall(pure.yebis.set, key, value)
        if not ok then
            st6ix_bloom_field_errors[key] = true
            pcall(function() ac.log("ST6IX bloom/glare optional field " .. key .. ": " .. tostring(err)) end)
        end
    end
    safe_yebis("glareEnabled", bloom_output > 0 or star_lum > 0)
    safe_yebis("glareUseCustomShape", true)
    safe_yebis("glareLuminance", 1.0)
    safe_yebis("glareShapeLuminance", 1.0)
    safe_yebis("glareThreshold", math.min(bloom_thresh, star_threshold_ui))
    safe_yebis("glareBloomLevels", bloom_levels)
    safe_yebis("glareShapeBloomLuminance", bloom_output)
    safe_yebis("glareBloomLuminanceGamma", bloom_gamma)
    safe_yebis("glareBloomFilterThreshold", bloom_filter)
    safe_yebis("glareBloomGaussianRadiusScale", bloom_rad)
    safe_yebis("glareShapeStarLength", star_len)
    safe_yebis("glareShapeStarLuminance", star_lum)
    safe_yebis("glareShapeStarStreaksNumber", star_streaks)
    safe_yebis("glareStarFilterThreshold", star_filter)
    safe_yebis("glareStarSoftness", star_softness)
    safe_yebis("glareStarLengthFOVDependence", 0)
    safe_yebis("glareGenerationRangeScale", 0.07)
    safe_yebis("glareBlur", 0.8)
    safe_yebis("glareShapeStarSecondaryLength", 0)
    safe_yebis("glareShapeStarDispersion", 0)
    safe_yebis("glareShapeStarForceDispersion", false)
    safe_yebis("glareShapeBloomDispersion", 0)
    safe_yebis("glareShapeBloomDispersionBaseLevel", 0)
    safe_yebis("glareShapeGhostLuminance", 0)
    safe_yebis("glareShapeGhostHaloLuminance", 0)
    safe_yebis("glareShapeAfterimageLuminance", 0)

    -- Apply tonemapping immediately after the confirmed-working bloom block.
    -- The old call was near the end of update_pure_script(), so any unrelated
    -- error in fog, skydomes or finishing effects prevented it from running.
    local active_tonemap = math.floor(pure.script.ui.getValue("Tonemapping") or 2)
    set_tonemapping(dt, active_tonemap)

    pcall(function()
        pure.script.ui.setValue("Status: Script OK", 1)
        pure.script.ui.setValue("Status: Tonemap", active_tonemap)
        pure.script.ui.setValue("Status: Bloom", bloom_preset)
        pure.script.ui.setValue("Status: Wetness", environment.wet)
        pure.script.ui.setValue("Status: Rain", environment.rain)
        pure.script.ui.setValue("Status: Weather Adaptation", realism)
        pure.script.ui.setValue("Status: Exposure Mode", math.floor(pure.script.ui.getValue("exposure_mode") or 0))
        pure.script.ui.setValue("Status: Exposure", pure.exposure.getValue())
        pure.script.ui.setValue("Status: Interior", interior and 1 or 0)
    end)

    -- ========================================================================
    -- GOD RAYS (controlled only by length; active when length > 0)
    -- ========================================================================
    local godray_len = pure.script.ui.getValue("godray_length")
    -- These compatibility keys only need rewriting when the slider changes.
    if _last_godray_length ~= godray_len then
        local godray_intensity = math.min(2.0, math.max(0.0, godray_len / 10.0))
        local godray_active = (godray_len > 0) and 1 or 0

        -- Primary keys
        pure.config.set("godrays.active", godray_active, true)
        pure.config.set("godrays.length", godray_len, true)
        pure.config.set("godrays.intensity", godray_intensity, true)

        -- Compatibility namespaces for older Pure/CSP builds.
        pure.config.set("shaders.godrays.active", godray_active, true)
        pure.config.set("shaders.godrays.length", godray_len, true)
        pure.config.set("shaders.godrays.intensity", godray_intensity, true)

        pure.config.set("shaders.sunrays.active", godray_active, true)
        pure.config.set("shaders.sunrays.length", godray_len, true)
        pure.config.set("shaders.sunrays.intensity", godray_intensity, true)

        pure.config.set("pp.godrays.length", godray_len, true)
        pure.config.set("pp.godrays.intensity", godray_intensity, true)
        _last_godray_length = godray_len
    end
    
    -- ========================================================================
    -- SCENE ANALYSIS & EXPOSURE
    -- ========================================================================
    occlusion = pure.camera.getOcclusion()
    cloud_shadow = pure.world.getCloudShadow() * occlusion
    cloud_shadow_sun = cloud_shadow * pure.mod.sun(0)
    cloud_shadow_twilight = cloud_shadow * pure.mod.twilight(0)
    badness = math.pow(pure.world.getBadness() * pure.mod.twilight(0) * occlusion, 1.5)
    fog = math.smootherstep(pure.world.getFog()) * pure.mod.twilight(0) * occlusion
    fog_gain = fog_gain or 1.053
    fog = fog * fog * fog_gain
    
    local exp = pure.exposure.getValue()
    _l_Exposure_lut = _l_ExposureCPP:get(exp)
    
    -- ========================================================================
    -- ADVANCED FOG SYSTEM 
    -- ========================================================================
    
    -- Update daycurvefog
    daycurvefog = pure.mod.dayCurve(1.0, 1.06, 0.6)
    
    -- Calculate fog thickness with day/night compensation (uses helpers defined earlier)
    
    local fog_thickness_value = pure.script.ui.getValue("Fog Thickness")
    local Fogthickness = (fog_thickness_value * 0.75 * day_compensate(0) + 
                          (fog_thickness_value * 1.14) * night_compensate(0))
    
    Fogthickness = (Fogthickness - (Fogthickness * 0.45 * night_compensate(0))) + 
                   ((0.25 * Fogthickness) * pure.world.getCloudCoverage())
    
    -- Get fog data
    local worldfogget = __PURE__world__fog_get()
    local basecolor = worldfogget.color
    local RGBcolorfog = rgb_fog
    local ambientcolor = Pure_getColor(COLORS.AMBIENT)
    
    local skycolor = ambientcolor * 0.65
    local fogtyper = -(0.5 * badness)
    local mixermult = pure.script.ui.getValue("Fog Color mixer") * pure.mod.dayCurve(4, 1, 1)
    local colorblend = pure.mod.dayCurve(
        mixermult * day_compensate(0) + (mixermult * night_compensate(0)) - 1.2,
        mixermult * day_compensate(0) + (mixermult * 2 * night_compensate(0)),
        0.67
    )
    
    fogtype = math.floor(pure.script.ui.getValue("FOG Type"))
    local fog_amount_value = pure.script.ui.getValue("Fog amount")
    if realism > 0 then
        local moisture = math.max(environment.fog, environment.rain, math.max(0, (environment.humidity - 0.65) / 0.35))
        local factor = 0.25 + 0.65 * moisture + 0.10 * environment.cloud
        fog_amount_value = fog_amount_value * (1 + realism * (factor - 1))
        Fogthickness = Fogthickness * (1 + realism * (factor - 1))
    end
    
    if fogtype == 0 then
        -- None mode: reset every property changed by the other presets so no
        -- stale fog survives after switching modes.
        fogdensity = 0
        fogsat = 1
        ac.setFogBacklitMultiplier(0)
        st6ix_weather.fog_density = 0
        st6ix_weather.fog_blend = 0
        ac.setFogDensity(0)
        ac.setFogHeight(0)
        ac.setFogColor(basecolor)
        ac.setHorizonFogMultiplier(1, 1, 1)
        ac.setFogBlend(0)
        ac.setFogExponent(1)
        ac.setFogDistance(1000000, 1000000, 0)
        
    elseif fogtype == 1 then
        -- Immersive mode
        fogdensity = pure.mod.dayCurve(1, 1, 0.07) * (500 * fog_amount_value) + (140.25 * badness)
        ac.setFogBacklitMultiplier(pure.mod.dayCurve(0.20, 0.04, 0.67))
        ac.setFogDensity(st6ix_smooth("fog_density", fogdensity, dt, 2))
        ac.setFogHeight(pure.mod.dayCurve(1120, 1913, 0.67))
        ac.setFogColor(math.lerp(skycolor, RGBcolorfog, colorblend) / daycurvefog)
        fogsat = 1
        ac.setHorizonFogMultiplier(0.705, 1, 1)
        ac.setFogBlend(st6ix_smooth("fog_blend", 25.502 * Fogthickness + worldfogget.density * 0.8, dt, 2))
        ac.setFogExponent(0.7510)
        ac.setFogHeight(pure.mod.dayCurve(1120, 1213, 0.67))
        ac.setFogDistance(
            550000 * (pure.utils.CamIsInTunnel() + 0.1),
            350000 * (pure.utils.CamIsInTunnel() + 0.1),
            pure.world.getHumidity()
        )
        
    elseif fogtype == 2 then
        -- Realistic mode
        fogdensity = 0
        ac.setFogBacklitMultiplier(pure.mod.dayCurve(0.15, 0.02, 0.67))
        ac.setFogDensity(st6ix_smooth("fog_density", fog_amount_value * 7000, dt, 2))
        ac.setFogHeight(1120)
        ac.setFogColor(math.lerp(skycolor, RGBcolorfog, colorblend) / daycurvefog)
        fogsat = pure.mod.dayCurve(0.65, 1, 0.06)
        ac.setHorizonFogMultiplier(0.705, 1, 1)
        ac.setFogBlend(st6ix_smooth("fog_blend", 14.502 * Fogthickness + worldfogget.density, dt, 2))
        ac.setFogExponent(0.7510)
        ac.setFogHeight(pure.mod.dayCurve(1120, 1213, 0.67))
        ac.setFogDistance(
            5500000 * (pure.utils.CamIsInTunnel() + 0.1),
            3500000 * (pure.utils.CamIsInTunnel() + 0.1),
            pure.world.getHumidity()
        )
    end
    
    -- Convert fog color using HSV
    RGBToHSV_To(hsv_fog, worldfogget.color)
    hsv_fog.v = hsv_fog.v * 1 * (1 + (8 * badness * 1))
    hsv_fog.s = hsv_fog.s * fogsat
    HSVToRGB_To(rgb_fog, hsv_fog.h, hsv_fog.s, hsv_fog.v)
    
    -- ========================================================================
    -- DASHCAM LENS DISTORTION 
    -- ========================================================================
    local lensDistortionEnabled = pure.script.ui.getValue("Dashcam") or false
    local lensDistortionRoundness = pure.script.ui.getValue("Lens Distortion Roundness")
    local lensDistortionSmoothness = pure.script.ui.getValue("Lens Distortion Smoothness")
    
    pure.yebis.set("lensDistortionEnabled", lensDistortionEnabled)
    
    if lensDistortionEnabled then
        pure.yebis.set("lensDistortionRoundness", lensDistortionRoundness)
        pure.yebis.set("lensDistortionSmoothness", lensDistortionSmoothness)
    end
    
    -- ========================================================================
    -- VIGNETTE
    -- ========================================================================
    local vignetteintense = profile.vignette
    if vignetteintense == nil then
        vignetteintense = pure.script.ui.getValue("Vignette Intensity")
    end
    pure.yebis.set("vignetteStrength", vignetteintense, true)
    
    -- ========================================================================
    -- FILM GRAIN 
    -- ========================================================================
    local automatic_grain = profile.grain
    if automatic_grain ~= nil and automatic_grain > 0 then
        pure.pp.set("spice.SensorNoise.active", true)
        pure.pp.set("spice.SensorNoise.strength", automatic_grain * pure.mod.dayCurve(0.85, 1.15, 0.5))
        pure.pp.set("spice.SensorNoise.scale", 0.4)
    elseif automatic_grain == nil and pure.script.ui.getValue("Enable Film Grain") then
        pure.pp.set("spice.SensorNoise.active", true)
        pure.pp.set("spice.SensorNoise.strength", (4 * pure.mod.dayCurve(0.6, 1, 0.5)) * pure.script.ui.getValue("Film Grain Strength"))
        pure.pp.set("spice.SensorNoise.scale", 0.4)
    else
        pure.pp.set("spice.SensorNoise.active", false)
        pure.pp.set("spice.SensorNoise.strength", 0)
        pure.pp.set("spice.SensorNoise.scale", 0)
    end
    
    -- ========================================================================
    -- SKYDOMES 
    -- ========================================================================
    local skydometype = pure.script.ui.getValue("Skydome Preset")
    local SkydomesRot = pure.script.ui.getValue("Skydome Rotation")
    local SkydomesHeight = pure.script.ui.getValue("Skydome Height")
    local SkydomesBright = pure.script.ui.getValue("Skydome Brightness")
    local SkydomesContrast = pure.script.ui.getValue("Skydome Contrast")
    
    cover.shadowRadius = 100000
    cover.shadowOpacityMultiplier = 0.00
    cover.texOffsetX = SkydomesRot * 1.5
    
    local brightnessp = 1
    local exponentp = 1
    
    if skydometype == 0 then
        -- OFF
        cover:setTexture()
    elseif skydometype == 1 then
        -- ST6IX Nebula
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX Nebula.dds')
        brightnessp = 10
        exponentp = 1.5
        cover.texRemapY = SkydomesHeight
    elseif skydometype == 2 then
        -- ST6IX MADARA
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX MADARA.dds')
        brightnessp = 8
        exponentp = 1.8
        cover.texRemapY = SkydomesHeight * 1.2
    elseif skydometype == 3 then
        -- ST6IX blackhole
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX blackhole.dds')
        brightnessp = 12
        exponentp = 2.0
        cover.texRemapY = SkydomesHeight * 1.0
    elseif skydometype == 4 then
        -- ST6IX black-matter
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/ST6IX black-matter.dds')
        brightnessp = 11
        exponentp = 1.9
        cover.texRemapY = SkydomesHeight * 1.1
    elseif skydometype == 5 then
        -- ST6IX Black matter Colored
        cover:setTexture('system/cfg/ppfilters/pure_scripts/textures/Black matter Colored.dds')
        brightnessp = 9
        exponentp = 1.7
        cover.texRemapY = SkydomesHeight * 0.95
    end
    
    cover.colorMultiplier = rgb(
        SkydomesBright * brightnessp,
        SkydomesBright * brightnessp,
        SkydomesBright * brightnessp
    )
    cover.colorExponent = rgb(
        SkydomesContrast * exponentp,
        SkydomesContrast * exponentp,
        SkydomesContrast * exponentp
    )
    
    -- ========================================================================
    -- HDR & CLARITY ENHANCEMENT
    -- ========================================================================
    local hdr_preset = math.floor(pure.script.ui.getValue("hdr_clarity_preset"))
    local hdr_sharpness, hdr_clarity, hdr_micro_contrast, hdr_brightness_boost, hdr_color_vibrance, hdr_highlight_recovery
    
    if HDR_CLARITY_PRESETS[hdr_preset] then
        local p = HDR_CLARITY_PRESETS[hdr_preset]
        hdr_sharpness = p.sharpness
        hdr_clarity = p.clarity
        hdr_micro_contrast = p.micro_contrast
        hdr_brightness_boost = p.hdr_brightness
        hdr_color_vibrance = p.color_vibrance
        hdr_highlight_recovery = p.highlight_recovery
    else
        -- Manual mode
        hdr_sharpness = pure.script.ui.getValue("hdr_sharpness")
        hdr_clarity = pure.script.ui.getValue("hdr_clarity")
        hdr_micro_contrast = pure.script.ui.getValue("hdr_micro_contrast")
        hdr_brightness_boost = pure.script.ui.getValue("hdr_brightness_boost")
        hdr_color_vibrance = pure.script.ui.getValue("hdr_color_vibrance")
        hdr_highlight_recovery = pure.script.ui.getValue("hdr_highlight_recovery")
    end

    hdr_sharpness = hdr_sharpness * profile.sharpness
    hdr_clarity = hdr_clarity * profile.clarity
    if lighting_sharpness_override then
        hdr_sharpness = lighting_sharpness_override * profile.sharpness
    end
    
    -- Apply sharpening via SPICE post-processing
    local sharpen_active = hdr_sharpness > 0.01
    pure.pp.set("spice.Sharpen.active", sharpen_active)
    if sharpen_active then
        -- Adaptive sharpness: reduce slightly at night to avoid noise amplification
        local night_sharpen_damp = math.lerp(1.0, 0.55, 1.0 - math.min(1, pure.mod.sun(0) * 10))
        local cockpit_sharpen_damp = interior and 0.92 or 1.0
        cockpit_sharpen_damp = cockpit_sharpen_damp * (1 - realism * (0.12 * environment.cockpit + 0.12 * environment.shadow + 0.08 * environment.rain))
        pure.pp.set("spice.Sharpen.strength", hdr_sharpness * 1.15 * night_sharpen_damp * cockpit_sharpen_damp)
    else
        pure.pp.set("spice.Sharpen.strength", 0)
    end
    
    -- Apply clarity saturation component
    if hdr_clarity > 0.01 then
        local clarity_saturation = 1.0 + (hdr_clarity * 0.08)
        pure.config.set("pp.saturation", clarity_saturation, true)
    else
        pure.config.set("pp.saturation", 1.0, true)
    end
    
    -- Color vibrance: selective saturation that boosts muted colors more than already-saturated ones
    -- Implemented through spice color grading
    if hdr_color_vibrance > 0.01 then
        local vibrance_sat = 1.0 + (hdr_color_vibrance * 0.6)
        pure.pp.set("spice.Saturation.active", true)
        pure.pp.set("spice.Saturation.strength", vibrance_sat)
    else
        pure.pp.set("spice.Saturation.active", false)
    end
    
    -- Highlight recovery intentionally does not overwrite the working bloom/glare preset.

    
    -- ========================================================================
    -- BLACK LEVELS & CONTRAST
    -- ========================================================================
    local black_multi = interior and 0.05 or 0.025
    -- In the Pure API used by the supplied working Lua, isHDR is a state value,
    -- not a callable function. Calling it stopped this update before tonemapping.
    local hdr_black_limit = pure.system.isHDR and 1.5 or 0
    local contrast_damp_day = black_multi * (pure.script.ui.getValue("black_limit_low_exposure") + hdr_black_limit)
    local contrast_damp_night = black_multi * (pure.script.ui.getValue("black_limit_high_exposure") + hdr_black_limit) * _l_Exposure_lut[5]
    local base_contrast = 1.00 - math.min(math.max(contrast_damp_day, contrast_damp_night), contrast_damp_day*_l_Exposure_lut[4] + contrast_damp_day*cloud_shadow_twilight + contrast_damp_night)
    -- Combine with HDR clarity contrast boost
    local clarity_contrast_boost = (hdr_clarity and hdr_clarity > 0.01) and (hdr_clarity * 0.35) or 0
    local micro_contrast_boost = (hdr_micro_contrast and hdr_micro_contrast > 0.01) and (hdr_micro_contrast * 0.12) or 0
    local final_contrast = lighting_contrast_override or (base_contrast + clarity_contrast_boost + micro_contrast_boost)
    pure.config.set("pp.contrast", final_contrast, true)
    
    -- ========================================================================
    -- GAMMA & TONEMAPPING
    -- ========================================================================
    -- Gamma: further lowered for brighter realistic output (was 1.35/1.28/1.22/1.15)
    gamma = math.lerp(math.lerp(math.lerp(1.18, 1.12, math.min(1, math.max(0, pure.mod.dayCurve(0.0,1.2,0.67)))), 1.08, _l_Exposure_lut[1]), 1.02, _l_Exposure_lut[2])
    -- Integrate HDR brightness boost
    local final_brightness = (hdr_brightness_boost and hdr_brightness_boost > 1.001) and hdr_brightness_boost or 1.00
    pure.config.set("pp.brightness", final_brightness, true)
    
    -- Tonemapping is applied directly after bloom above, before optional blocks.
    
    -- Spectrum adaption
    pure.light.setSpectrumAdaption(pure.script.ui.getValue("spectrum_adaption"))

    -- ========================================================================
    -- COLOR TEMPERATURE (per day/dusk/night)
    -- ========================================================================
    local _ct_aw = pure.mod.dayCurve(1, 0, 1)
    local _ct_nw = pure.mod.nightCurve(1, 0, 1)
    local _ct_tw = math.max(0, 1.0 - _ct_aw - _ct_nw)
    local _ct_blended = (pure.script.ui.getValue("color_temp_day")   * _ct_aw)
                      + (pure.script.ui.getValue("color_temp_dusk")  * _ct_tw)
                      + (pure.script.ui.getValue("color_temp_night") * _ct_nw)
    -- Normalize weights to avoid unintended temperature dips at twilight.
    local _ct_weight = _ct_aw + _ct_tw + _ct_nw
    if _ct_weight > 0 then _ct_blended = _ct_blended / _ct_weight else _ct_blended = 6500 end
    pure.yebis.set("colorTemperature", _ct_blended)
end
