-- Standalone static class-order & local-underscore checker (no external deps)
-- Usage: luajit check_class_order.lua <path-to-main.lua>
local path = arg[1]
if not path then print("USAGE: luajit check_class_order.lua <path>"); os.exit(1) end
local lines = {}
for l in io.lines(path) do lines[#lines + 1] = l end

local decl_line, method_line = {}, {}
for i, l in ipairs(lines) do
  local cls = l:match("^%s*local%s+(%w+)%s*=%s*[%w.:]*:extend%s*%{")
          or l:match("^%s*(%w+)%s*=%s*[%w.:]*:extend%s*%{")
  if cls and not decl_line[cls] then decl_line[cls] = i end
  local mcls = l:match("^%s*function%s+(%w+)%s*:")
  if mcls then method_line[mcls] = method_line[mcls] or {}; method_line[mcls][#method_line[mcls]+1] = i end
end
local problems = 0
for cls, lst in pairs(method_line) do
  local dl = decl_line[cls]
  if dl then for _, ml in ipairs(lst) do
    if ml < dl then
      problems = problems + 1
      print(("PROBLEM: %s:method @%d BEFORE class decl @%d"):format(cls, ml, dl))
    end
  end end
end
if problems == 0 then print("OK class-order") else print(("FOUND %d class-order"):format(problems)) end

-- local _ underscore shadow
local l_underscore = 0
for i, l in ipairs(lines) do
  if l:match("^%s*local%s+_[%s,=)]") and not l:match("require") then
    l_underscore = l_underscore + 1
    print(("CHECK: local _ shadow @%d : %s"):format(i, (l:match("^%s*(.+)$")) or ""))
  end
end
if l_underscore == 0 then print("OK local-underscore") else print(("FOUND %d local-underscore"):format(l_underscore)) end
