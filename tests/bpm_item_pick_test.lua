-- Which item the Live BPM Analyzer listens to.
--
-- Tobi found this the hard way on 2026-09-13: a SMPTE/LTC track lying over the
-- whole song won on track order, and the analyzer happily reported the square
-- wave's period as a tempo -- clean, confident, meaningless. The old picker took
-- the first selected item, otherwise the FIRST audio item under the cursor in
-- track order, with no idea what it was looking at and no word in the window
-- about which item it had chosen.
--
-- So this drives the real pick_audio_item through a fake REAPER project: tracks
-- with names and selection, items with position/length/selection/take name/
-- notes. Every scenario checks the item AND the "Source" line the window shows,
-- because a correct pick that is described wrongly is still a bug report.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

-- ---------------------------------------------------------------- fake REAPER

-- A project is { tracks = { { name=, selected=, items = { {...}, ... } } } }.
-- An item is { pos=, len=, selected=, take=, notes=, midi=, no_take= }.
local project = { tracks = {} }
local cursor = { playing = false, play_pos = 0, edit_pos = 0 }

-- Items and takes are the identity the picker compares, so they have to be
-- stable tables -- rebuilt once per scenario, never per call.
local function load_project(tracks)
  project.tracks = tracks
  for track_index, track in ipairs(tracks) do
    track.number = track_index
    for _, item in ipairs(track.items or {}) do
      item.track = track
      item.take = (not item.no_take) and { name = item.take_name or "" } or nil
    end
  end
end

local function item_at(track_index, item_index)
  return project.tracks[track_index].items[item_index]
end

reaper = {
  CountTracks = function() return #project.tracks end,
  GetTrack = function(_, index) return project.tracks[index + 1] end,
  CountTrackMediaItems = function(track) return #(track.items or {}) end,
  GetTrackMediaItem = function(track, index) return track.items[index + 1] end,

  GetActiveTake = function(item) return item.take end,
  TakeIsMIDI = function(take) return take.midi == true end,
  GetTakeName = function(take) return take.name end,
  GetMediaItemTrack = function(item) return item.track end,

  GetMediaItemInfo_Value = function(item, key)
    if key == "D_POSITION" then return item.pos end
    if key == "D_LENGTH" then return item.len end
    if key == "B_UISEL" then return item.selected and 1 or 0 end
    return 0
  end,

  GetMediaTrackInfo_Value = function(track, key)
    if key == "I_SELECTED" then return track.selected and 1 or 0 end
    if key == "IP_TRACKNUMBER" then return track.number end
    return 0
  end,

  GetTrackName = function(track)
    -- REAPER returns the default label for a track without a name.
    if track.name and track.name ~= "" then return true, track.name end
    return true, string.format("Track %d", track.number)
  end,

  GetSetMediaItemInfo_String = function(item, key, _, set)
    if set or key ~= "P_NOTES" then return false, "" end
    return true, item.notes or ""
  end,

  GetSelectedMediaItem = function(_, index)
    local seen = 0
    for _, track in ipairs(project.tracks) do
      for _, item in ipairs(track.items or {}) do
        if item.selected then
          if seen == index then return item end
          seen = seen + 1
        end
      end
    end
    return nil
  end,

  ValidatePtr2 = function() return true end,

  GetPlayState = function() return cursor.playing and 1 or 0 end,
  GetPlayPosition = function() return cursor.play_pos end,
  GetCursorPosition = function() return cursor.edit_pos end,

  time_precise = function() return os.clock() end,
  new_array = function() return { clear = function() end } end,
}

-- ------------------------------------------------------------------ the plugin

BPM_ANALYZER_TEST = {}
dofile(folder .. "Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST

-- --------------------------------------------------------------------- runner

local fails = 0
local function check(name, ok, note)
  if not ok then fails = fails + 1 end
  print(string.format("  %-5s %-52s %s", ok and "PASS" or "FAIL", name, note or ""))
end

-- Put the cursor somewhere and let the plugin choose, the way a call site does.
local function pick(previous)
  local item, take, err = T.pick_audio_item(previous)
  if item then
    T.set_current_item(item)
  end
  return item, take, err
end

local function where(item)
  if not item then return "nothing" end
  return string.format("track %d item \"%s\"",
    item.track.number, item.take and item.take.name or "-")
end

print("Live BPM Analyzer -- picking the item to analyze:\n")

-- (a) ------------------------------------------ LTC track above the song track
do
  load_project({
    { name = "LTC", items = { { pos = 0, len = 200, take_name = "ltc.wav" } } },
    { name = "Song", items = { { pos = 0, len = 200, take_name = "song.wav" } } },
  })
  cursor.playing = true
  cursor.play_pos = 30
  T.set_current_item(nil)

  local item = pick(nil)

  check("(a) LTC over the song, nothing selected -> the song",
    item == item_at(2, 1), where(item))
  check("(a) source names the song track",
    T.get_display_state().source_text == "Track 2 \"Song\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))
end

-- (b) -------------------------------------------- and even when LTC is selected
do
  load_project({
    { name = "LTC", items = { { pos = 0, len = 200, take_name = "ltc.wav", selected = true } } },
    { name = "Song", items = { { pos = 0, len = 200, take_name = "song.wav" } } },
  })
  cursor.playing = true
  cursor.play_pos = 30
  T.set_current_item(nil)

  local item = pick(nil)

  check("(b) selected LTC item still loses to the song",
    item == item_at(2, 1), where(item))
  check("(b) source names the song track",
    T.get_display_state().source_text == "Track 2 \"Song\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))
end

-- (c) ------------------------------------------------- the selected track wins
do
  local function two_plain_tracks(second_selected)
    load_project({
      { name = "", items = { { pos = 0, len = 200, take_name = "one.wav" } } },
      { name = "", selected = second_selected,
        items = { { pos = 0, len = 200, take_name = "two.wav" } } },
    })
    cursor.playing = false
    cursor.edit_pos = 30
    T.set_current_item(nil)
  end

  two_plain_tracks(true)
  local item = pick(nil)

  check("(c) both under the cursor, track 2 selected -> track 2",
    item == item_at(2, 1), where(item))
  check("(c) unnamed track is not quoted as \"Track 2\"",
    T.get_display_state().source_text == "Track 2 \u{00B7} two.wav",
    tostring(T.get_display_state().source_text))

  two_plain_tracks(false)
  item = pick(nil)

  check("(c) no track selected -> track 1, as before",
    item == item_at(1, 1), where(item))
  check("(c) source names track 1",
    T.get_display_state().source_text == "Track 1 \u{00B7} one.wav",
    tostring(T.get_display_state().source_text))
end

-- (d) --------------------------------------------------- a selection outranks
do
  load_project({
    { name = "Beds", items = { { pos = 0, len = 200, take_name = "bed.wav" } } },
    { name = "FX", items = {} },
    { name = "Song", items = { { pos = 300, len = 200, take_name = "song.wav", selected = true } } },
  })
  cursor.playing = true
  cursor.play_pos = 30
  T.set_current_item(nil)

  local item = pick(nil)

  check("(d) selected item off-cursor beats one under the cursor",
    item == item_at(3, 1), where(item))
  check("(d) source names track 3",
    T.get_display_state().source_text == "Track 3 \"Song\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))
end

-- (e) ------------------------------------------------------------- it sticks
do
  load_project({
    { name = "Ambience", items = { { pos = 0, len = 200, take_name = "amb.wav" } } },
    { name = "Song", items = { { pos = 0, len = 200, take_name = "song.wav" } } },
  })
  cursor.playing = true
  cursor.play_pos = 300
  T.set_current_item(nil)

  -- The song is what is being analyzed: cursor inside it, nothing else under it.
  local song = item_at(2, 1)
  song.pos = 250
  song.len = 200
  local item = pick(nil)
  check("(e) starts on the song item",
    item == song, where(item))

  -- Playback moves on and the cursor now also sweeps an item on track 1.
  song.pos = 0
  song.len = 400
  cursor.play_pos = 30
  item = pick(song)

  check("(e) cursor reaches a track 1 item -> the song stays",
    item == song, where(item))
  check("(e) source unchanged",
    T.get_display_state().source_text == "Track 2 \"Song\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))

  -- The user clicks the track 1 item: a fresh selection always wins.
  item_at(1, 1).selected = true
  item = pick(song)

  check("(e) the user selects the track 1 item -> it switches",
    item == item_at(1, 1), where(item))
  check("(e) source follows",
    T.get_display_state().source_text == "Track 1 \"Ambience\" \u{00B7} amb.wav",
    tostring(T.get_display_state().source_text))

  -- Selecting a TRACK is the user's doing too: the item under the cursor on
  -- that track outranks the one the analyzer was on (TT 54 clicks a track head).
  item_at(1, 1).selected = false
  item = pick(item_at(1, 1))
  check("(e) nothing selected -> stays on the track 1 item",
    item == item_at(1, 1), where(item))

  project.tracks[2].selected = true
  item = pick(item_at(1, 1))
  check("(e) the user selects track 2 -> it switches to the song",
    item == song, where(item))
  project.tracks[2].selected = false
end

-- (f) ------------------------------------------------- the only audio item
do
  load_project({
    { name = "Song", items = { { pos = 100, len = 200, take_name = "song.wav" } } },
  })
  cursor.playing = false
  cursor.edit_pos = 0
  T.set_current_item(nil)

  local item = pick(nil)

  check("(f) the only audio item is taken, cursor outside",
    item == item_at(1, 1), where(item))

  load_project({
    { name = "SMPTE", items = { { pos = 100, len = 200, take_name = "tc.wav" } } },
  })
  cursor.edit_pos = 0
  T.set_current_item(nil)

  item = pick(nil)
  T.apply_estimate(120.0, 0.9)
  local state = T.get_display_state()

  check("(f) the only item is taken even when it is timecode",
    item == item_at(1, 1), where(item))
  check("(f) but the status says what it looks like",
    state.status:find("looks like a timecode track", 1, true) ~= nil,
    state.status)
end

-- (g) ------------------------------------------------- looks_like_timecode
do
  local yes = { "LTC", "ltc out", "SMPTE 25", "Timecode", "time code", "MTC", "TC" }
  local no = { "Match", "etc", "Song", "" }

  for _, text in ipairs(yes) do
    check(string.format("(g) %-12s is timecode", "\"" .. text .. "\""),
      T.looks_like_timecode(text) == true)
  end

  for _, text in ipairs(no) do
    check(string.format("(g) %-12s is not", "\"" .. text .. "\""),
      T.looks_like_timecode(text) == false)
  end

  check("(g) a take name or a note is enough on its own",
    T.looks_like_timecode("Bed", "ltc.wav") == true
      and T.looks_like_timecode("Bed", "bed.wav", "LTC feed from the truck") == true
      and T.looks_like_timecode("Bed", "bed.wav", "the etc of it") == false)
end

-- (h) --------------------------------- a new item throws the old numbers away
do
  load_project({
    { name = "Song A", items = { { pos = 0, len = 200, take_name = "a.wav", selected = true } } },
    { name = "Song B", items = { { pos = 0, len = 200, take_name = "b.wav" } } },
  })
  cursor.playing = false
  cursor.edit_pos = 10
  T.set_current_item(nil)

  pick(nil)
  T.apply_estimate(128.0, 0.9)
  T.apply_estimate(128.2, 0.9)
  local filled = T.get_display_state()

  check("(h) analyzing fills history and the BPM",
    #filled.history == 2 and filled.current_bpm ~= nil,
    string.format("%d entries, bpm %s", #filled.history, tostring(filled.current_bpm)))

  item_at(1, 1).selected = false
  item_at(2, 1).selected = true
  T.start_pending_estimate_for_test()
  local item = pick(filled.current_item)
  local cleared = T.get_display_state()

  check("(h) switching item -> history empty, BPM gone",
    item == item_at(2, 1) and #cleared.history == 0 and cleared.current_bpm == nil
      and cleared.raw_bpm == nil and cleared.confidence == 0
      and cleared.pending_estimate == nil,
    string.format("%s, %d entries, bpm %s",
      where(item), #cleared.history, tostring(cleared.current_bpm)))
end

-- (i) ---------------------------------------- MIDI and empty items are not it
do
  load_project({
    { name = "Notes", items = { { pos = 0, len = 200, take_name = "notes", selected = true } } },
    { name = "Empty", items = { { pos = 0, len = 200, no_take = true, selected = true } } },
    { name = "Song", items = { { pos = 0, len = 200, take_name = "song.wav" } } },
  })
  item_at(1, 1).take.midi = true
  cursor.playing = false
  cursor.edit_pos = 10
  T.set_current_item(nil)

  local item = pick(nil)

  check("(i) a selected MIDI item and a takeless item are skipped",
    item == item_at(3, 1), where(item))

  -- Nothing else to fall back on: the old wording, unchanged.
  load_project({
    { name = "Notes", items = { { pos = 0, len = 200, take_name = "notes", selected = true } } },
  })
  item_at(1, 1).take.midi = true
  T.set_current_item(nil)

  local _, _, err = T.pick_audio_item(nil)
  check("(i) MIDI on its own still says so",
    err == "Selected item is MIDI. Please select the finished audio song item.",
    tostring(err))

  load_project({
    { name = "Empty", items = { { pos = 0, len = 200, no_take = true, selected = true } } },
  })
  T.set_current_item(nil)

  _, _, err = T.pick_audio_item(nil)
  check("(i) an item without a take still says so",
    err == "Selected item has no active take.", tostring(err))
end

-- (j) --------------------------- the Source line follows renames and track swaps
-- Tobi, TT 52 (2026-09-15): after swapping the TC and song tracks the line kept
-- saying "Track 2", and renaming the track changed nothing either. The item
-- pointer is the same item; only what is around it changed.
do
  load_project({
    { name = "LTC", items = { { pos = 0, len = 200, take_name = "tc.wav" } } },
    { name = "Song", items = { { pos = 0, len = 200, take_name = "song.wav" } } },
  })
  cursor.playing = true
  cursor.play_pos = 10
  T.set_current_item(nil)

  local song = item_at(2, 1)
  local item = pick(nil)
  check("(j) starts on Track 2 \"Song\"",
    item == song and T.get_display_state().source_text == "Track 2 \"Song\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))

  -- The user renames the track. Same item, same pick -- the line must follow.
  project.tracks[2].name = "Main mix"
  item = pick(song)
  check("(j) renaming the track renames the Source line",
    item == song and T.get_display_state().source_text == "Track 2 \"Main mix\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))

  -- The user swaps the two tracks: the song now lies on track 1.
  local ltc_track, song_track = project.tracks[1], project.tracks[2]
  project.tracks[1], project.tracks[2] = song_track, ltc_track
  song_track.number, ltc_track.number = 1, 2
  item = pick(song)
  check("(j) after a track swap it says Track 1, and stays on the song",
    item == song and T.get_display_state().source_text == "Track 1 \"Main mix\" \u{00B7} song.wav",
    tostring(T.get_display_state().source_text))

  -- and the smoothing was NOT thrown away for a mere relabel
  T.apply_estimate(120.0, 0.9)
  pick(song)
  check("(j) a relabel keeps the history",
    #T.get_display_state().history == 1, #T.get_display_state().history .. " entries")
end

-- error case ------------------------------------------------------------------
do
  load_project({
    { name = "A", items = { { pos = 0, len = 100, take_name = "a.wav" } } },
    { name = "B", items = { { pos = 0, len = 100, take_name = "b.wav" } } },
  })
  cursor.playing = false
  cursor.edit_pos = 500
  T.set_current_item(nil)

  local item, take, err = T.pick_audio_item(nil)

  check("nothing selected, nothing under the cursor, two items -> the ask",
    item == nil and take == nil
      and err == "Select the song item or place the play cursor inside it.",
    tostring(err))
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
