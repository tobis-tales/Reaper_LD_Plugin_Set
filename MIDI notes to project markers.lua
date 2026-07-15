-- MIDI notes to project markers
-- Creates project markers at MIDI note start positions in selected MIDI items.
-- The user can choose all MIDI items in the project or only selected MIDI items.
-- Looped MIDI items are followed across the visible item length.

local SCRIPT_TITLE = "MIDI notes to project markers"

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local EPSILON = 0.000000001
local MARKER_WARNING_THRESHOLD = 2000
local PREFLIGHT_COUNT_CAP = 50000
local run_with_scope
local marker_colors = {}
local use_ma_tools_syntax = true

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

local function load_module(name)
  local chunk = loadfile(folder .. name)
  if not chunk then
    reaper.ShowMessageBox(
      name .. " is missing next to this script.\n\n" ..
      "Please copy the whole steelblue package into the same folder.",
      SCRIPT_TITLE,
      0
    )
    return nil
  end

  return chunk()
end

math.randomseed(math.floor((reaper.time_precise and reaper.time_precise() or os.time()) * 1000000) % 2147483647)

local function choose_scope_fallback()
  local result = reaper.ShowMessageBox(
    "Create markers from all MIDI notes, or only from selected MIDI items?\n\n" ..
    "Yes = all MIDI items in the project\n" ..
    "No = only the selected MIDI items\n" ..
    "Cancel = do nothing",
    SCRIPT_TITLE,
    3
  )

  if result ~= 6 and result ~= 7 then
    return nil
  end

  local ma_result = reaper.ShowMessageBox(
    "Name the markers in MA-Tools syntax?\n\n" ..
    "Yes = NAME(1)[Top]^NAME^\n" ..
    "No = plain note names",
    SCRIPT_TITLE,
    4
  )
  use_ma_tools_syntax = ma_result == 6

  return result == 6 and "all" or "selected"
end

local function destroy_imgui_context(ctx)
  if ctx and reaper.APIExists and reaper.APIExists("ImGui_DestroyContext") then
    reaper.ImGui_DestroyContext(ctx)
  end
end

local function choose_scope()
  if not (reaper.APIExists and reaper.APIExists("ImGui_CreateContext")) then
    return choose_scope_fallback()
  end

  local SB = load_module("steelblue_ui.lua")
  if not SB then
    return nil
  end

  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)
  local choice = nil

  local function loop()
    local close_window = false
    local selected_count = reaper.CountSelectedMediaItems(0)

    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 460)

    if visible then
      SB.section(ctx, "Naming")

      local _
      _, use_ma_tools_syntax = reaper.ImGui_Checkbox(ctx, "MA-Tools syntax", use_ma_tools_syntax)
      SB.label(ctx, use_ma_tools_syntax and "Example: C4(1)[Top]^C4^" or "Example: C4")

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Which MIDI items?")

      if SB.primary_button(ctx, "All MIDI items in the project", 430, 32) then
        choice = "all"
        close_window = true
      end

      if SB.button(ctx, "Only selected MIDI items", 430, 32) then
        choice = "selected"
        close_window = true
      end

      SB.label(ctx, selected_count == 1
        and "1 item currently selected"
        or (tostring(selected_count) .. " items currently selected"))

      reaper.ImGui_Separator(ctx)

      if SB.button(ctx, "Cancel", 120) then
        choice = nil
        close_window = true
      end

      SB.footer(ctx, "Markers are placed at every MIDI note start.")
    end

    SB.end_window(ctx, visible, font)

    if open and not close_window then
      reaper.defer(loop)
    else
      destroy_imgui_context(ctx)
      if choice then
        run_with_scope(choice)
      end
    end
  end

  reaper.defer(loop)
  return "deferred"
end

local function default_note_name(pitch)
  local octave = math.floor(pitch / 12) - 1 -- MIDI note 60 = C4
  return NOTE_NAMES[(pitch % 12) + 1] .. tostring(octave)
end

local function get_note_name(take, pitch, channel)
  local item = reaper.GetMediaItemTake_Item(take)
  local track = item and reaper.GetMediaItem_Track(item)

  if track and reaper.GetTrackMIDINoteNameEx then
    local custom_name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, channel)
    if custom_name and custom_name ~= "" then
      return custom_name
    end
  end

  return default_note_name(pitch)
end

local function format_marker_name(note_name)
  if use_ma_tools_syntax then
    return note_name .. "(1)[Top]^" .. note_name .. "^"
  end

  return note_name
end

local function get_marker_color(marker_name)
  if not marker_colors[marker_name] then
    local red = math.random(70, 235)
    local green = math.random(70, 235)
    local blue = math.random(70, 235)

    marker_colors[marker_name] = reaper.ColorToNative(red, green, blue) + 0x1000000
  end

  return marker_colors[marker_name]
end

local function collect_selected_midi_takes()
  local takes = {}
  local selected_item_count = reaper.CountSelectedMediaItems(0)

  for item_index = 0, selected_item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, item_index)
    local take = item and reaper.GetActiveTake(item)

    if take and reaper.TakeIsMIDI(take) then
      takes[#takes + 1] = take
    end
  end

  return takes
end

local function collect_all_midi_takes()
  local takes = {}
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    local item_count = reaper.CountTrackMediaItems(track)

    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(track, item_index)
      local take = item and reaper.GetActiveTake(item)

      if take and reaper.TakeIsMIDI(take) then
        takes[#takes + 1] = take
      end
    end
  end

  return takes
end

local function get_source_length_ppq(take)
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil
  end

  local source_length, length_is_qn = reaper.GetMediaSourceLength(source)
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then
    playrate = 1
  end

  if length_is_qn then
    local source_start_qn = reaper.MIDI_GetProjQNFromPPQPos(take, 0)
    local one_qn_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, source_start_qn + 1)

    return math.floor((source_length * one_qn_ppq / playrate) + 0.5)
  end

  local source_start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
  return math.floor(
    reaper.MIDI_GetPPQPosFromProjTime(take, source_start_time + (source_length / playrate)) + 0.5
  )
end

local function add_marker(marker_pos, marker_name, marker_color, item_start, item_end, should_create)
  if marker_pos >= item_start - EPSILON and marker_pos < item_end - EPSILON then
    if should_create then
      reaper.AddProjectMarker2(0, false, marker_pos, 0, marker_name, -1, marker_color or 0)
    end

    return 1
  end

  return 0
end

local function add_markers_for_note(take, start_ppq, marker_name, marker_color, should_create, max_count)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local loops_source = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") > 0.5
  local created_count = 0

  if not loops_source then
    local marker_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
    return add_marker(marker_pos, marker_name, marker_color, item_start, item_end, should_create)
  end

  local source_length_ppq = get_source_length_ppq(take)
  if not source_length_ppq or source_length_ppq <= 0 then
    local marker_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
    return add_marker(marker_pos, marker_name, marker_color, item_start, item_end, should_create)
  end

  local first_visible_ppq = math.ceil(reaper.MIDI_GetPPQPosFromProjTime(take, item_start))
  local last_visible_ppq = math.floor(reaper.MIDI_GetPPQPosFromProjTime(take, item_end))
  local loop_start_ppq = math.floor((first_visible_ppq - start_ppq) / source_length_ppq) * source_length_ppq
  local note_ppq = start_ppq + loop_start_ppq

  while note_ppq < first_visible_ppq do
    note_ppq = note_ppq + source_length_ppq
  end

  while note_ppq <= last_visible_ppq do
    local marker_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, note_ppq)
    created_count = created_count + add_marker(
      marker_pos,
      marker_name,
      marker_color,
      item_start,
      item_end,
      should_create
    )
    if max_count and created_count >= max_count then
      return created_count
    end

    note_ppq = note_ppq + source_length_ppq
  end

  return created_count
end

local function create_markers(takes, should_create, max_count)
  local created_count = 0

  for _, take in ipairs(takes) do
    local _, note_count = reaper.MIDI_CountEvts(take)

    for note_index = 0, note_count - 1 do
      local ok, selected, muted, start_ppq, end_ppq, channel, pitch = reaper.MIDI_GetNote(take, note_index)

      if ok then
        local note_name = should_create and get_note_name(take, pitch, channel) or ""
        local marker_name = should_create and format_marker_name(note_name) or ""
        local marker_color = should_create and get_marker_color(note_name) or 0
        local remaining_count = max_count and (max_count - created_count) or nil
        created_count = created_count + add_markers_for_note(
          take,
          start_ppq,
          marker_name,
          marker_color,
          should_create,
          remaining_count
        )

        if max_count and created_count >= max_count then
          return created_count
        end
      end
    end
  end

  return created_count
end

run_with_scope = function(scope)
  local takes
  if scope == "all" then
    takes = collect_all_midi_takes()
  else
    takes = collect_selected_midi_takes()
  end

  if #takes == 0 then
    if scope == "selected" then
      reaper.ShowMessageBox(
        "No MIDI items are selected.\n\nSelect the MIDI items you want and run the script again.",
        SCRIPT_TITLE,
        0
      )
    else
      reaper.ShowMessageBox("No MIDI items found in this project.", SCRIPT_TITLE, 0)
    end

    return
  end

  local planned_count = create_markers(takes, false, PREFLIGHT_COUNT_CAP)

  if planned_count == 0 then
    reaper.ShowMessageBox("No visible MIDI notes found.", SCRIPT_TITLE, 0)
    return
  end

  if planned_count >= MARKER_WARNING_THRESHOLD then
    local planned_text = tostring(planned_count)
    if planned_count >= PREFLIGHT_COUNT_CAP then
      planned_text = "at least " .. planned_text
    end

    local confirm = reaper.ShowMessageBox(
      "This will create " .. planned_text .. " markers.\n\nContinue?",
      SCRIPT_TITLE,
      4
    )

    if confirm ~= 6 then
      return
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local created_count = create_markers(takes, true)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Create project markers from MIDI notes", -1)

  reaper.ShowMessageBox(
    tostring(created_count) .. " markers created.",
    SCRIPT_TITLE,
    0
  )
end

local scope = choose_scope()
if scope == "deferred" then
  return
end

if scope then
  run_with_scope(scope)
end
