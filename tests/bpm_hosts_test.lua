-- Both hosts of steelblue_bpm.lua, driven the way a user drives them: a song
-- item on one track, the play cursor running through it, and the analyzer
-- either in its own window or as the block in the workspace header band.
--
-- The five BPM suites (bpm_accuracy, bpm_busy, bpm_confidence_validate,
-- bpm_incremental, bpm_item_pick) prove that the DSP, the live reader and the
-- item pick still do what they did -- they load the single script and never
-- draw a pixel. This file is the other half: what the two hosts draw, that the
-- live path keeps running behind a tab that is not the analyzer's, that the
-- switch really stops it, that the ">>>" popup opens and closes, that a button
-- inside the popup acts, and that the audio accessor is handed back when the
-- window closes.
--
-- Same fake as copy_hosts_test.lua: the ImGui surface is the real dylib's
-- function list, so a mistyped ImGui_* name is a missing API and not a silent
-- no-op. What is new here is a fake audio accessor (every read is counted) and
-- a popup that is only open once OpenPopup has been called for it -- a fake
-- that says "open" to every BeginPopup would hide the whole ">>>" mechanism.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

local MORE = "\u{203A}\u{203A}\u{203A}"

-- How far the play cursor moves between two rendered frames. Below the
-- analyzer's own jump limit (2 x UPDATE_INTERVAL), so the rolling window keeps
-- continuing instead of being thrown away and refilled every frame.
local PLAY_STEP = 0.9

local buttons, texts, checkboxes, inputs, click_label, checkbox_force
local begin_open, deferred, armed, clock, play_pos
local accessor_reads, accessors_created, accessors_destroyed
local popups_open, current_popup

-- A square-wave beat, computed per sample instead of stored: the analyzer only
-- has to find transients in it, and a 200 s table would be the slowest part of
-- this file by far.
local function sample_at(index)
  return (index % 5512) < 200 and 0.8 or 0.01
end

local function drew(label)
  return buttons[label] == true or texts[label] == true
    or checkboxes[label] == true or inputs[label] == true
end

-- The kv rows carry their value in the same string, so they are matched by
-- their first word.
local function drew_starting_with(prefix)
  for text in pairs(texts) do
    if text:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function build_reaper(initial_ext)
  buttons, texts, checkboxes, inputs = {}, {}, {}, {}
  click_label, checkbox_force = nil, nil
  begin_open = true
  deferred, armed = nil, false
  clock, play_pos = 0, 0
  accessor_reads, accessors_created, accessors_destroyed = 0, 0, 0
  popups_open, current_popup = {}, nil

  local ext_state = {}
  for key, value in pairs(initial_ext or {}) do ext_state[key] = value end

  -- one song item on one track, and nothing selected: the picker takes the
  -- item under the play cursor, which is the state the analyzer is used in
  local take = { name = "song.wav" }
  local track = { name = "Song", number = 1 }
  local item = { track = track, take = take }
  track.items = { item }

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

    Master_GetTempo = function() return 120.0 end,
    GetCursorPosition = function() return play_pos end,
    GetPlayPosition = function() return play_pos end,
    GetPlayState = function() return 1 end,

    CountTracks = function() return 1 end,
    GetTrack = function(_, index) return index == 0 and track or nil end,
    CountTrackMediaItems = function() return 1 end,
    GetTrackMediaItem = function(_, index) return index == 0 and item or nil end,
    GetActiveTake = function(it) return it.take end,
    TakeIsMIDI = function() return false end,
    GetTakeName = function(tk) return tk.name end,
    GetMediaItemTrack = function(it) return it.track end,
    GetTrackName = function(tr) return true, tr.name end,
    GetSelectedMediaItem = function() return nil end,
    ValidatePtr2 = function() return true end,
    GetSetMediaItemInfo_String = function() return true, "" end,
    GetMediaItemInfo_Value = function(_, key)
      if key == "D_POSITION" then return 0 end
      if key == "D_LENGTH" then return 200 end
      return 0
    end,
    GetMediaTrackInfo_Value = function(_, key)
      if key == "IP_TRACKNUMBER" then return 1 end
      return 0
    end,

    -- the audio accessor, counted: this is how "is the live path still
    -- running" is asked a question a fake cannot answer with "yes" by default
    CreateTakeAudioAccessor = function(tk)
      accessors_created = accessors_created + 1
      return { take = tk }
    end,
    DestroyAudioAccessor = function()
      accessors_destroyed = accessors_destroyed + 1
    end,
    -- Deliberately false, and deliberately present: without it the catch-all
    -- below would return 0, the analyzer would read that as "the take changed
    -- under me" and throw its rolling window away on every single frame.
    AudioAccessorValidateState = function() return false end,
    GetMediaItemTake_Source = function(tk) return { take = tk } end,
    GetMediaSourceNumChannels = function() return 1 end,
    GetAudioAccessorSamples = function(_, sample_rate, channels, start_seconds, sample_count, buffer)
      accessor_reads = accessor_reads + 1
      local start_sample = math.floor((start_seconds * sample_rate) + 0.5)
      for index = 0, sample_count - 1 do
        buffer[(index * channels) + 1] = sample_at(start_sample + index)
      end
      return 1
    end,
    new_array = function() return { clear = function() end, table = function() return {} end } end,

    GetExtState = function(_, key) return ext_state[key] or "" end,
    SetExtState = function(_, key, value) ext_state[key] = value end,
    DeleteExtState = function(_, key) ext_state[key] = nil end,
    HasExtState = function(_, key) return ext_state[key] ~= nil end,

    format_timestr_pos = function(pos) return tostring(pos) end,
    parse_timestr_pos = function() return 0 end,
    ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end,
    ColorFromNative = function(v) return v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF end,

    -- JS_ReaScriptAPI present, Region/Marker Manager closed: the three tab
    -- panels draw their "nothing selected" state, which is all this file needs
    -- from them
    JS_Localize = function(s) return s end,
    JS_Window_ArrayFind = function() return 0 end,
    JS_Window_HandleFromAddress = function() return nil end,
    JS_Window_FindChildByID = function() return nil end,
    JS_ListView_ListAllSelItems = function() return 0, "" end,
    JS_ListView_GetItemText = function() return "" end,
    EnumProjectMarkers3 = function() return 0 end,
    GetNumRegionsOrMarkers = function() return 0 end,
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
        if key == "ImGui_Begin" then return true, begin_open end
        if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
        if key == "ImGui_GetContentRegionAvail" then return 1400, 300 end
        if key == "ImGui_GetWindowSize" then return 1512, 500 end
        if key == "ImGui_GetCursorPos" then return 12, 12 end
        if key == "ImGui_GetCursorPosX" then return 12 end
        if key == "ImGui_GetFrameHeight" then return 23 end
        if key == "ImGui_CalcTextSize" then return 50, 12 end
        if key == "ImGui_GetItemRectMin" then return 100, 100 end
        if key == "ImGui_GetItemRectMax" then return 220, 124 end

        -- A popup is open only once OpenPopup has been called for its id, and
        -- it stays open until something closes it -- exactly the handshake the
        -- ">>>" button depends on.
        if key == "ImGui_OpenPopup" then popups_open[a2] = true return nil end
        if key == "ImGui_BeginPopup" then
          if popups_open[a2] then current_popup = a2 return true end
          return false
        end
        if key == "ImGui_CloseCurrentPopup" then
          if current_popup then popups_open[current_popup] = nil end
          return nil
        end

        if key == "ImGui_Button" then
          buttons[a2] = true
          return a2 == click_label
        end
        -- every submitted text, kv rows included, so "does the popup name the
        -- source" is a question about what was drawn and not about a call count
        if key == "ImGui_TextColored" then texts[a3] = true return nil end
        if key == "ImGui_TextWrapped" then texts[a2] = true return nil end
        if key == "ImGui_Text" then texts[a2] = true return nil end

        if key == "ImGui_BeginTabBar" then tab_first = nil return true end
        if key == "ImGui_BeginTabItem" then
          if a4 == 1 then tab_selected = a2 end
          if tab_first == nil then tab_first = a2 end
          return tab_selected == a2 or (tab_selected == nil and tab_first == a2)
        end

        if key == "ImGui_Checkbox" then
          checkboxes[a2] = true
          if checkbox_force and checkbox_force[a2] ~= nil then
            return true, checkbox_force[a2]
          end
          return false, a3
        end
        if key == "ImGui_InputText" then inputs[a2] = true return false, a3 end
        if key == "ImGui_InputInt" then inputs[a2] = true return false, a3 end
        if key == "ImGui_Combo" then return false, a3 end
        if key == "ImGui_RadioButton" then return false end
        if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
          or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
        return nil
      end
    end,
  })
end

local fails = 0
local function check(ok, name, detail)
  if not ok then fails = fails + 1 end
  print(string.format("  %s  %-58s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- One rendered frame, with the play cursor a step further along.
local function frame()
  buttons, texts, checkboxes, inputs = {}, {}, {}, {}
  armed = false
  play_pos = play_pos + PLAY_STEP
  local ok, err = pcall(deferred)
  if not ok then error(err) end
  return armed
end

print("\nsteelblue_bpm.lua in both hosts -- the window, the header block, the popup:\n")

-- ------------------------------------------------------------- single script
-- (a) the window it has always had, and (g) the accessor handed back on close

do
  -- No hook here on purpose: the single script publishes it and RETURNS -- it
  -- is how the five BPM suites get the DSP without a window. This scenario
  -- wants the window.
  BPM_ANALYZER_TEST = nil
  reaper = build_reaper()
  local ok, err = pcall(dofile, folder .. "Live BPM Analyzer.lua")
  if not ok then
    check(false, "a) the single script loads", tostring(err))
  else
    frame()

    check(drew("Precision analyze") and drew("Live update") and drew("Analyze now")
      and drew("Half") and drew("Double") and drew("Set project tempo") and drew("Clear"),
      "a1) its own window draws all seven controls", "")
    check(drew("--.--") and drew("BPM"),
      "a2) with the big read-out above them", "")
    check(drew_starting_with("Source"),
      "a3) and the Source line from 1.1.3", "")
    check(not drew(MORE) and not drew("Close"),
      "a4) and nothing from the workspace layout", "")

    -- four more frames: the second one onwards has new audio to read
    for _ = 1, 4 do frame() end

    check(accessors_created == 1 and accessor_reads > 0,
      "g1) the live path made one accessor and read through it",
      accessors_created .. " accessor(s), " .. accessor_reads .. " reads")
    check(accessors_destroyed == 0,
      "g2) and holds on to it while the window is open", accessors_destroyed .. " destroyed")

    begin_open = false
    local again = frame()

    check(not again, "g3) the window closes", "")
    check(accessors_destroyed == 1,
      "g4) and release() hands the accessor back", accessors_destroyed .. " destroyed")
  end
end

-- ------------------------------------------------------------- workspace
-- (b) the header block, (c) the popup, (a2) Source in it, (d) a button in it

do
  BPM_ANALYZER_TEST = {}
  reaper = build_reaper({ active_tab = "rename" })
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "b) the workspace loads", tostring(err))
  else
    local T = BPM_ANALYZER_TEST

    frame()

    check(drew("LIVE BPM") and drew("--.--") and drew("Precision analyze") and drew(MORE),
      "b1) the header band draws the compact block", "")
    check(not drew("Set project tempo") and not drew("Analyze now") and not drew("Close"),
      "b2) and nothing that belongs in the popup", "")
    check(drew("Rename selected markers"),
      "b3) the rename tab is drawn as before", "")

    click_label = MORE
    frame()
    click_label = nil
    frame()

    check(drew("Set project tempo") and drew("Analyze now") and drew("Half")
      and drew("Double") and drew("Clear") and drew("Close"),
      "c1) clicking >>> opens the popup with the rest of the analyzer", "")
    check(drew_starting_with("Source"),
      "c2) and the Source line is in there", "")
    check(drew_starting_with("Last analysis"),
      "c3) together with what the last pass cost", "")
    check(drew("Min BPM") and drew("Max BPM") and drew("Window seconds"),
      "c4) and the range fields", "")

    -- a value to halve, set the way the analyzer would have set it
    T.apply_estimate(128, 0.9)
    check(T.get_display_state().current_bpm == 128,
      "d1) the panel shows a tempo", tostring(T.get_display_state().current_bpm))

    click_label = "Half"
    frame()
    click_label = nil

    check(T.get_display_state().current_bpm == 64,
      "d2) Half in the popup halves it", tostring(T.get_display_state().current_bpm))

    click_label = "Close"
    frame()
    click_label = nil
    frame()

    check(not drew("Set project tempo") and not drew("Close"),
      "c5) Close shuts the popup again", "")
    check(drew("Precision analyze") and drew(MORE),
      "c6) and the header block stays", "")
  end
end

-- ------------------------------------------------------------ another tab
-- (e) the live path runs behind a tab that is not the analyzer's, and
-- (f) the switch in the header really stops it

do
  BPM_ANALYZER_TEST = {}
  reaper = build_reaper({ active_tab = "copy" })
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  if not ok then
    check(false, "e) the workspace loads on the copy tab", tostring(err))
  else
    local T = BPM_ANALYZER_TEST

    for _ = 1, 5 do frame() end

    check(drew("Copy to cursor"), "e1) the copy tab is the one on screen", "")
    check(drew("Precision analyze"),
      "e2) and the BPM block is still in the header", "")
    check(accessor_reads > 0,
      "e3) the analyzer kept reading audio behind it", accessor_reads .. " reads")

    -- the switch off: the analysis stops, the read-out does not disappear
    checkbox_force = { ["##live_bpm"] = false }
    frame()
    check(T.get_display_state().live_update == false,
      "f1) the switch in the header turns the analysis off", "")

    local before = accessor_reads
    for _ = 1, 5 do frame() end

    check(accessor_reads == before,
      "f2) and no audio is read any more",
      before .. " -> " .. accessor_reads .. " reads")
    check(drew("LIVE BPM") and drew("BPM"),
      "f3) while the read-out stays on screen", "")
  end
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
