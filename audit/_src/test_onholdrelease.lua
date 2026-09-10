-- 桩测试：验证 ArtGalleryViewer:onHoldRelease 的手势分流
-- 从真实 main.lua 抽出该函数体，在桩环境里执行，喂入模拟手势，断言行为。
-- 覆盖用例：
--   1. 长按并拖动（位移 > 阈值）→ 必须 panBy（v1.0.22-rc 首版回归：此处曾失效）
--   2. 长按不移动（位移 < 阈值）→ 不得 panBy、不得 setDirty "full"
--   3. 图库态 → 直接吞掉（既不平移动也不刷新）
--   4. _pan_relative_* 缺失（防御路径）→ 不崩、且按零位移处理
--   5. 未处于 _panning（fit 态长按弹菜单路径）→ 不崩、什么都不做
-- 用法: luajit test_onholdrelease.lua <path-to-main.lua>
local path = arg[1]
local src = assert(io.open(path, "rb")):read("*a")

-- 抽出 ArtGalleryViewer:onHoldRelease 的完整函数体
local fname = "ArtGalleryViewer:onHoldRelease"
local s = src:find("function " .. fname, 1, true)
assert(s, "onHoldRelease not found in " .. path)
-- 从函数起点开始做括号配平，找到匹配的 end
local i = src:find("\n", s, true)
local depth, j = 0, i
while true do
  local a, b, c, d = src:find("\f()", j) -- placeholder, replaced below
  break
end
-- 简化：逐行扫描，按 Lua 关键字配平（本函数无嵌套 function/closure）
local lines, out, in_fn = {}, {}, false
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
  if not in_fn and line:find("function " .. fname, 1, true) then
    in_fn = true
    out[#out + 1] = "return function(self, ges)"   -- 改写成匿名函数
  elseif in_fn then
    if line:match("^end%s*$") then
      out[#out + 1] = "end"
      break
    end
    out[#out + 1] = line
  end
end
assert(#out > 3, "failed to extract function body")
local chunk = table.concat(out, "\n")
local fn = assert(loadstring or load)(chunk)()
print("extracted onHoldRelease: OK (" .. #out .. " lines)")

-- ── 桩：模拟 Screen.scaleBySize / math ──────────────────────────────────────
local PAN_THRESHOLD = 5
local Screen = { scaleBySize = function(_, n) return n end }
local UIManager = { setDirty = function(_, _, mode) _G.__last_dirty = mode end }
-- 让被抽出的函数体能看到这两个全局
_G.Screen = Screen
_G.UIManager = UIManager

-- ── 用例执行器 ─────────────────────────────────────────────────────────────
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1; print("  PASS  " .. name)
  else fail = fail + 1; print("  FAIL  " .. name .. (detail and ("  -> " .. detail) or "")) end
end

local function make_self(opts)
  opts = opts or {}
  local s = {
    _gallery_mode = opts.gallery,
    _panning = opts.panning,
    pan_threshold = PAN_THRESHOLD,
    _panned = nil,
    panBy = function(self, x, y) self._panned = { x = x, y = y } end,
  }
  if opts.relx ~= nil then s._pan_relative_x = opts.relx end
  if opts.rely ~= nil then s._pan_relative_y = opts.rely end
  return s
end

print("\n=== 用例 ===")

-- 1. 长按并拖动（位移 40,25 > 阈值 5）
do
  _G.__last_dirty = nil
  local s = make_self{ panning = true, relx = 100, rely = 100 }
  fn(s, { pos = { x = 140, y = 125 } })
  check("1 长按拖动 → 触发平移", s._panned ~= nil,
        s._panned and string.format("panned=(%s,%s)", s._panned.x, s._panned.y) or "未调用 panBy")
  if s._panned then
    -- panBy 传的是相对位移的负值（与上游 onPanRelease 一致）
    check("1b 平移量 = -Δ (反向)", s._panned.x == -40 and s._panned.y == -25,
          string.format("got (%s,%s) expect (-40,-25)", s._panned.x, s._panned.y))
  end
  check("1c 拖动后 _panning 已清零", s._panning == false)
  check("1d 拖动不触发整屏刷新", _G.__last_dirty == nil, "dirty=" .. tostring(_G.__last_dirty))
end

-- 2. 长按不移动（位移 2,1 < 阈值 5）
do
  _G.__last_dirty = nil
  local s = make_self{ panning = true, relx = 100, rely = 100 }
  fn(s, { pos = { x = 102, y = 101 } })
  check("2 长按不动 → 不平移", s._panned == nil, "意外调用了 panBy")
  check("2b 长按不动 → 不整屏闪", _G.__last_dirty ~= "full", "dirty=" .. tostring(_G.__last_dirty))
  check("2c 长按不动 → _panning 已清零", s._panning == false)
end

-- 3. 图库态
do
  _G.__last_dirty = nil
  local s = make_self{ gallery = true, panning = true, relx = 100, rely = 100 }
  fn(s, { pos = { x = 140, y = 125 } })
  check("3 图库态 → 直接吞掉，不平移", s._panned == nil)
  check("3b 图库态 → 不整屏闪", _G.__last_dirty ~= "full")
end

-- 4. 防御：_pan_relative_* 缺失
do
  _G.__last_dirty = nil
  local ok = pcall(fn, make_self{ panning = true }, { pos = { x = 140, y = 125 } })
  check("4 _pan_relative 缺失 → 不崩溃", ok)
end

-- 5. 未处于 _panning（fit 态长按弹菜单后）
do
  _G.__last_dirty = nil
  local s = make_self{ panning = false, relx = 100, rely = 100 }
  local ok = pcall(fn, s, { pos = { x = 140, y = 125 } })
  check("5 非 _panning → 不崩溃且无副作用", ok and s._panned == nil and _G.__last_dirty == nil)
end

-- 6. 边界：位移恰好等于阈值
do
  local s = make_self{ panning = true, relx = 100, rely = 100 }
  fn(s, { pos = { x = 105, y = 100 } })
  check("6 位移 == 阈值 → 平移（>= 语义，与上游原判据互补）", s._panned ~= nil)
end

print(string.format("\n结果: PASS=%d  FAIL=%d", pass, fail))
if fail == 0 then print(">>> 桩测试通过 <<<") else print(">>> 存在 FAIL <<<") end
