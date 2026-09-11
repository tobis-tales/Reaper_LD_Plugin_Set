-- Both hosts of steelblue_copy.lua, driven the way a user drives them: three
-- markers selected in the Region/Marker Manager, the edit cursor at 34.2 s,
-- then "Copy to cursor" clicked, then the project and the footer read.
--
-- tests/copy_click_test.lua, copy_follow_test.lua and copy_lanes_test.lua
-- drive the single script and prove the copy, the follow rule and the lanes.
-- None of them knows the workspace exists. This file is the other half: the
-- same click in the tab, the fields following the cursor there, the footer,
-- no Close button anywhere, and the queue emptied after one run.
--
-- Same fake as rename_hosts_test.lua: the tab bar remembers its selection the
-- way Dear ImGui does, every frame is a second later so the 150 ms selection
-- poll fires on each of them, and JS_ReaScriptAPI reports the manager open
-- with rows 1..3 selected.

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

local CURSOR = 34.2

local PROJECT, added, ext_state, deferred, armed, footer_text, labels, fields,
  click_label, clock, selection_polls

local function drew(label)
  for _, seen in ipairs(labels) do
    if seen == label then return true end
  end
  return false
end

local function added_text()
  local parts = {}
  for _, entry in ipairs(added) do
    parts[#parts + 1] = string.format("%s@%.2f", entry.name, entry.pos)
  end
  return table.concat(parts, " ")
end

local function build_reaper(initial_ext)
  PROJECT = {}
  for index, entry in ipairs(BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do clone[key] = value end
    clone.is_region = false
    PROJECT[index] = clone
  end
  added = {}

  ext_state = {}
  for key, value in pairs(initial_ext or {}) do ext_state[key] = value end

  deferred, armed, footer_text, click_label = nil, false, nil, nil
  labels, fields = {}, {}
  clock = 0
  selection_polls = 0

  -- one tab bar's memory, exactly as much of it as SB.tab_bar can observe
  local tab_selected, tab_first = nil, nil

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn armed = true end,
    time_precise = function() clock = clock + 1 return clock end,
    GetOS = function() return "macOS-arm64" end,
    GetAppVersion = function() return "7.75/OSX64" end,
    ShowMessageBox = function(m) print("  MSGBOX: " .. tostring(m)) return 6 end,

    GetCursorPosition = function() return CURSOR end,
    -- recognizable, invertible: "M:" for measure.beats (mode 2), "T:" for
    -- hh:mm:ss:ff (mode 5), the same trick copy_follow_test.lua uses
    format_timestr_pos = function(pos, _, mode)
      if mode == 2 then return "M:" .. tostring(pos) end
      if mode == 5 then return "T:" .. tostring(pos) end
      return tostring(pos)
    end,
    parse_timestr_pos = function(input)
      local _, num = input:match("^([MT]):(.+)$")
      return tonumber(num) or 555.5
    end,

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
    AddProjectMarker2 = function(_, _, pos, _, name, _, color)
      added[#added + 1] = { pos = pos, name = name, color = color }
      PROJECT[#PROJECT + 1] = { pos = pos, name = name, id = #PROJECT + 1, color = color, is_region = false }
      return #PROJECT
    end,
    SetProjectMarker4 = function() return true end,

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
    -- one call per MARKERS.selected(): this is the poll counter of check (b5)
    JS_ListView_ListAllSelItems = function() selection_polls = selection_polls + 1 return 3, "1,2,3" end,
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

      return function(a1, a2, a3, a4)
        if key == "ImGui_CreateContext" then return "ctx" end
        if key == "ImGui_CreateFont" then return "font" end
        if key == "ImGui_GetWindowDrawList" then return "dl" end
        if key == "ImGui_Begin" then return true, true end
        if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
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

        if key == "ImGui_BeginTabBar" then tab_first = nil return true end
        if key == "ImGui_BeginTabItem" then
          if a4 == 1 then tab_selected = a2 end
          if tab_first == nil then tab_first = a2 end
          return tab_selected == a2 or (tab_selected == nil and tab_first == a2)
        end

        -- every field hands its own value straight back, and the value it was
        -- shown with is remembered by label
        if key == "ImGui_Checkbox" then return false, a3 end
        if key == "ImGui_InputText" then fields[a2] = a3 return false, a3 end
        if key == "ImGui_InputInt" then return false, a3 end
        if key == "ImGui_Combo" then return false, a3 end
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
  print(string.format("  %s  %-58s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- One rendered frame. Returns whether the script asked for another one.
local function frame()
  labels, fields = {}, {}
  armed = false
  selection_polls = 0
  local ok, err = pcall(deferred)
  if not ok then error(err) end
  return armed
end

local function drew_all_three()
  return drew("Copy to cursor") and drew("Copy to measure.beats") and drew("Copy to hh:mm:ss:ff")
end

local WANT = "verse@34.20 buildup@37.95 drop@41.70"

print("\nsteelblue_copy.lua in both hosts -- click the button, read the project:\n")

-- ------------------------------------------------------------- single script

do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then
    check(false, "a) the single script loads", tostring(err))
  else
    frame()
    check(drew_all_three() and footer_text == "Ready.",
      "a1) its own window draws the three buttons and a Ready footer",
      "footer " .. tostring(footer_text))
    check(not drew("Close") and not drew("Cancel"),
      "a2) and no Close button -- the window has never had one", #labels .. " buttons drawn")
    check(fields["measure.beats"] == "M:34.2" and fields["hh:mm:ss:ff"] == "T:34.2",
      "a3) both fields follow the cursor",
      tostring(fields["measure.beats"]) .. " / " .. tostring(fields["hh:mm:ss:ff"]))

    click_label = "Copy to cursor"
    frame()
    click_label = nil
    local again = frame()

    check(added_text() == WANT, "a4) clicking Copy to cursor copies the selection", added_text())
    check(footer_text == "3 markers copied.", "a5) and says so in the footer", "footer " .. tostring(footer_text))
    check(again, "a6) the window stays open", "")

    frame()
    check(#added == 3, "a7) two more frames do not copy again", #added .. " copies")
  end
end

-- ------------------------------------------------------------- workspace tab

do
  reaper = capture_footer(build_reaper({ active_tab = "copy" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "b) the workspace loads", tostring(err))
  else
    frame()
    check(drew_all_three(), "b1) the copy tab draws the same three buttons", #labels .. " buttons drawn")
    check(footer_text == "Ready.", "b2) and a Ready footer", "footer " .. tostring(footer_text))
    check(not drew("Close") and not drew("Cancel"), "b3) and no Close button", "")
    check(fields["measure.beats"] == "M:34.2" and fields["hh:mm:ss:ff"] == "T:34.2",
      "b4) both fields follow the cursor in the tab too",
      tostring(fields["measure.beats"]) .. " / " .. tostring(fields["hh:mm:ss:ff"]))
    check(selection_polls == 1,
      "b5) the selection is polled once per frame, by the workspace only",
      selection_polls .. " polls")

    click_label = "Copy to cursor"
    frame()
    click_label = nil
    frame()

    check(added_text() == WANT, "b6) the same click copies the same markers", added_text())
    check(footer_text == "3 markers copied.",
      "b7) and the workspace footer says so", "footer " .. tostring(footer_text))

    frame()
    check(#added == 3, "b8) two more frames do not copy again", #added .. " copies")
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

    check(not drew("Copy to cursor") and not drew("Copy to measure.beats") and not drew("Copy to hh:mm:ss:ff"),
      "c1) another tab does not draw the copy buttons", #labels .. " buttons drawn")
    check(drew("All MIDI items in the project"), "c2) it draws the MIDI panel instead", "")

    click_label = "Copy to cursor"
    frame()
    click_label = nil
    frame()
    check(#added == 0, "c3) a click on the absent button copies nothing", #added .. " copies")
  end
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
