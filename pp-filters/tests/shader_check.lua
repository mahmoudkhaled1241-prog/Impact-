-- Usage: luajit tests/shader_check.lua <script.lua>
-- Compiles every custom tone-mapping shader the script can hand to Pure, using
-- glslangValidator's HLSL front end. Each `values` entry becomes a float uniform,
-- which is how Pure exposes them to the shader.

package.path = arg[0]:gsub('[^/\\]+$', '') .. '?.lua;' .. package.path
local H = require('harness')
local script = assert(arg[1], 'script path required')
local tmp = os.getenv('TMPDIR') or '/tmp'

local probe = H.run(script, {}, function() end, 1, 0.1)
local curve = probe.controls['Tone Curve']
local failures, compiled = 0, 0

for option = 1, curve.count do
    local S = H.run(script, { ['Tone Curve'] = option }, function() end, 3, 0.1)
    local t = S.tonemapTable
    if t and S.last['pp.setCustomRGBTonemapping'] then
        local names = {}
        for k, v in pairs(t.values) do
            assert(type(v) == 'number', 'non-numeric shader value ' .. k)
            names[#names + 1] = '    float ' .. k .. ';'
        end
        table.sort(names)
        local src = 'cbuffer ST6IXValues : register(b0) {\n' .. table.concat(names, '\n') .. '\n};\n'
            .. t.shader
            .. '\nfloat4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD0) : SV_TARGET {\n'
            .. '    return float4(tonemapping(float3(uv * 8.0, uv.x * uv.y * 8.0)), 1.0);\n}\n'
        local path = string.format('%s/st6ix_tonemap_%d.hlsl', tmp, option)
        local f = assert(io.open(path, 'w'))
        f:write(src)
        f:close()
        local cmd = string.format('glslangValidator -D -S frag -e main -V -o /dev/null %s 2>&1', path)
        local pipe = io.popen(cmd)
        local out = pipe:read('*a')
        local ok = pipe:close()
        local passed = (ok == true or ok == 0) and not out:find('ERROR')
        compiled = compiled + 1
        print(string.format('%s Tone Curve %d shader (%d uniforms)', passed and 'PASS' or 'FAIL', option, #names))
        if not passed then print(out); failures = failures + 1 end
    end
end

print(string.format('%d custom shaders compiled, %d failed', compiled, failures))
os.exit(failures == 0 and compiled > 0 and 0 or 1)
