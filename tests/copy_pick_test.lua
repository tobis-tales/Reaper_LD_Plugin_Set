-- The tick list in Copy Markers: which markers get copied, and how the ticks
-- survive the Region/Marker Manager throwing its selection away.
--
-- Tobi's problem (2026-09-15): clicking any other marker in the manager clears
-- the selection, so "pick three, look at something else, then copy" was
-- impossible. The panel now keeps its own ticks. Two modes:
--
--   follow  the start state -- the ticks mirror the manager selection
--   manual  from the first click on a tick box -- the ticks stay put
--
-- tests/copy_click_test.lua, copy_follow_test.lua, copy_lanes_test.lua and
-- copy_hosts_test.lua all drive the SELECTION path and must keep passing
-- unchanged: in follow mode the ticked set is the selection, so nothing they
-- can see has changed. This file is the other half.
--
-- The fake runs REAPER 7.78 with ruler lanes, so every marker has a GUID --
-- which is what a tick is keyed on, and why renaming a marker cannot lose it.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

local CURSOR = 34.2

-- Five markers over three ruler lanes. The lane of each copy is checked by
-- copy_lanes_test.lua; here the lanes only have to make the list draw its
-- third column.
local BASE_PROJECT = {
  { pos =  0.0,  name = "intro",   id = 1, color = 0, lane = 0, guid = "{G1}" },
  { pos =  3.75, name = "verse",   id = 2, color = 0, lane = 1, guid = "{G2}" },
  { pos =  7.5,  name = "buildup", id = 3, color = 0, lane = 1, guid = "{G3}" },
  { pos = 11.25, name = "drop",    id = 4, color = 0, lane = 2, guid = "{G4}" },
  { pos = 13.1,  name = "break",   id = 5, color = 0, lane = 0, guid = "{G5}" },
}

local LANE_NAMES = { [0] = "Cues", [1] = "FX", [2] = "Music" }

-- ------------------------------------------------------------------- fake

-- Returns the fake reaper table and a handle to drive it with.
local function build_reaper(opts)
  opts = opts or {}

  local PROJECT = {}
  for index, entry in ipairs(opts.project or BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do clone[key] = value end
    PROJECT[index] = clone
  end

  local added, boxes = {}, {}
  local deferred, footer_text = nil, nil
  local buttons, checkboxes, texts = {}, {}, {}
  local children, child_depth, max_child_depth = 0, 0, 0
  -- what BeginChild was asked for, and where SetCursorPosX put the cursor:
  -- the two numbers that say whether the list is 520 wide and sits right
  local child_sizes, cursor_x_sets = {}, {}
  local click_label, check_label = nil, nil
  local selected_rows = opts.selected_rows or {}
  local ext_state = {}
  for key, value in pairs(opts.ext or {}) do ext_state[key] = value end
  local clock = 0
  local next_id = #PROJECT

  local function marker_by_guid(guid)
    for _, entry in ipairs(PROJECT) do
      if entry.guid == guid then return entry end
    end
    return nil
  end

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn end,
    time_precise = function() clock = clock + 1 return clock end,
    GetOS = function() return "macOS-arm64" end,
    GetAppVersion = function() return "7.78/OSX64" end,
    ShowMessageBox = function(m) boxes[#boxes + 1] = m return 6 end,

    GetCursorPosition = function() return CURSOR end,
    -- recognizable and invertible, the trick copy_follow_test.lua uses
    format_timestr_pos = function(pos, _, mode)
      if mode == 2 then return "M:" .. tostring(pos) end
      if mode == 5 then return "T:" .. tostring(pos) end
      return tostring(pos)
    end,
    parse_timestr_pos = function(input)
      local _, num = tostring(input):match("^([MT]):(.+)$")
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
      return 1, false, e.pos, e.pos, e.name, e.id, e.color
    end,

    -- ruler lanes: numeric descriptors on GetSetProjectInfo, NAME/GUID on the
    -- string one -- the split that made the first probe run read "no lanes"
    GetSetProjectInfo = function(_, desc)
      if desc == "RULER_LANE_COUNT" then return 3.0 end
      return 0
    end,
    GetSetProjectInfo_String = function(_, desc)
      local param, index = desc:match("^RULER_LANE_(%u+):(%-?%d+)$")
      if param == "NAME" then return true, LANE_NAMES[tonumber(index)] or "" end
      if param == "GUID" then return true, "{LANE" .. index .. "}" end
      return false, ""
    end,

    GetNumRegionsOrMarkers = function() return #PROJECT end,
    GetRegionOrMarker = function(_, index, guid)
      if index and index >= 0 then return PROJECT[index + 1] end
      return marker_by_guid(guid)
    end,
    GetRegionOrMarkerInfo_Value = function(_, e, param)
      if param == "B_ISREGION" then return 0 end
      if param == "I_NUMBER" then return e.id + 0.0 end
      if param == "I_LANENUMBER" then return (e.lane or 0) + 0.0 end
      return 0
    end,
    SetRegionOrMarkerInfo_Value = function(_, e, param, value)
      if param == "I_LANENUMBER" then e.lane = math.floor(value + 0.5) end
      return 0
    end,
    GetSetRegionOrMarkerInfo_String = function(_, e, param, str, is_set)
      if param == "GUID" then return true, e.guid end
      if param == "P_NAME" then
        if is_set then e.name = str return true end
        return true, e.name
      end
      return false, ""
    end,
    AddRegionOrMarker = function(_, _, pos, _, name, _, color)
      next_id = next_id + 1
      local entry = {
        pos = pos, name = name, id = next_id, color = color,
        lane = 0, guid = "{NEW" .. next_id .. "}",
      }
      PROJECT[#PROJECT + 1] = entry
      added[#added + 1] = entry
      return entry
    end,
    AddProjectMarker2 = function(_, _, pos, _, name, _, color)
      next_id = next_id + 1
      local entry = { pos = pos, name = name, id = next_id, color = color }
      PROJECT[#PROJECT + 1] = entry
      added[#added + 1] = entry
      return next_id
    end,
    SetProjectMarker4 = function() return true end,

    -- JS_ReaScriptAPI with the manager open; which rows are selected is what
    -- the driver changes between frames
    new_array = function() return { table = function() return { 1234 } end } end,
    JS_Localize = function(s) return s end,
    JS_Window_ArrayFind = function() return 1 end,
    JS_Window_HandleFromAddress = function() return "hwnd" end,
    JS_Window_FindChildByID = function(_, id)
      if id == 1056 then return "container" end
      if id == 1071 then return "listview" end
      return nil
    end,
    JS_ListView_ListAllSelItems = function()
      if #selected_rows == 0 then return 0, "" end
      return #selected_rows, table.concat(selected_rows, ",")
    end,
    JS_ListView_GetItemText = function(_, row)
      local e = PROJECT[row + 1]
      return e and ("M" .. e.id) or nil
    end,
  }

  local tab_selected, tab_first = nil, nil

  local r = setmetatable({}, {
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
        if key == "ImGui_GetContentRegionAvail" then return 1488, 300 end
        if key == "ImGui_GetWindowSize" then return 1512, 500 end
        if key == "ImGui_GetCursorPos" then return 12, 12 end
        if key == "ImGui_GetCursorPosX" then return 12 end
        if key == "ImGui_GetFrameHeight" then return 23 end
        if key == "ImGui_CalcTextSize" then return 50, 12 end
        if key == "ImGui_GetItemRectMin" then return 100, 100 end
        if key == "ImGui_GetItemRectMax" then return 220, 124 end

        -- A child is a Begin/End pair and leaks exactly like a window; both
        -- the count and the depth are recorded so a missing EndChild shows up
        -- as an unbalanced pair rather than as nothing at all.
        if key == "ImGui_BeginChild" then
          children = children + 1
          child_depth = child_depth + 1
          if child_depth > max_child_depth then max_child_depth = child_depth end
          -- (ctx, str_id, size_w, size_h, ...) -- the geometry the layout asked
          -- for, which is the only way an offline harness can see a layout at all
          child_sizes[#child_sizes + 1] = { id = a2, w = a3, h = a4 }
          return true
        end
        if key == "ImGui_EndChild" then child_depth = child_depth - 1 return nil end

        if key == "ImGui_Button" then
          buttons[#buttons + 1] = a2
          return a2 == click_label
        end

        -- A clicked checkbox reports changed = true and the TOGGLED value,
        -- which is what ImGui does; anything else hands its value straight back
        if key == "ImGui_Checkbox" then
          checkboxes[#checkboxes + 1] = { label = a2, value = a3 }
          if a2 == check_label then return true, not a3 end
          return false, a3
        end

        if key == "ImGui_TextColored" then texts[#texts + 1] = a3 return nil end
        if key == "ImGui_SetCursorPosX" then cursor_x_sets[#cursor_x_sets + 1] = a2 return nil end

        if key == "ImGui_BeginTabBar" then tab_first = nil return true end
        if key == "ImGui_BeginTabItem" then
          if a4 == 1 then tab_selected = a2 end
          if tab_first == nil then tab_first = a2 end
          return tab_selected == a2 or (tab_selected == nil and tab_first == a2)
        end

        if key == "ImGui_InputText" then return false, a3 end
        if key == "ImGui_InputInt" then return false, a3 end
        if key == "ImGui_Combo" then return false, a3 end
        if key == "ImGui_RadioButton" then return false end
        if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
          or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
        return nil
      end
    end,
  })

  -- the footer is the only text drawn at SB.size.small, so the last one wins
  local inner = getmetatable(r).__index
  setmetatable(r, { __index = function(t, key)
    if key == "ImGui_DrawList_AddTextEx" then
      return function(_dl, _font, size, _x, _y, _col, text)
        if size == 11 then footer_text = text end
        return nil
      end
    end
    return inner(t, key)
  end })

  local handle = {
    project = PROJECT,
    added = added,
    boxes = boxes,

    -- One rendered frame. opts.click fires that button, opts.tick clicks that
    -- tick box, opts.select replaces the manager selection first.
    frame = function(frame_opts)
      frame_opts = frame_opts or {}
      if frame_opts.select then selected_rows = frame_opts.select end
      click_label = frame_opts.click
      check_label = frame_opts.tick
      buttons, checkboxes, texts = {}, {}, {}
      children, child_depth = 0, 0
      child_sizes, cursor_x_sets = {}, {}
      local ok, err = pcall(deferred)
      click_label, check_label = nil, nil
      if not ok then error(err) end
    end,

    drew_button = function(label)
      for _, seen in ipairs(buttons) do
        if seen == label then return true end
      end
      return false
    end,
    drew_text = function(text)
      for _, seen in ipairs(texts) do
        if seen == text then return true end
      end
      return false
    end,
    button_count = function() return #buttons end,
    children = function() return children end,
    child_balance = function() return child_depth end,
    max_child_depth = function() return max_child_depth end,

    -- The size BeginChild was called with, by child id.
    child_size = function(id)
      for _, size in ipairs(child_sizes) do
        if size.id == id then return size.w, size.h end
      end
      return nil
    end,
    -- Was the cursor moved to exactly this x at some point in the frame?
    set_cursor_x = function(x)
      for _, seen in ipairs(cursor_x_sets) do
        if seen == x then return true end
      end
      return false
    end,
    cursor_x_sets = function() return cursor_x_sets end,

    -- which tick boxes were drawn, and with which value
    ticks = function()
      local on = {}
      for _, box in ipairs(checkboxes) do
        local key = tostring(box.label):match("^##pick_(.+)$")
        if key and box.value then on[#on + 1] = key end
      end
      table.sort(on)
      return on
    end,
    tick_boxes = function()
      local all = {}
      for _, box in ipairs(checkboxes) do
        local key = tostring(box.label):match("^##pick_(.+)$")
        if key then all[#all + 1] = key end
      end
      return all
    end,
    -- The "N selected" counter, as the panel drew it. The single window also
    -- draws "N markers selected" in its Selection block; the anchored pattern
    -- cannot confuse the two.
    counter = function()
      for _, text in ipairs(texts) do
        local n = tostring(text):match("^(%d+) selected$")
        if n then return tonumber(n) end
      end
      return nil
    end,

    footer = function() return footer_text end,
    added_text = function()
      local parts = {}
      for _, entry in ipairs(added) do
        parts[#parts + 1] = string.format("%s@%.2f", entry.name, entry.pos)
      end
      return table.concat(parts, " ")
    end,
    -- Deleting a marker and putting it back is an undo away in REAPER, and it
    -- is the only way to SEE a tick that was left behind: a stale tick has no
    -- row to be drawn on, so it only shows up when its marker returns.
    remove_marker = function(guid)
      for index, entry in ipairs(PROJECT) do
        if entry.guid == guid then
          return table.remove(PROJECT, index), index
        end
      end
      return nil
    end,
    restore_marker = function(entry, index)
      table.insert(PROJECT, index, entry)
    end,
    rename_marker = function(guid, name)
      local entry = marker_by_guid(guid)
      if entry then entry.name = name return true end
      return false
    end,
  }

  return r, handle
end

local function keys(list)
  return "[" .. table.concat(list, " ") .. "]"
end

local fails = 0
local function check(ok, name, detail)
  if not ok then fails = fails + 1 end
  print(string.format("  %s  %-60s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- Loads the single-window host against a fresh fake and returns its handle.
local function start_single(opts)
  local handle
  reaper, handle = build_reaper(opts)
  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then error("CopyMarkers.lua failed to load: " .. tostring(err)) end
  return handle
end

print("\nCopy Markers -- the tick list decides what gets copied:\n")

-- ------------------------------------------------------- (a) follow mode

do
  -- rows 1 and 2 = verse (M2) and buildup (M3)
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  check(#h.ticks() == 2 and h.ticks()[1] == "{G2}" and h.ticks()[2] == "{G3}",
    "a1) two markers selected -> exactly those two are ticked", keys(h.ticks()))
  check(h.counter() == 2, "a2) and the counter says so", tostring(h.counter()) .. " selected")
  check(#h.tick_boxes() == 5, "a3) every marker in the project has a row",
    #h.tick_boxes() .. " rows")
  check(h.drew_text("Cues") and h.drew_text("FX") and h.drew_text("Music"),
    "a4) each row names its ruler lane", "")

  h.frame({ click = "Copy to cursor" })
  h.frame()
  check(h.added_text() == "verse@34.20 buildup@37.95",
    "a5) Copy to cursor copies exactly the ticked markers", h.added_text())
  check(h.footer() == "2 markers copied.", "a6) and the footer says so",
    "footer " .. tostring(h.footer()))
end

-- --------------------------------------------- (b) one click and it is mine

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  h.frame({ tick = "##pick_{G4}" })          -- drop, a third one
  h.frame()
  check(#h.ticks() == 3, "b1) ticking a third box adds it to the two followed ones",
    keys(h.ticks()))

  -- the manager throws the selection away and lands on a single other marker
  h.frame({ select = { 4 } })
  h.frame()
  check(#h.ticks() == 3 and h.ticks()[1] == "{G2}" and h.ticks()[2] == "{G3}"
    and h.ticks()[3] == "{G4}",
    "b2) the manager selection changes -- the ticks do not", keys(h.ticks()))
  check(h.counter() == 3, "b3) the counter still says three", tostring(h.counter()))

  h.frame({ click = "Copy to cursor" })
  h.frame()
  check(h.added_text() == "verse@34.20 buildup@37.95 drop@41.70",
    "b4) and the copy takes the three ticked, not the one selected", h.added_text())
end

-- --------------------------------------------------- (c) Clear selection

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  h.frame({ click = "Clear selection" })
  h.frame()
  check(#h.ticks() == 0, "c1) Clear selection clears every tick", keys(h.ticks()))
  check(h.counter() == 0, "c2) and the counter follows", tostring(h.counter()))

  h.frame({ click = "Copy to cursor" })
  h.frame()
  check(#h.added == 0, "c3) copying without a tick copies nothing", #h.added .. " copies")
  check(h.footer() == "Tick the markers to copy.", "c4) and says what to do instead",
    "footer " .. tostring(h.footer()))

  -- Clear selection is manual: the selection must not tick itself again next frame
  h.frame({ select = { 1, 2, 3 } })
  h.frame()
  check(#h.ticks() == 0, "c5) and the manager selection does not tick them again",
    keys(h.ticks()))
end

-- ------------------------------------------------------ (d) Use selection

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  h.frame({ tick = "##pick_{G5}" })          -- manual, three ticks in total
  h.frame({ select = { 0 } })                -- manager now holds intro alone
  h.frame()
  check(#h.ticks() == 3, "d1) manual mode is holding three ticks", keys(h.ticks()))

  h.frame({ click = "Use selection" })
  h.frame()
  check(#h.ticks() == 1 and h.ticks()[1] == "{G1}",
    "d2) Use selection replaces the ticks with the selection", keys(h.ticks()))

  h.frame({ select = { 3, 4 } })
  h.frame()
  check(#h.ticks() == 2 and h.ticks()[1] == "{G4}" and h.ticks()[2] == "{G5}",
    "d3) and follow mode is on again -- the ticks track the manager", keys(h.ticks()))
end

-- ------------------------------------------- (e) a ticked marker disappears

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  h.frame({ tick = "##pick_{G4}" })
  h.frame({ select = {} })
  h.frame()
  check(#h.ticks() == 3 and h.counter() == 3, "e1) three ticked, nothing selected",
    keys(h.ticks()))

  local gone, where = h.remove_marker("{G3}")  -- buildup deleted in REAPER
  h.frame()
  h.frame()
  check(#h.ticks() == 2 and h.ticks()[1] == "{G2}" and h.ticks()[2] == "{G4}",
    "e2) a deleted marker loses its tick", keys(h.ticks()))
  check(h.counter() == 2, "e3) and the counter counts what is left",
    tostring(h.counter()))
  check(#h.tick_boxes() == 4, "e4) and the row is gone with it",
    #h.tick_boxes() .. " rows")

  h.frame({ click = "Copy to cursor" })
  h.frame()
  check(h.added_text() == "verse@34.20 drop@41.70",
    "e5) the copy takes the two that are left", h.added_text())

  -- Ctrl+Z in REAPER: the marker is back, and it must come back UNticked --
  -- a tick that merely went invisible while its row was gone would reappear
  -- here and copy a marker nobody picked.
  h.restore_marker(gone, where)
  h.frame()
  h.frame()
  check(#h.ticks() == 2 and h.ticks()[1] == "{G2}" and h.ticks()[2] == "{G4}",
    "e6) undoing the delete does not bring the tick back", keys(h.ticks()))
  check(#h.tick_boxes() == 7, "e7) the restored marker has a row again (2 copies too)",
    #h.tick_boxes() .. " rows")
end

-- ---------------------------------------------------- (g) renaming a marker

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  h.frame({ tick = "##pick_{G4}" })
  h.frame({ select = {} })
  h.frame()
  check(#h.ticks() == 3, "g1) three ticked before the rename", keys(h.ticks()))

  h.rename_marker("{G4}", "drop 2")          -- same GUID, different name
  h.frame()
  h.frame()
  check(#h.ticks() == 3 and h.ticks()[3] == "{G4}",
    "g2) renaming a marker keeps its tick", keys(h.ticks()))
  check(h.drew_text("drop 2"), "g3) and the row shows the new name", "")

  h.frame({ click = "Copy to cursor" })
  h.frame()
  check(h.added_text() == "verse@34.20 buildup@37.95 drop 2@41.70",
    "g4) and it is still copied", h.added_text())
end

-- -------------------------------------------- (f) the list in both hosts

do
  local h = start_single({ selected_rows = { 1, 2 } })

  h.frame()
  check(h.drew_button("Copy to cursor") and h.drew_button("Copy to measure.beats")
    and h.drew_button("Copy to hh:mm:ss:ff"),
    "f1) the single window draws the three copy buttons", h.button_count() .. " buttons")
  check(h.drew_button("Use selection") and h.drew_button("Clear selection"),
    "f2) and the two tick buttons, by their new names", "")
  check(not h.drew_button("None"), "f2b) and never the old \"None\"", "")
  check(h.children() == 1, "f3) and puts the list in ONE child of its own",
    h.children() .. " children")
  check(h.child_balance() == 0, "f4) every BeginChild has its EndChild",
    "balance " .. h.child_balance())

  -- the single window keeps its 600 px list: that window auto-sizes, so the
  -- list must not be the thing deciding how wide it gets
  local w, list_h = h.child_size("copy_pick_list")
  check(w == 600, "f4b) the single window's list is still 600 wide", tostring(w))
  check(list_h == 8 * (23 + 7), "f4c) and eight rows tall", tostring(list_h))
end

do
  -- the workspace, with the Copy Markers tab open
  local handle
  reaper, handle = build_reaper({ selected_rows = { 1, 2 }, ext = { active_tab = "copy" } })
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then error("steelblue_workspace.lua failed to load: " .. tostring(err)) end

  handle.frame()
  check(handle.drew_button("Copy to cursor") and handle.drew_button("Copy to measure.beats")
    and handle.drew_button("Copy to hh:mm:ss:ff"),
    "f5) the copy tab draws the same three buttons", handle.button_count() .. " buttons")
  check(handle.drew_button("Use selection") and handle.drew_button("Clear selection"),
    "f6) and the same two tick buttons, by their new names", "")
  check(not handle.drew_button("None"), "f6b) and never the old \"None\" here either", "")
  check(handle.children() == 1, "f7) and puts the list in a child there too",
    handle.children() .. " children")
  check(handle.child_balance() == 0, "f8) every BeginChild has its EndChild",
    "balance " .. handle.child_balance())
  check(#handle.ticks() == 2, "f9) the ticks work there too", keys(handle.ticks()))

  handle.frame({ click = "Copy to cursor" })
  handle.frame()
  check(handle.added_text() == "verse@34.20 buildup@37.95",
    "f10) and so does the copy", handle.added_text())
end

-- ------------------------------------ (i) where the tab puts its two columns

-- Tobi, TT 96 (2026-09-16): "Die Tabelle koennte noch etwas breiter sein.
-- Einfach Haelfte der Breite Tabelle, Haelfte der Breite UI." The list now
-- gets half of what the tab has left (floor, right edge as before) instead of
-- a fixed 520 px; the controls column gets the other half. TT 97 (a scrollbar
-- under ~370 px) is accepted -- height is untouched.
--
-- The fake reports GetContentRegionAvail = (1488, 300) and GetCursorPosX = 12,
-- so the list is floor((1488 - 24) / 2) = 732 wide and starts at
-- 12 + 1488 - 732 = 768. Those two numbers are the only part of a layout an
-- offline harness can see at all (AGENTS.md: "Layout is the one thing the
-- offline harness cannot check") -- they prove the intent, not the picture.
-- TT 212 is the picture.
do
  local handle
  reaper, handle = build_reaper({ selected_rows = { 1, 2 }, ext = { active_tab = "copy" } })
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then error("steelblue_workspace.lua failed to load: " .. tostring(err)) end

  handle.frame()

  local w, list_h = handle.child_size("copy_pick_list")
  check(w == 732, "i1) the tab's list is half the available width, not 520",
    tostring(w))
  check(handle.set_cursor_x(12 + 1488 - 732),
    "i2) and starts at the right edge minus that half", "x = " .. tostring(12 + 1488 - 732))
  check(list_h == 300 - 42 - 7,
    "i3) and still reaches down to the host's footer", tostring(list_h))

  -- the sections that loosen the left column up
  check(handle.drew_text("EDIT CURSOR") and handle.drew_text("TARGET POSITION")
    and handle.drew_text("COPY"),
    "i4) the left column has its three section headings", "")
  check(handle.drew_text("Measure M:34.2  \194\183  Timecode T:34.2"),
    "i5) Measure and Timecode share one line, to fit a 400 px docker", "")
end

-- ------------------------------------------------ (h) 600 markers, measured

do
  local many = {}
  for index = 1, 600 do
    many[index] = {
      pos = index * 0.5,
      name = "cue " .. index,
      id = index,
      color = 0,
      lane = index % 3,
      guid = string.format("{B%04d}", index),
    }
  end

  local handle
  reaper, handle = build_reaper({ project = many, selected_rows = { 0, 1 } })

  local MARKERS = dofile(folder .. "steelblue_markers.lua")

  local ROUNDS = 20
  local started = os.clock()
  for _ = 1, ROUNDS do MARKERS.markers_by_id() end
  local per_read = (os.clock() - started) / ROUNDS * 1000

  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then error("CopyMarkers.lua failed to load: " .. tostring(err)) end

  handle.frame()
  local frame_started = os.clock()
  handle.frame()
  local per_frame = (os.clock() - frame_started) * 1000

  check(#handle.tick_boxes() == 600, "h1) 600 markers -> 600 rows",
    #handle.tick_boxes() .. " rows")
  check(per_read < 20,
    "h2) reading all 600 markers stays under 20 ms",
    string.format("%.2f ms per read (%d rounds)", per_read, ROUNDS))
  -- printed, not judged: this is the whole frame, list drawing included, and
  -- against a Lua fake rather than REAPER
  check(true, "h3) one full frame with 600 rows, for the record",
    string.format("%.2f ms", per_frame))
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
