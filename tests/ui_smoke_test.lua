-- Smoke-test the theme module against a fake `reaper` built from the REAL
-- ImGui_* function list of the installed dylib. Catches two classes of bug that
-- otherwise only surface in REAPER:
--   1. mistyped API names (crash on first use)
--   2. unbalanced style stack (grows every frame until ImGui asserts)

local dylib = "/Users/tobiaspehla/Library/Application Support/REAPER/UserPlugins/reaper_imgui-arm64.dylib"

local real = {}
local count_real = 0
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do
  real[line:gsub("^-API_", "")] = true
  count_real = count_real + 1
end
p:close()
print(string.format("ReaImGui exposes %d ImGui_* functions", count_real))

local missing = {}
local stack = { colors = 0, vars = 0, fonts = 0, windows = 0 }

reaper = setmetatable({}, {
  __index = function(_, key)
    if not key:match("^ImGui_") then
      return nil
    end
    if not real[key] then
      missing[key] = true
      return nil
    end

    return function(ctx, a, b, c)
      if key == "ImGui_PushStyleColor" then stack.colors = stack.colors + 1 end
      if key == "ImGui_PopStyleColor" then stack.colors = stack.colors - (a or 1) end
      if key == "ImGui_PushStyleVar" then stack.vars = stack.vars + 1 end
      if key == "ImGui_PopStyleVar" then stack.vars = stack.vars - (a or 1) end
      if key == "ImGui_PushFont" then stack.fonts = stack.fonts + 1 end
      if key == "ImGui_PopFont" then stack.fonts = stack.fonts - 1 end
      -- ReaImGui rule: End is called if and only if Begin returned true. A
      -- collapsed window submits nothing and needs no End, so only count the
      -- windows that actually opened.
      if key == "ImGui_Begin" and WINDOW_VISIBLE then stack.windows = stack.windows + 1 end
      if key == "ImGui_End" then stack.windows = stack.windows - 1 end

      if key == "ImGui_CreateFont" then return "font" end
      if key == "ImGui_CreateContext" then return "ctx" end
      if key == "ImGui_GetWindowDrawList" then return "dl" end
      if key == "ImGui_Begin" then return WINDOW_VISIBLE, true end
      if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
      if key == "ImGui_GetContentRegionAvail" then return 400, 300 end
      if key == "ImGui_CalcTextSize" then return 50, 12 end
      if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_") or key:match("^ImGui_Cond_") or key:match("Flags") then
        return 1
      end
      if key == "ImGui_Button" then return false end
      return nil
    end
  end,
})

local folder = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/"
local SB = dofile(folder .. "steelblue_ui.lua")
print("module loaded, version " .. SB.VERSION)
print(string.format("brand blue #%06X, brand grey #%06X", SB.BRAND_BLUE, SB.BRAND_GREY))

local ctx = "ctx"

local function draw_frame()
  local visible, open, font = SB.begin_window(ctx, "Live BPM Analyzer", 420, 400)
  if visible then
    SB.section(ctx, "Tempo")
    SB.display_value(ctx, "130.99", "BPM")
    SB.meter(ctx, 0.8, 200)
    SB.label(ctx, "Raw: 130.99")
    SB.separator(ctx)
    SB.primary_button(ctx, "Precision analyze", 140, 26)
    SB.button(ctx, "Half", 55, 26)
    SB.footer(ctx, "Precision result from 120 s of audio.", "success")
  end
  SB.end_window(ctx, visible, font)
end

-- 60 frames visible, 60 collapsed, 60 visible again: the collapsed stretch is
-- where an End-in-the-wrong-branch or a missed pop_theme would show up
WINDOW_VISIBLE = true
for _ = 1, 60 do draw_frame() end
print(string.format("\nafter 60 visible frames:   colors=%d vars=%d fonts=%d windows=%d",
  stack.colors, stack.vars, stack.fonts, stack.windows))

WINDOW_VISIBLE = false
for _ = 1, 60 do draw_frame() end
print(string.format("after 60 collapsed frames: colors=%d vars=%d fonts=%d windows=%d",
  stack.colors, stack.vars, stack.fonts, stack.windows))

WINDOW_VISIBLE = true
for _ = 1, 60 do draw_frame() end
print(string.format("after 60 visible again:    colors=%d vars=%d fonts=%d windows=%d",
  stack.colors, stack.vars, stack.fonts, stack.windows))

local fails = 0

local miss_list = {}
for k in pairs(missing) do miss_list[#miss_list + 1] = k end
table.sort(miss_list)
if #miss_list > 0 then
  print("\nMISSING / TYPO'd API NAMES (would crash in REAPER):")
  for _, k in ipairs(miss_list) do print("   " .. k) end
  fails = fails + 1
end

for name, value in pairs(stack) do
  if value ~= 0 then
    print(string.format("\nSTACK LEAK: %s is %+d after 180 frames", name, value))
    fails = fails + 1
  end
end

print(fails == 0 and "\nALL PASS -- no typos, stacks balanced" or "\nFAILED")
os.exit(fails == 0 and 0 or 1)
