-- 反向验证：把「修复前的旧实现」喂给同一套断言，确认用例 1 会 FAIL，
-- 证明 test_onholdrelease.lua 不是恒过的无效测试。
-- 用法: luajit verify_test_catches_bug.lua
local PAN_THRESHOLD = 5
local Screen = { scaleBySize = function(_, n) return n end }
local UIManager = { setDirty = function(_, _, mode) _G.__last_dirty = mode end }
_G.Screen, _G.UIManager = Screen, UIManager

-- 旧实现（v1.0.22-rc 首版，BUG 版本）：提前清 _panning 后再委托上游
local OLD = [[
return function(self, ges)
    local ImageViewer = { onHoldRelease = function(v, _, g)
        -- 上游真实入口守卫（imageviewer.lua:637 起）
        if v._panning then
            v._panning = false
            v._pan_relative_x = g.pos.x - v._pan_relative_x
            v._pan_relative_y = g.pos.y - v._pan_relative_y
            if math.abs(v._pan_relative_x) < v.pan_threshold and math.abs(v._pan_relative_y) < v.pan_threshold then
                v.dithered = true
                UIManager:setDirty(nil, "full", nil, true)
            else
                v:panBy(-v._pan_relative_x, -v._pan_relative_y)
            end
        end
        return true
    end }
    if self._gallery_mode then return true end
    if self._panning then
        self._panning = false
        self._pan_relative_x = ges.pos.x - self._pan_relative_x
        self._pan_relative_y = ges.pos.y - self._pan_relative_y
        return ImageViewer.onHoldRelease(self, _, ges)
    end
    return true
end
]]
local old_fn = assert(loadstring or load)(OLD)()

local function make_self(o)
  o = o or {}
  local s = {
    _gallery_mode = o.gallery, _panning = o.panning,
    pan_threshold = PAN_THRESHOLD, _panned = nil,
    panBy = function(self, x, y) self._panned = { x = x, y = y } end,
  }
  if o.relx then s._pan_relative_x = o.relx end
  if o.rely then s._pan_relative_y = o.rely end
  return s
end

print("=== 用旧(BUG)实现跑同一套断言 ===")
_G.__last_dirty = nil
local s1 = make_self{ panning = true, relx = 100, rely = 100 }
old_fn(s1, { pos = { x = 140, y = 125 } })
print("  用例1 长按拖动 -> 触发平移 :",
      (s1._panned ~= nil) and "PASS" or "FAIL   <-- 复现用户报的 bug（平移丢失）")

_G.__last_dirty = nil
local s2 = make_self{ panning = true, relx = 100, rely = 100 }
old_fn(s2, { pos = { x = 102, y = 101 } })
print("  用例2 长按不动 -> 不整屏闪  :",
      (_G.__last_dirty ~= "full") and "PASS" or "FAIL   <-- 旧实现同样吞掉了闪（唯一做对的部分）")

local n_fail = (s1._panned == nil and 1 or 0) + (_G.__last_dirty == "full" and 1 or 0)
print(string.format("\n旧实现 FAIL 数 = %d", n_fail))
print(n_fail > 0 and ">>> 测试有效：能抓到旧 bug <<<" or ">>> 测试无效：恒过，需重新设计 <<<")
