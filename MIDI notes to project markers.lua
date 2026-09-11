-- MIDI notes to project markers
-- Creates project markers at MIDI note start positions in selected MIDI items.
-- The user can choose all MIDI items in the project or only selected MIDI items.
-- Looped MIDI items are followed across the visible item length.
--
-- Markers are grouped into one ruler lane per track basename: "Kick (12)" and
-- "Kick (13)" share the lane "Kick", one sequence and one ranking. That is what
-- the MA3 importer needs -- and the one case worth a warning, because it can no
-- longer tell the two tracks apart.

local SCRIPT_TITLE = "MIDI notes to project markers"

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local EPSILON = 0.000000001
local MARKER_WARNING_THRESHOLD = 2000
local PREFLIGHT_COUNT_CAP = 50000

-- For tracks the user never coloured. Picked by track index, so two uncoloured
-- tracks next to each other never come out the same.
local PALETTE = {
  { 70, 130, 180 }, { 219, 112, 147 }, { 60, 179, 113 }, { 255, 165, 0 },
  { 147, 112, 219 }, { 205, 92, 92 }, { 32, 178, 170 }, { 218, 165, 32 },
  { 100, 149, 237 }, { 188, 143, 143 }, { 154, 205, 50 }, { 255, 127, 80 },
}

local run_with_scope

local state = {
  use_ma_tools_syntax = true,
  command = "Top",
  replace_existing = true,
}

-- The commands offered in the Command list. The state keeps the TEXT, so
-- MA.format, the test hook and the fallback path work as before.
local COMMANDS = { "Go", "Top", "Flash" }

-- Items for ImGui_Combo (each one null-terminated) and the 0-based index of
-- the current command. A command outside the three (set by a test, say) is
-- shown as a fourth entry for as long as it is active; choosing one of the
-- three drops it.
local function command_choices(current)
  local items = {}
  local index

  for i, name in ipairs(COMMANDS) do
    items[i] = name
    if name == current then
      index = i - 1
    end
  end

  if index == nil then
    items[#items + 1] = current
    index = #items - 1
  end

  return table.concat(items, "\0") .. "\0", index, items
end

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

-- The only loader code left inline: something has to load the loader. The rest
-- was copied word for word into all four plugins and now lives in
-- steelblue_boot.lua.
local boot_chunk = loadfile(folder .. "steelblue_boot.lua")
if not boot_chunk then
  reaper.ShowMessageBox(
    "steelblue_boot.lua is missing next to this script.\n\n" ..
    "Please copy the whole steelblue package into the same folder.",
    SCRIPT_TITLE,
    0
  )
  return
end

local BOOT = boot_chunk()

local function load_module(name)
  return BOOT.load_module(folder, name, SCRIPT_TITLE)
end

local MARKERS = load_module("steelblue_markers.lua")
local MA = load_module("steelblue_matools.lua")
if not MARKERS or not MA then
  return
end

-- ------------------------------------------------------------------ tracks

-- Colours always go through ColorToNative: the byte order is platform
-- dependent. The high bit is what tells REAPER the colour is set at all.
local function palette_colour(index)
  local rgb = PALETTE[(index % #PALETTE) + 1]
  return math.floor(reaper.ColorToNative(rgb[1], rgb[2], rgb[3])) | 0x1000000
end

-- GetTrackColor answers 0 for "this track has no colour of its own"; anything
-- else already carries the high bit.
local function group_colour(track, index)
  local colour = track and reaper.GetTrackColor(track) or 0
  if colour ~= 0 then
    return math.floor(colour)
  end

  return palette_colour(index)
end

local function track_name(track)
  if not track then
    return ""
  end

  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name or ""
end

local function track_index(track)
  if not track then
    return 0
  end

  return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") + 0.5) - 1
end

-- An unnamed track reads as "" through P_NAME, and an empty lane name would
-- match the nameless lanes every project already has -- including the one
-- "replace existing markers" then empties. REAPER shows such a track as
-- "Track 3"; so does this.
local function display_name(track)
  local name = track_name(track)
  if name ~= "" then
    return name
  end

  return "Track " .. tostring(track_index(track) + 1)
end

local function take_track(take)
  local item = reaper.GetMediaItemTake_Item(take)
  return item and reaper.GetMediaItem_Track(item) or nil
end

-- ------------------------------------------------------------------- notes

local function default_note_name(pitch)
  local octave = math.floor(pitch / 12) - 1 -- MIDI note 60 = C4
  return NOTE_NAMES[(pitch % 12) + 1] .. tostring(octave)
end

local function get_note_name(take, pitch, channel)
  local track = take_track(take)

  if track and reaper.GetTrackMIDINoteNameEx then
    local custom_name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, channel)
    if custom_name and custom_name ~= "" then
      return custom_name
    end
  end

  return default_note_name(pitch)
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

  for index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, index)
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

-- A note only earns a marker where the item actually shows it: a loop can carry
-- the note past the end of the item. `place` nil counts without creating, which
-- is what the preflight needs.
local function place_marker(marker_pos, item_start, item_end, place)
  if marker_pos >= item_start - EPSILON and marker_pos < item_end - EPSILON then
    if place then
      place(marker_pos)
    end

    return 1
  end

  return 0
end

local function add_markers_for_note(take, start_ppq, max_count, place)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local loops_source = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") > 0.5
  local created_count = 0

  if not loops_source then
    local marker_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
    return place_marker(marker_pos, item_start, item_end, place)
  end

  local source_length_ppq = get_source_length_ppq(take)
  if not source_length_ppq or source_length_ppq <= 0 then
    local marker_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
    return place_marker(marker_pos, item_start, item_end, place)
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
    created_count = created_count + place_marker(marker_pos, item_start, item_end, place)

    if max_count and created_count >= max_count then
      return created_count
    end

    note_ppq = note_ppq + source_length_ppq
  end

  return created_count
end

-- ------------------------------------------------------------------ groups

local function has_track(group, name)
  for _, known in ipairs(group.tracks) do
    if known == name then
      return true
    end
  end

  return false
end

-- Groups the takes by track BASENAME, ranks the pitches inside each group, and
-- reports the groups that ended up holding more than one track.
--
-- The cue number is the RANK of the pitch, not the pitch: five C1 hits are five
-- markers on cue 1. A custom note name stays the cue name, but the rank still
-- follows the pitch.
local function plan_groups(takes)
  local groups = {}
  local by_basename = {}

  for _, take in ipairs(takes) do
    local track = take_track(take)
    local name = display_name(track)
    local basename = MA.track_basename(name) or name

    local group = by_basename[basename]
    if not group then
      group = {
        basename = basename,
        tracks = {},
        colour = group_colour(track, track_index(track)),
        track_index = track_index(track),
        takes = {},
        pitches = {},
        notes = {},
      }
      by_basename[basename] = group
      groups[#groups + 1] = group
    end

    if not has_track(group, name) then
      group.tracks[#group.tracks + 1] = name
    end

    group.takes[#group.takes + 1] = take

    local _, note_count = reaper.MIDI_CountEvts(take)

    for note_index = 0, note_count - 1 do
      local ok, _, _, start_ppq, _, channel, pitch = reaper.MIDI_GetNote(take, note_index)

      if ok then
        group.notes[#group.notes + 1] = {
          take = take,
          start_ppq = start_ppq,
          pitch = pitch,
          channel = channel,
          note_name = get_note_name(take, pitch, channel),
        }
        group.pitches[pitch] = true
      end
    end
  end

  for _, group in ipairs(groups) do
    local pitches = {}
    for pitch in pairs(group.pitches) do
      pitches[#pitches + 1] = pitch
    end
    table.sort(pitches)

    for rank, pitch in ipairs(pitches) do
      group.pitches[pitch] = rank
    end
  end

  local collisions = {}
  for _, group in ipairs(groups) do
    if #group.tracks > 1 then
      collisions[#collisions + 1] = group
    end
  end

  return groups, collisions
end

local function marker_name(group, note)
  if not state.use_ma_tools_syntax then
    return note.note_name
  end

  return MA.format({
    cue = note.note_name,
    number = group.pitches[note.pitch],
    command = state.command,
    sequence = group.basename,
  })
end

-- What the run would create, without creating it. Capped, because a project
-- with long looped items can plan more markers than anyone wants to wait for.
local function count_markers(groups, max_count)
  local total = 0

  for _, group in ipairs(groups) do
    for _, note in ipairs(group.notes) do
      local remaining = max_count and (max_count - total) or nil
      total = total + add_markers_for_note(note.take, note.start_ppq, remaining, nil)

      if max_count and total >= max_count then
        return total
      end
    end
  end

  return total
end

-- Creates the markers. An existing lane keeps its own colour -- the user may
-- have picked it -- but the markers always carry the track colour, because that
-- is the one MA-Tools reads back out of the .RPP.
local function execute(groups)
  local result = { created = 0, lanes = 0, replaced = 0, failed_lanes = {} }
  local lanes_on = MARKERS.lanes_available()

  for _, group in ipairs(groups) do
    local lane
    if lanes_on then
      lane = MARKERS.ensure_lane(group.basename, group.colour)

      if lane then
        result.lanes = result.lanes + 1
      else
        result.failed_lanes[#result.failed_lanes + 1] = group.basename
      end
    end

    if lane and state.replace_existing then
      for _, entry in ipairs(MARKERS.markers_in_lane(lane)) do
        if MARKERS.delete_marker(entry) then
          result.replaced = result.replaced + 1
        end
      end
    end

    for _, note in ipairs(group.notes) do
      local name = marker_name(group, note)

      add_markers_for_note(note.take, note.start_ppq, nil, function(pos)
        if MARKERS.add_marker(pos, name, group.colour, lane) then
          result.created = result.created + 1
        end
      end)
    end
  end

  return result
end

-- ---------------------------------------------------------------- messages

local function collision_text(collisions)
  local blocks = {}

  for _, group in ipairs(collisions) do
    blocks[#blocks + 1] = "These tracks share the name '" .. group.basename .. "':\n" ..
      table.concat(group.tracks, "\n")
  end

  return table.concat(blocks, "\n\n") ..
    "\n\nTheir markers would share one ruler lane and one sequence, and the MA3 " ..
    "importer could not tell them apart.\n\nContinue anyway?"
end

local function completion_text(result)
  local text

  if result.lanes > 0 then
    text = tostring(result.created) .. " markers created in " .. tostring(result.lanes) .. " lanes"

    if result.replaced > 0 then
      text = text .. " (" .. tostring(result.replaced) .. " replaced)"
    end

    text = text .. "."
  else
    text = tostring(result.created) .. " markers created."
  end

  if #result.failed_lanes > 0 then
    text = text .. "\n\nCould not create a ruler lane for: " ..
      table.concat(result.failed_lanes, ", ") .. "."
  end

  return text
end

-- -------------------------------------------------------------------- run

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

  local groups, collisions = plan_groups(takes)

  if #collisions > 0 then
    if reaper.ShowMessageBox(collision_text(collisions), SCRIPT_TITLE, 4) ~= 6 then
      return
    end
  end

  local planned_count = count_markers(groups, PREFLIGHT_COUNT_CAP)

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

  -- creating the lanes, emptying them and filling them again is one step for
  -- the user, so it is one undo point
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local result = execute(groups)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateTimeline()
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Create project markers from MIDI notes", -1)

  reaper.ShowMessageBox(completion_text(result), SCRIPT_TITLE, 0)
end

-- --------------------------------------------------------------------- ui

-- The example goes through the same formatter the markers do, so whatever the
-- user types into Command shows up here.
local function example_name()
  if not state.use_ma_tools_syntax then
    return "C4"
  end

  return MA.format({ cue = "C4", number = 1, command = state.command, sequence = "Kick" })
end

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
    "Yes = C4(1)[Top]^Kick^\n" ..
    "No = plain note names",
    SCRIPT_TITLE,
    4
  )
  state.use_ma_tools_syntax = ma_result == 6

  -- there is no command list here, so it stays the default ("Top")
  if MARKERS.lanes_available() then
    local replace = reaper.ShowMessageBox(
      "Replace existing markers in these lanes?",
      SCRIPT_TITLE,
      4
    )
    state.replace_existing = replace == 6
  end

  return result == 6 and "all" or "selected"
end

local function choose_scope()
  if not BOOT.has_imgui() then
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
    local lanes_on = MARKERS.lanes_available()

    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 460)

    if visible then
      local _

      SB.section(ctx, "Naming")

      _, state.use_ma_tools_syntax = reaper.ImGui_Checkbox(ctx, "MA-Tools syntax", state.use_ma_tools_syntax)
      SB.label(ctx, "Example: " .. example_name())

      if state.use_ma_tools_syntax then
        local command_items, command_index, command_list = command_choices(state.command)
        reaper.ImGui_SetNextItemWidth(ctx, 120)
        local command_changed, chosen = reaper.ImGui_Combo(ctx, "Command", command_index, command_items)
        if command_changed and command_list[chosen + 1] then
          state.command = command_list[chosen + 1]
        end
      end

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Ruler lanes")

      if lanes_on then
        SB.label(ctx, "One lane per track, named after the track: 'Kick (12)' becomes lane 'Kick'.")
        _, state.replace_existing = reaper.ImGui_Checkbox(
          ctx,
          "Replace existing markers in these lanes",
          state.replace_existing
        )
      else
        reaper.ImGui_TextColored(
          ctx,
          SB.color.text_muted,
          "No ruler lanes in this REAPER (needs 7.72+) - colours and names only."
        )
      end

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
      BOOT.destroy_context(ctx)
      if choice then
        run_with_scope(choice)
      end
    end
  end

  reaper.defer(loop)
  return "deferred"
end

-- Test hook: lets the grouping, naming and lane logic run outside REAPER.
local TEST_HOOK = rawget(_G, "MIDI_TEST")
if TEST_HOOK then
  TEST_HOOK.state = state
  TEST_HOOK.COMMANDS = COMMANDS
  TEST_HOOK.command_choices = command_choices
  TEST_HOOK.PALETTE = PALETTE
  TEST_HOOK.palette_colour = palette_colour
  TEST_HOOK.group_colour = group_colour
  TEST_HOOK.plan_groups = plan_groups
  TEST_HOOK.marker_name = marker_name
  TEST_HOOK.count_markers = count_markers
  TEST_HOOK.execute = execute
  TEST_HOOK.run_with_scope = run_with_scope
  TEST_HOOK.collect_all_midi_takes = collect_all_midi_takes
  TEST_HOOK.collect_selected_midi_takes = collect_selected_midi_takes
  return
end

-- ReaImGui is optional here: without it the window becomes the plain dialogs
-- above, which is a downgrade worth hearing about once.
BOOT.check_dependencies({
  title = SCRIPT_TITLE,
  imgui = "optional",
  imgui_cost = "the window is a plain dialog.",
})

local scope = choose_scope()
if scope == "deferred" then
  return
end

if scope then
  run_with_scope(scope)
end
