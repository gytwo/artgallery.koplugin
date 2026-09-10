-- Loose proxy load test: dofile the plugin in a sandbox where every KOReader
-- runtime global returns a permissive proxy. Plugin's own class names are NOT
-- pre-stubbed, so any "method defined before class decl" still throws.
-- Usage: luajit load_test.lua <path-to-main.lua>
local path = arg[1]
if not path then print("USAGE: luajit load_test.lua <path>"); os.exit(1) end
local function make_proxy()
  local p
  p = setmetatable({}, {
    __index = function() return p end,
    __call = function() return p end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __mod = function() return 0 end, __pow = function() return 0 end,
    __unm = function() return 0 end,
    __concat = function(a, b) return tostring(a)..tostring(b) end,
    __tostring = function() return "0" end,
    __eq = function() return false end,
    __lt = function() return false end, __le = function() return false end,
    __len = function() return 0 end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
  })
  return p
end
local p = make_proxy()
_G.require = function() return p end
_G.Screen = p; _G.G_reader_settings = p; _G.UIManager = p
_G.DataStorage = p; _G.Device = p; _G.BD = p
_G.RenderImage = p; _G.Widget = p; _G.Blitbuffer = p; _G.Geom = p
_G.Font = p; _G.ffi = p
_G.G_reader_share = p; _G.Logger = p
local ok, err = pcall(function() dofile(path) end)
print(ok and "LOAD_OK" or ("LOAD_ERROR: "..tostring(err)))
