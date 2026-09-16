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
--
-- The popup fake works the same way it does in bpm_hosts_test.lua: a popup is
-- open only once OpenPopup has been called for its id, and it stays open until
-- CloseCurrentPopup. A fake that said "open" to every BeginPopup would draw the
-- legend whether or not the button was ever pressed, which is the whole of what
-- (e) and (f) below are asking about.

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

local PROJECT, ext_state, deferred, footer_text, labels, texts, click_label, clock,
  selection_polls, marker_writes, popups_open, current_popup, window_pos_calls

-- The window height the fake reports. 500 px is Tobi's usual docker; (g) turns
-- it down to 400, which is where the legend used to be dropped.
local window_h = 500

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

local function count_label(label)
  local seen = 0
  for _, value in ipairs(labels) do
    if value == label then seen = seen + 1 end
  end
  return seen
end

-- Legend lines carry their columns in the string itself, so they are matched by
-- a piece of their text rather than by the whole padded line.
local function drew_text_containing(needle)
  for _, text in ipairs(texts) do
    if type(text) == "string" and text:find(needle, 1, true) then return true end
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
  popups_open, current_popup = {}, nil
  window_pos_calls = {}
  clock = 0
  selection_polls = 0
  marker_writes = 0

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
    -- every rename and every colour goes through here (7.75: no P_NAME); the
    -- count per frame is what the "do not rename again" checks read
    SetProjectMarker4 = function(_, id, _, _, _, name, color)
      marker_writes = marker_writes + 1
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
    -- one call per MARKERS.selected(): this is the poll counter of check (b4)
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

      -- (ctx, label, value, flags) for every widget below, so a2 is the label
      -- and a3 the value the caller passed in
      return function(a1, a2, a3, a4)
        if key == "ImGui_CreateContext" then return "ctx" end
        if key == "ImGui_CreateFont" then return "font" end
        if key == "ImGui_GetWindowDrawList" then return "dl" end
        if key == "ImGui_Begin" then return true, true end
        if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
        -- one entry per call, so a test can check both the count (OpenPopup
        -- must be armed exactly once per click) and the position (the popup
        -- must land under the anchor, not wherever the mouse was)
        if key == "ImGui_SetNextWindowPos" then
          window_pos_calls[#window_pos_calls + 1] = { x = a2, y = a3 }
          return nil
        end
        -- a docked strip, the width Tobi's workspace actually has
        if key == "ImGui_GetContentRegionAvail" then return 1400, 300 end
        if key == "ImGui_GetWindowSize" then return 1512, window_h end

        -- A popup is open only once OpenPopup has been called for its id, and
        -- it stays open until something closes it -- exactly the handshake the
        -- "Legend" button depends on.
        if key == "ImGui_OpenPopup" then popups_open[a2] = true return nil end
        if key == "ImGui_BeginPopup" then
          if popups_open[a2] then current_popup = a2 return true end
          return false
        end
        if key == "ImGui_CloseCurrentPopup" then
          if current_popup then popups_open[current_popup] = nil end
          return nil
        end
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
  selection_polls = 0
  marker_writes = 0
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
    check(footer_text == "3 markers renamed and coloured.",
      "a2) clicking Rename renames the selection",
      "footer " .. tostring(footer_text))
    check(renamed == "verse(1)[Top]^verse^"
      and marker(3).name == renamed and marker(4).name == renamed,
      "a3) all three markers carry the template's name", renamed)
    check(marker(1).name == "intro" and marker(5).name == "break",
      "a4) the markers that were not selected are untouched",
      marker(1).name .. " / " .. marker(5).name)
    check(drew("Close"), "a5) its own window draws the Close button", "")
    check(drew("Legend") and not drew_text_containing("BeatFx(1)[Top]^BeatFx^"),
      "a5b) it draws the Legend button and not the legend itself",
      #texts .. " texts")

    -- the queue must be empty after the one click: not a single write on the
    -- frames that follow
    frame()
    local writes = marker_writes
    frame()
    check(writes == 0 and marker_writes == 0, "a6) two more frames do not rename again",
      writes + marker_writes .. " writes")
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

    check(footer_text == "3 markers renamed and coloured.",
      "b2) the same click writes into the workspace footer",
      "footer " .. tostring(footer_text))
    check(marker(2).name == "verse(1)[Top]^verse^",
      "b3) and renames the same three markers", marker(2).name)
    check(not drew("Close"), "b4) but no Close button -- the tab is not a window", "")
    check(drew("Legend") and not drew_text_containing("BeatFx(1)[Top]^BeatFx^"),
      "b4b) the Legend button is there, the legend itself is not",
      #texts .. " texts")
    check(selection_polls == 1,
      "b5) the selection is polled once per frame, by the workspace only",
      selection_polls .. " polls")

    frame()
    local writes = marker_writes
    frame()
    check(writes == 0 and marker_writes == 0, "b6) two more frames do not rename again",
      writes + marker_writes .. " writes")
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

    check(not drew("Rename selected markers") and not drew("Reset to defaults"),
      "c1) another tab does not draw the rename panel",
      #labels .. " buttons drawn")
    check(drew("All MIDI items in the project"), "c2) it draws the MIDI panel instead")
    check(marker(2).name == "verse", "c3) nothing was renamed", marker(2).name)
  end
end

-- --------------------------------------------------------- the +/- arrows

do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "Rename selected markers.lua")
  if not ok then
    check(false, "d) the single script loads for the arrow test", tostring(err))
  else
    frame()

    click_label = "+"
    frame()
    click_label = nil
    frame()

    click_label = "Rename selected markers"
    frame()
    click_label = nil
    frame()

    local renamed = marker(2).name
    check(renamed == "verse(2)[Top]^verse^",
      "d1) the + button bumps the cue number before renaming",
      renamed)
  end
end

-- ------------------------------------------------------------ the legend popup

-- The single window. Only opening is checked here: its own "Close" button
-- carries the same label as the popup's, and a fake click by label would press
-- both at once. Closing is checked on the workspace below, where the tab draws
-- no Close of its own and the label belongs to the popup alone.
do
  reaper = capture_footer(build_reaper())
  local ok, err = pcall(dofile, folder .. "Rename selected markers.lua")
  if not ok then
    check(false, "e) the single script loads for the legend test", tostring(err))
  else
    frame()
    local before = count_label("Close")

    click_label = "Legend"
    frame()
    click_label = nil
    frame()

    check(drew_text_containing("BeatFx(1)[Top]^BeatFx^"),
      "e1) clicking Legend opens the popup with the example line", "")
    check(drew_text_containing("One sequence is generated per marker colour"),
      "e2) the popup carries the introduction sentence too", "")
    check(before == 1 and count_label("Close") == 2,
      "e3) and a Close button of its own, next to the window's",
      before .. " -> " .. count_label("Close"))

    -- The click frame and the frame right after it have both run by now
    -- (see above): exactly one SetNextWindowPos, anchored under the button
    -- ("Legend" is drawn right after the preview field, whose screen
    -- position the fake's GetCursorScreenPos reports as 100, 100).
    local call = window_pos_calls[1]
    check(#window_pos_calls == 1 and call and call.x == 100 and call.y > 100,
      "e4) SetNextWindowPos is called once, x at the anchor and y below it",
      #window_pos_calls .. " calls, x=" .. tostring(call and call.x) .. " y=" .. tostring(call and call.y))

    frame()
    check(#window_pos_calls == 1,
      "e5) a further frame without a click adds no further call",
      #window_pos_calls .. " calls")
  end
end

-- The workspace tab: open it, read it, close it.
do
  reaper = capture_footer(build_reaper({ active_tab = "rename" }))
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "f) the workspace loads for the legend test", tostring(err))
  else
    frame()
    check(count_label("Legend") == 1,
      "f1) the tab draws exactly one Legend button", count_label("Legend") .. " drawn")

    click_label = "Legend"
    frame()
    click_label = nil
    frame()

    check(drew_text_containing("BeatFx(1)[Top]^BeatFx^") and drew("Close"),
      "f2) the popup opens with the legend and a Close button", "")

    -- Same anchoring in the workspace host: the header band's own popup (the
    -- BPM analyzer's ">>>") was never requested here, so this is the legend's
    -- call alone.
    local call = window_pos_calls[1]
    check(#window_pos_calls == 1 and call and call.x == 100 and call.y > 100,
      "f2b) the workspace host anchors the popup the same way",
      #window_pos_calls .. " calls, x=" .. tostring(call and call.x) .. " y=" .. tostring(call and call.y))

    click_label = "Close"
    frame()
    click_label = nil
    frame()

    check(not drew_text_containing("BeatFx(1)[Top]^BeatFx^") and not drew("Close"),
      "f3) Close closes it again", #texts .. " texts")
    check(marker(2).name == "verse", "f4) and nothing was renamed on the way",
      marker(2).name)
  end
end

-- A short docker: the legend used to be dropped below 450 px, so the one place
-- it was needed most was the one place it was not there.
do
  reaper = capture_footer(build_reaper({ active_tab = "rename" }))
  window_h = 400
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "g) the workspace loads in a short docker", tostring(err))
  else
    frame()
    check(drew("Legend"), "g1) a 400 px docker draws the Legend button as well", "")

    click_label = "Legend"
    frame()
    click_label = nil
    frame()

    check(drew_text_containing("BeatFx(1)[Top]^BeatFx^"),
      "g2) and the legend is reachable there", "")
  end
  window_h = 500
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
