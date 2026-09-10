-- Both hosts of steelblue_rename.lua, driven the way a user drives them: three
-- markers selected in the Region/Marker Manager, then the Rename button
-- clicked, then the footer read.
--
-- tests/rename_test.lua proves the naming logic. It does NOT press the button:
-- it reaches through the RENAME_TEST hook straight into run_rename, so a panel
-- that never draws its button, never queues the work, or never lets it out
-- again after the frame would leave that suite perfectly green. This file is
-- the other half -- it only ever touches labels and the status line, the two
-- things a user actually sees.
--
-- The fake tab bar remembers its selection the way Dear ImGui does: an item
-- asked for with TabItemFlags_SetSelected becomes the selected one and stays
-- selected afterwards. Handing "true" to every tab instead would draw all
-- three tabs' contents at once and hide the very bug case (c) is about.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

-- five markers; the manager has rows 1..3 selected, which are M2, M3 and M4
local BASE_PROJECT = {
  { pos =  0.0, name = "intro",   id = 1, color = 0 },
  { pos =  3.75, name = "verse",   id = 2, color = 0 },
  { pos =  7.5, name = "buildup", id = 3, color = 0 },
  { pos = 11.25, name = "drop",    id = 4, color = 0 },
  { pos = 13.1, name = "break",   id = 5, color = 0 },
}

local PROJECT, ext_state, deferred, footer_text, labels, texts, click_label, clock

local function marker(id)
  for _, entry in ipairs(PROJECT) do
    if entry.id == id then return entry end
  end
  return nil
end

local function drew(label)
  for _, seen in ipairs(labels) do
    if seen == label then return true end
  end
  return false
end

local function build_reaper(initial_ext)
  PROJECT = {}
  for index, entry in ipairs(BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do clone[key] = value end
    clone.is_region = false
    PROJECT[index] = clone
  end

  ext_state = {}
  for key, value in pairs(initial_ext or {}) do ext_state[key] = value end

  deferred, footer_text, click_label = nil, nil, nil
  labels, texts = {}, {}
  clock = 0

  -- one tab bar's memory, exactly as much of it as SB.tab_bar can observe
  local tab_selected, tab_first = nil, nil

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn end,
    -- every frame is a second later, so the 150 ms selection poll fires on
    -- each of them and a change of selection could never be missed here
    time_precise = function() clock = clock + 1 return clock end,
    GetOS = function() return "macOS-arm64" end,
    GetAppVersion = function() return "7.75/OSX64" end,
    ShowMessageBox = function(m) print("  MSGBOX: " .. tostring(m)) return 6 end,

    GetExtState = function(_, key) return ext_state[key] or "" end,
    SetExtState = function(_, key, value) ext_state[key] = value end,
    DeleteExtState = function(_, key) ext_state[key] = nil end,
    HasExtState = function(_, key) return ext_state[key] ~= nil end,

    ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end,
    ColorFromNative = function(v) return v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF end,

    Undo_BeginBlock = function() end,
    Undo_EndBlock = function() end,
    PreventUIRefresh = function() end,
    UpdateTimeline = function() end,
    UpdateArrange = function() end,

    EnumProjectMarkers3 = function(_, index)
      local e = PROJECT[index + 1]
      if not e then return 0 end
      return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
    end,
    SetProjectMarker4 = function(_, id, _, _, _, name, color)
      local e = marker(id)
      if e then e.name = name e.color = color end
      return true
    end,

    -- JS_ReaScriptAPI with the manager open and three rows selected
    new_array = function() return { table = function() return { 1234 } end } end,
    JS_Localize = function(s) return s end,
    JS_Window_ArrayFind = function() return 1 end,
    JS_Window_HandleFromAddress = function() return "hwnd" end,
    JS_Window_FindChildByID = function(_, id)
      if id == 1056 then return "container" end
      if id == 1071 then return "listview" end
      return nil
    end,
    JS_ListView_ListAllSelItems = function() return 3, "1,2,3" end,
    JS_ListView_GetItemText = function(_, row)
      local rows = { [0] = "M1", [1] = "M2", [2] = "M3", [3] = "M4", [4] = "M5" }
      return rows[row]
    end,
  }

  return setmetatable({}, {
    __index = function(_, key)
      if specific[key] then return specific[key] end
      if not key:match("^ImGui_") then return function() return 0 end end
      if not real_imgui[key] then return nil end

      -- (ctx, label, value, flags) for every widget below, so a2 is the label
      -- and a3 the value the caller passed in
      return function(a1, a2, a3, a4)
        if key == "ImGui_CreateContext" then return "ctx" end
        if key == "ImGui_CreateFont" then return "font" end
        if key == "ImGui_GetWindowDrawList" then return "dl" end
        if key == "ImGui_Begin" then return true, true end
        if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
        -- a docked strip: wide enough for two legend columns, tall enough for
        -- the legend to be asked for at all
        if key == "ImGui_GetContentRegionAvail" then return 1400, 300 end
        if key == "ImGui_GetWindowSize" then return 1512, 500 end
        if key == "ImGui_GetCursorPos" then return 12, 12 end
        if key == "ImGui_GetCursorPosX" then return 12 end
        if key == "ImGui_GetFrameHeight" then return 23 end
        if key == "ImGui_CalcTextSize" then return 50, 12 end
        if key == "ImGui_GetItemRectMin" then return 100, 100 end
        if key == "ImGui_GetItemRectMax" then return 220, 124 end

        if key == "ImGui_Button" then
          labels[#labels + 1] = a2
          return a2 == click_label
        end
        -- TextColored is (ctx, colour, text): the text is the third argument
        if key == "ImGui_TextColored" then texts[#texts + 1] = a3 end
        if key == "ImGui_Text" or key == "ImGui_TextWrapped" then texts[#texts + 1] = a2 end

        if key == "ImGui_BeginTabBar" then tab_first = nil return true end
        if key == "ImGui_BeginTabItem" then
          -- a4 is the flags argument; the fake's enum getters all answer 1, so
          -- "1" here means TabItemFlags_SetSelected
          if a4 == 1 then tab_selected = a2 end
          if tab_first == nil then tab_first = a2 end
          return tab_selected == a2 or (tab_selected == nil and tab_first == a2)
        end

        -- Hand every field its own value straight back: a fake that answers
        -- with the LABEL would type "Cue name" into the cue name box on frame
        -- one and every assertion after that would be about the fake.
        if key == "ImGui_Checkbox" then return false, a3 end
        if key == "ImGui_InputText" then return false, a3 end
        if key == "ImGui_InputInt" then return false, a3 end
        if key == "ImGui_RadioButton" then return false end
        if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
          or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
        return nil
      end
    end,
  })
end

-- The footer is the last thing drawn at SB.size.small, so the last value wins.
local function capture_footer(fake)
  local inner = getmetatable(fake).__index
  setmetatable(fake, { __index = function(t, key)
    if key == "ImGui_DrawList_AddTextEx" then
      return function(_dl, _font, size, _x, _y, _col, text)
        if size == 11 then footer_text = text end
        return nil
      end
    end
    return inner(t, key)
  end })
  return fake
end

local fails = 0
local function check(ok, name, detail)
  if not ok then fails = fails + 1 end
  print(string.format("  %s  %-56s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

local function frame()
  labels, texts = {}, {}
  local ok, err = pcall(deferred)
  if not ok then error(err) end
end

print("\nsteelblue_rename.lua in both hosts -- click the button, read the footer:\n")

-- ------------------------------------------------------------- single script

do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "Rename selected markers.lua")
  if not ok then
    check(false, "a) the single script loads", tostring(err))
  else
    frame()
    check(footer_text == "Ready." and drew("Rename selected markers"),
      "a1) its own window draws the panel and a Ready footer",
      "footer " .. tostring(footer_text))

    click_label = "Rename selected markers"
    frame()
    click_label = nil
    frame()

    local renamed = marker(2).name
    check(footer_text == "3 markers renamed.",
      "a2) clicking Rename renames the selection",
      "footer " .. tostring(footer_text))
    check(renamed == "verse(1)[Top]^verse^"
      and marker(3).name == renamed and marker(4).name == renamed,
      "a3) all three markers carry the template's name", renamed)
    check(marker(1).name == "intro" and marker(5).name == "break",
      "a4) the markers that were not selected are untouched",
      marker(1).name .. " / " .. marker(5).name)
  end
end

-- ------------------------------------------------------------- workspace tab

do
  reaper = capture_footer(build_reaper({ active_tab = "rename" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "b) the workspace loads", tostring(err))
  else
    frame()
    check(drew("Rename selected markers"),
      "b1) the rename tab draws the same panel",
      "footer " .. tostring(footer_text))

    click_label = "Rename selected markers"
    frame()
    click_label = nil
    frame()

    check(footer_text == "3 markers renamed.",
      "b2) the same click writes into the workspace footer",
      "footer " .. tostring(footer_text))
    check(marker(2).name == "verse(1)[Top]^verse^",
      "b3) and renames the same three markers", marker(2).name)
  end
end

-- ------------------------------------------------------------ a different tab

do
  reaper = capture_footer(build_reaper({ active_tab = "midi" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "c) the workspace loads on the midi tab", tostring(err))
  else
    frame()
    frame()

    local placeholder = false
    for _, text in ipairs(texts) do
      if type(text) == "string" and text:find("moves in here", 1, true) then
        placeholder = true
      end
    end

    check(not drew("Rename selected markers") and not drew("Reset to defaults"),
      "c1) another tab does not draw the rename panel",
      #labels .. " buttons drawn")
    check(placeholder, "c2) it draws its own placeholder instead")
    check(marker(2).name == "verse", "c3) nothing was renamed", marker(2).name)
  end
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
