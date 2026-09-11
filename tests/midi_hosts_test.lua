-- Both hosts of steelblue_midi.lua, driven the way a user drives them: one
-- track "Kick (12)" with a MIDI item of two notes, then the "All MIDI items in
-- the project" button clicked, then the project and the footer read.
--
-- tests/midi_lanes_test.lua proves the grouping, naming and lane logic. It does
-- NOT press a button: it reaches through the MIDI_TEST hook straight into
-- run_with_scope, so a panel that never draws its buttons, never queues the
-- run, or never lets it out again after the frame would leave that suite
-- perfectly green. This file is the other half -- it only ever touches labels,
-- the project and the status line, the things a user actually sees.
--
-- Same fake as rename_hosts_test.lua: the tab bar remembers its selection the
-- way Dear ImGui does, every frame is a second later so the 150 ms selection
-- poll fires on each of them, and JS_ReaScriptAPI reports the manager open
-- with three rows selected -- MIDI does not read that selection, which is
-- exactly what check (b4) is about.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

local PPQ_PER_SECOND = 960

local PROJECT, ext_state, deferred, armed, footer_text, labels, texts, click_label,
  clock, messages, selection_polls

local function drew(label)
  for _, seen in ipairs(labels) do
    if seen == label then return true end
  end
  return false
end

local function marker_names()
  local names = {}
  for _, entry in ipairs(PROJECT) do names[#names + 1] = entry.name end
  table.sort(names)
  return table.concat(names, " / ")
end

local function build_reaper(initial_ext)
  PROJECT = {}

  ext_state = {}
  for key, value in pairs(initial_ext or {}) do ext_state[key] = value end

  deferred, armed, footer_text, click_label = nil, false, nil, nil
  labels, texts, messages = {}, {}, {}
  clock = 0
  selection_polls = 0

  -- one track, one item, two notes: C2 at the item start, D2 one second in
  local track = { name = "Kick (12)", color = 0x10A141E, number = 1 }
  local item = { pos = 0.0, length = 4.0, loop = 0, track = track }
  local take = { item = item, notes = { { ppq = 0, pitch = 36 }, { ppq = 960, pitch = 38 } } }
  item.take = take
  track.items = { item }

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
    -- 7.75: no ruler lanes, so the markers go through AddProjectMarker2 and
    -- the completion text is the short one
    GetAppVersion = function() return "7.75/OSX64" end,
    ShowMessageBox = function(m) messages[#messages + 1] = m return 6 end,

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

    -- tracks, items, takes
    CountTracks = function() return 1 end,
    GetTrack = function(_, index) return index == 0 and track or nil end,
    CountTrackMediaItems = function() return 1 end,
    GetTrackMediaItem = function(_, index) return index == 0 and item or nil end,
    GetActiveTake = function(i) return i.take end,
    TakeIsMIDI = function() return true end,
    GetMediaItemTake_Item = function(t) return t.item end,
    GetMediaItem_Track = function(i) return i.track end,
    CountSelectedMediaItems = function() return 1 end,
    GetSelectedMediaItem = function(_, index) return index == 0 and item or nil end,
    GetTrackColor = function(t) return t.color end,
    GetSetMediaTrackInfo_String = function(t, param)
      if param == "P_NAME" then return true, t.name end
      return false, ""
    end,
    GetMediaTrackInfo_Value = function(t, param)
      if param == "IP_TRACKNUMBER" then return t.number end
      return 0
    end,
    GetMediaItemInfo_Value = function(i, param)
      if param == "D_POSITION" then return i.pos end
      if param == "D_LENGTH" then return i.length end
      if param == "B_LOOPSRC" then return i.loop end
      return 0
    end,
    GetTrackMIDINoteNameEx = function() return nil end,
    MIDI_CountEvts = function(t) return 0, #t.notes, 0 end,
    MIDI_GetNote = function(t, index)
      local note = t.notes[index + 1]
      if not note then return false end
      return true, false, false, note.ppq, note.ppq + 120, 0, note.pitch
    end,
    MIDI_GetProjTimeFromPPQPos = function(t, ppq) return t.item.pos + ppq / PPQ_PER_SECOND end,
    MIDI_GetPPQPosFromProjTime = function(t, time) return (time - t.item.pos) * PPQ_PER_SECOND end,

    -- markers: the project starts empty; every marker the run creates lands here
    EnumProjectMarkers3 = function(_, index)
      local e = PROJECT[index + 1]
      if not e then return 0 end
      return 1, false, e.pos, e.pos, e.name, e.id, e.color
    end,
    AddProjectMarker2 = function(_, _, pos, _, name, _, color)
      PROJECT[#PROJECT + 1] = { pos = pos, name = name, id = #PROJECT + 1, color = color }
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
    -- one call per MARKERS.selected(): this is the poll counter of check (b4)
    JS_ListView_ListAllSelItems = function() selection_polls = selection_polls + 1 return 3, "0,1,2" end,
    JS_ListView_GetItemText = function(_, row)
      local rows = { [0] = "M1", [1] = "M2", [2] = "M3" }
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
        if key == "ImGui_TextColored" then texts[#texts + 1] = a3 end
        if key == "ImGui_Text" or key == "ImGui_TextWrapped" then texts[#texts + 1] = a2 end

        if key == "ImGui_BeginTabBar" then tab_first = nil return true end
        if key == "ImGui_BeginTabItem" then
          if a4 == 1 then tab_selected = a2 end
          if tab_first == nil then tab_first = a2 end
          return tab_selected == a2 or (tab_selected == nil and tab_first == a2)
        end

        if key == "ImGui_Checkbox" then return false, a3 end
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
  labels, texts = {}, {}
  armed = false
  selection_polls = 0
  local ok, err = pcall(deferred)
  if not ok then error(err) end
  return armed
end

local READY = "Markers are placed at every MIDI note start."
local ALL_BUTTON = "All MIDI items in the project"

print("\nsteelblue_midi.lua in both hosts -- click the button, read the project:\n")

-- ------------------------------------------------------------- single script

do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "MIDI notes to project markers.lua")
  if not ok then
    check(false, "a) the single script loads", tostring(err))
  else
    frame()
    check(drew(ALL_BUTTON) and drew("Only selected MIDI items"),
      "a1) its own window draws the two scope buttons", #labels .. " buttons drawn")
    check(drew("Cancel"), "a2) and the Cancel button", "")
    check(footer_text == READY, "a3) and the sentence in the footer", "footer " .. tostring(footer_text))

    click_label = ALL_BUTTON
    local again = frame()
    click_label = nil

    check(#PROJECT == 2, "a4) clicking All MIDI items creates the markers", #PROJECT .. " markers")
    check(marker_names() == "C2(1)[Top]^Kick^ / D2(2)[Top]^Kick^",
      "a5) named after the notes, ranked, in the track's sequence", marker_names())
    check(#messages == 1 and messages[1] == "2 markers created.",
      "a6) the completion box is shown", tostring(messages[1]))
    check(not again, "a7) and the window closes after the run", again and "deferred again" or "not deferred")
  end
end

do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "MIDI notes to project markers.lua")
  if not ok then
    check(false, "a8) the single script loads for the Cancel check", tostring(err))
  else
    frame()
    click_label = "Cancel"
    local again = frame()
    click_label = nil
    check(not again and #PROJECT == 0 and #messages == 0,
      "a8) Cancel closes the window without a run",
      (again and "deferred again" or "closed") .. ", " .. #PROJECT .. " markers")
  end
end

-- ------------------------------------------------------------- workspace tab

do
  reaper = capture_footer(build_reaper({ active_tab = "midi" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "b) the workspace loads", tostring(err))
  else
    frame()
    check(drew(ALL_BUTTON) and drew("Only selected MIDI items"),
      "b1) the midi tab draws the same two buttons", #labels .. " buttons drawn")
    check(footer_text == READY, "b2) and the sentence in the workspace footer", "footer " .. tostring(footer_text))
    check(not drew("Cancel"), "b3) but no Cancel button -- the tab is not a window", "")
    check(selection_polls == 1,
      "b4) the selection is polled once per frame, by the workspace only",
      selection_polls .. " polls")

    click_label = ALL_BUTTON
    frame()
    click_label = nil
    local again = frame()

    check(#PROJECT == 2, "b5) the same click creates the same markers", #PROJECT .. " markers")
    check(footer_text == "2 markers created.",
      "b6) the completion text lands in the workspace footer", "footer " .. tostring(footer_text))
    check(#messages == 1, "b7) and the box is still shown", #messages .. " boxes")
    check(again, "b8) the workspace stays open", "")

    frame()
    check(#PROJECT == 2 and #messages == 1,
      "b9) two more frames do not run it again", #PROJECT .. " markers, " .. #messages .. " boxes")
  end
end

-- ------------------------------------------------------------ a different tab

do
  reaper = capture_footer(build_reaper({ active_tab = "rename" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "c) the workspace loads on the rename tab", tostring(err))
  else
    frame()
    frame()

    check(not drew(ALL_BUTTON) and not drew("Only selected MIDI items"),
      "c1) another tab does not draw the scope buttons", #labels .. " buttons drawn")
    check(drew("Rename selected markers"), "c2) it draws the rename panel instead", "")

    click_label = ALL_BUTTON
    frame()
    click_label = nil
    frame()
    check(#PROJECT == 0 and #messages == 0, "c3) a click on the absent button does nothing",
      #PROJECT .. " markers, " .. #messages .. " boxes")
  end
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
