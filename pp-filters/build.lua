-- Usage: luajit build.lua <output_dir>
-- Generates the four ST6IX release variants (Gamma / LCS x SDR / HDR) from
-- ST6IX_PP.lua, each paired with its PP filter .ini, into an install-ready tree.

local here = arg[0]:gsub('[^/\\]+$', '')
local out = assert(arg[1], 'output directory required')
local RELEASE = 'ST6IX_PP_V1.1'

local VARIANTS = {
    { file = 'ST6IX_PP_V1.1',         name = 'ST6IX V1.1',         hdr = false, lcs = false },
    { file = 'ST6IX_PP_V1.1_HDR',     name = 'ST6IX V1.1 HDR',     hdr = true,  lcs = false },
    { file = 'ST6IX_PP_V1.1_LCS',     name = 'ST6IX V1.1 LCS',     hdr = false, lcs = true },
    { file = 'ST6IX_PP_V1.1_LCS_HDR', name = 'ST6IX V1.1 LCS HDR', hdr = true,  lcs = true },
}

local function readAll(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function writeAll(path, s)
    local f = assert(io.open(path, 'wb'))
    f:write(s)
    f:close()
end

local function mkdir(path)
    assert(os.execute(string.format('mkdir -p "%s"', path)))
end

local master = readAll(here .. 'ST6IX_PP.lua')
local buildLine = "local BUILD = { name = 'ST6IX V1.1', hdr = false, lcs = false }"
local s, e = master:find(buildLine, 1, true)
assert(s and not master:find(buildLine, e + 1, true), 'BUILD line must appear exactly once in ST6IX_PP.lua')
local template = readAll(here .. 'ini/ST6IX.ini.template')

local root = out .. '/' .. RELEASE
local ppfilters = root .. '/assettocorsa/system/cfg/ppfilters'
mkdir(ppfilters .. '/pure_scripts')
mkdir(ppfilters .. '/purelcs_scripts')

for _, v in ipairs(VARIANTS) do
    local line = string.format("local BUILD = { name = '%s', hdr = %s, lcs = %s }",
        v.name, tostring(v.hdr), tostring(v.lcs))
    local script = master:sub(1, s - 1) .. line .. master:sub(e + 1)
    local scriptDir = v.lcs and 'purelcs_scripts' or 'pure_scripts'
    writeAll(string.format('%s/%s/%s.lua', ppfilters, scriptDir, v.file), script)

    local ini = template
        :gsub('{{NAME}}', v.name)
        :gsub('{{PURE}}', v.lcs and 'Pure LCS' or 'Pure Gamma')
        :gsub('{{DISPLAY}}', v.hdr and 'HDR displays' or 'SDR displays')
        :gsub('{{SCRIPT}}', scriptDir .. '/' .. v.file .. '.lua')
    writeAll(string.format('%s/%s.ini', ppfilters, v.file), ini)
    print(string.format('built %-24s -> %s/%s.lua', v.file .. '.ini', scriptDir, v.file))
end

writeAll(root .. '/README.txt', readAll(here .. 'README.txt'))
print('release tree: ' .. root)
