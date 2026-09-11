-- Run the real "MIDI notes to project markers.lua" against a fake REAPER, via
-- its MIDI_TEST hook: tracks with MIDI items, notes, ruler lanes and a message
-- box that answers whatever the scenario says.
--
-- Three things the fake does on purpose:
--   * a new lane is APPENDED. Verified in REAPER 7.79 (probe 3): a new lane
--     goes to the end and the existing ones keep their index and GUID. The
--     lane half of markers_test inserts at the front instead, which is the
--     right test for "find the new lane by GUID" but the wrong world for a
--     plugin that assigns markers to lane indexes it collected earlier.
--   * every number comes back as a FLOAT, as REAPER's do.
--   * a fresh project already has two nameless lanes (probe 2), so
--     lanes_available() is true before this plugin creates anything.
--
-- PPQ maps to project time linearly at 960 ppq per second, offset by the item
-- position -- ppq 0 is the start of the item.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

local PPQ_PER_SECOND = 960

local scenario = {}
local PROJECT = {}
local lanes = {}
local tracks = {}
local next_marker_id = 0
local calls = {}
local messages = {}

local function log(entry)
  calls[#calls + 1] = entry
end

local function count(kind)
  local total = 0
  for _, entry in ipairs(calls) do
    if entry.kind == kind then total = total + 1 end
  end
  return total
end

local function markers_named(name)
  local found = {}
  for _, entry in ipairs(PROJECT) do
    if not entry.is_region and entry.name == name then found[#found + 1] = entry end
  end
  return found
end

local function marker_names()
  local names = {}
  for _, entry in ipairs(PROJECT) do
    if not entry.is_region then names[#names + 1] = entry.name end
  end
  return names
end

local function marker_count()
  return #marker_names()
end

-- ---------------------------------------------------------------- the world

-- scenario.tracks: { name=, color=, note_names={ [pitch]="Boom" },
--                    items={ { pos=, length=, loop=, source_ppq=,
--                             notes={ {ppq=, pitch=, channel=} } } } }
local function build_world()
  tracks = {}
  PROJECT = {}
  lanes = {}
  calls = {}
  messages = {}
  next_marker_id = 0

  for index, spec in ipairs(scenario.tracks or {}) do
    local track = {
      name = spec.name,
      color = spec.color or 0,
      note_names = spec.note_names or {},
      number = index,
      items = {},
    }

    for _, item_spec in ipairs(spec.items or {}) do
      local item = {
        track = track,
        pos = item_spec.pos or 0.0,
        length = item_spec.length or 4.0,
        loop = item_spec.loop and 1.0 or 0.0,
        source_ppq = item_spec.source_ppq or (PPQ_PER_SECOND * 4),
      }
      item.take = { item = item, notes = item_spec.notes or {} }
      track.items[#track.items + 1] = item
    end

    tracks[#tracks + 1] = track
  end

  -- a fresh project already has these two
  for _, lane in ipairs(scenario.lanes or { { name = "" }, { name = "" } }) do
    lanes[#lanes + 1] = {
      name = lane.name or "",
      color = lane.color or 0,
      guid = lane.guid or ("{L" .. #lanes .. "}"),
    }
  end
end

local function lane_at(descriptor_index)
  return lanes[descriptor_index + 1]
end

local function build_reaper()
  local r = {}

  r.GetAppVersion = function() return scenario.version or "7.79/OSX64" end

  r.ShowMessageBox = function(text, _, kind)
    messages[#messages + 1] = { text = text, kind = kind }
    return scenario.answer or 6
  end

  r.ColorToNative = function(red, green, blue)
    return ((red << 16) | (green << 8) | blue) + 0.0
  end

  r.Undo_BeginBlock = function() end
  r.Undo_EndBlock = function() end
  r.PreventUIRefresh = function() end
  r.UpdateTimeline = function() end
  r.UpdateArrange = function() end

  -- tracks, items, takes
  r.CountTracks = function() return #tracks + 0.0 end
  r.GetTrack = function(_, index) return tracks[index + 1] end
  r.CountTrackMediaItems = function(track) return #track.items + 0.0 end
  r.GetTrackMediaItem = function(track, index) return track.items[index + 1] end
  r.GetActiveTake = function(item) return item.take end
  r.TakeIsMIDI = function() return true end
  r.GetMediaItemTake_Item = function(take) return take.item end
  r.GetMediaItem_Track = function(item) return item.track end

  r.CountSelectedMediaItems = function() return #(scenario.selected_items or {}) + 0.0 end
  r.GetSelectedMediaItem = function(_, index)
    local pick = (scenario.selected_items or {})[index + 1]
    if not pick then return nil end
    return tracks[pick[1]].items[pick[2]]
  end

  r.GetTrackColor = function(track) return track.color + 0.0 end

  r.GetSetMediaTrackInfo_String = function(track, param, _, is_set)
    if param ~= "P_NAME" or is_set then return false, "" end
    return true, track.name
  end

  r.GetMediaTrackInfo_Value = function(track, param)
    if param == "IP_TRACKNUMBER" then return track.number + 0.0 end
    return 0.0
  end

  r.GetMediaItemInfo_Value = function(item, param)
    if param == "D_POSITION" then return item.pos + 0.0 end
    if param == "D_LENGTH" then return item.length + 0.0 end
    if param == "B_LOOPSRC" then return item.loop + 0.0 end
    return 0.0
  end

  r.GetTrackMIDINoteNameEx = function(_, track, pitch)
    return track.note_names[pitch]
  end

  -- MIDI
  r.MIDI_CountEvts = function(take) return 0.0, #take.notes + 0.0, 0.0 end
  r.MIDI_GetNote = function(take, index)
    local note = take.notes[index + 1]
    if not note then return false end
    return true, false, false,
      (note.ppq or 0) + 0.0, (note.ppq or 0) + 120.0,
      (note.channel or 0) + 0.0, note.pitch + 0.0
  end
  r.MIDI_GetProjTimeFromPPQPos = function(take, ppq)
    return take.item.pos + (ppq / PPQ_PER_SECOND)
  end
  r.MIDI_GetPPQPosFromProjTime = function(take, time)
    return (time - take.item.pos) * PPQ_PER_SECOND
  end
  r.GetMediaItemTake_Source = function(take) return take end
  r.GetMediaSourceLength = function(take) return take.item.source_ppq / PPQ_PER_SECOND, false end
  r.GetMediaItemTakeInfo_Value = function() return 1.0 end

  -- markers
  r.EnumProjectMarkers3 = function(_, index)
    local e = PROJECT[index + 1]
    if not e then return 0 end
    return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
  end

  r.AddProjectMarker2 = function(_, isrgn, pos, rgnend, name, wantidx, color)
    next_marker_id = next_marker_id + 1
    PROJECT[#PROJECT + 1] = {
      is_region = isrgn, pos = pos, name = name, id = next_marker_id, color = color,
    }
    log({ kind = "add_project_marker2", pos = pos, name = name, color = color })
    return next_marker_id
  end

  r.DeleteProjectMarker = function(_, id, isrgn)
    log({ kind = "delete", id = id })
    for index, e in ipairs(PROJECT) do
      if e.id == id and e.is_region == isrgn then
        table.remove(PROJECT, index)
        return true
      end
    end
    return false
  end

  if scenario.lane_api ~= false then
    r.GetNumRegionsOrMarkers = function() return #PROJECT + 0.0 end
    r.GetRegionOrMarker = function(_, index, guid)
      if index < 0 then
        for _, e in ipairs(PROJECT) do
          if e.guid == guid then return e end
        end
        return nil
      end
      return PROJECT[index + 1]
    end
    r.GetRegionOrMarkerInfo_Value = function(_, e, param)
      if param == "B_ISREGION" then return e.is_region and 1.0 or 0.0 end
      if param == "I_NUMBER" then return e.id + 0.0 end
      if param == "I_LANENUMBER" then return (e.lane or 0) + 0.0 end
      if param == "I_CUSTOMCOLOR" then return (e.color or 0) + 0.0 end
      return 0.0
    end
    r.SetRegionOrMarkerInfo_Value = function(_, e, param, value)
      if param == "I_LANENUMBER" then
        e.lane = math.floor(value + 0.5)
        log({ kind = "set_lane", guid = e.guid, value = e.lane })
      end
      return 0.0
    end
    r.GetSetRegionOrMarkerInfo_String = function(_, e, param, str, is_set)
      if param == "GUID" and not is_set then return true, e.guid end
      if param == "P_NAME" then
        if is_set then e.name = str return true end
        return true, e.name
      end
      return false, ""
    end
    r.AddRegionOrMarker = function(_, isrgn, pos, rgnend, name, wantidx, color)
      next_marker_id = next_marker_id + 1
      local entry = {
        is_region = isrgn, pos = pos, name = name, id = next_marker_id,
        color = color, lane = 0, guid = "{M" .. next_marker_id .. "}",
      }
      PROJECT[#PROJECT + 1] = entry
      log({ kind = "add_region_or_marker", pos = pos, name = name, color = color })
      return entry
    end

    r.GetSetProjectInfo = function(_, desc, value, is_set)
      if desc == "RULER_LANE_COUNT" then
        return #lanes + 0.0
      end

      local order_position = desc:match("^RULER_LANE_ORDER:(-?%d+)$")
      if order_position and is_set then
        log({ kind = "lane_order", position = tonumber(order_position), value = value })
        if value == -1 and scenario.lane_create ~= false then
          -- REAPER 7.79 appends, and leaves the existing lanes where they are
          lanes[#lanes + 1] = { name = "", color = 0, guid = "{Lnew" .. #lanes .. "}" }
        end
        return tonumber(order_position) + 0.0
      end

      local param, index = desc:match("^RULER_LANE_(%u+):(-?%d+)$")
      if not param then return 0.0 end

      local lane = lane_at(tonumber(index))
      if not lane then return 0.0 end

      local key = param:lower()
      if is_set then
        lane[key] = value
        log({ kind = "lane_" .. key, index = tonumber(index), value = value })
        return value
      end

      return (tonumber(lane[key]) or 0) + 0.0
    end

    r.GetSetProjectInfo_String = function(_, desc, value, is_set)
      local param, index = desc:match("^RULER_LANE_(%u+):(-?%d+)$")
      if param ~= "NAME" and param ~= "GUID" then return false, "" end

      local lane = lane_at(tonumber(index))
      if not lane then return false, "" end

      if param == "GUID" then
        if is_set then return false, "" end
        return true, lane.guid
      end

      if is_set then
        lane.name = value
        log({ kind = "lane_name", index = tonumber(index), value = value })
        return true
      end

      return true, lane.name
    end
  end

  return r
end

-- ------------------------------------------------------------------- runner

local function load_plugin()
  build_world()
  reaper = build_reaper()

  local hook = {}
  rawset(_G, "MIDI_TEST", hook)
  dofile(folder .. "MIDI notes to project markers.lua")
  rawset(_G, "MIDI_TEST", nil)

  -- what the plugin itself starts with, before the scenario touches anything
  hook.loaded_defaults = {
    use_ma_tools_syntax = hook.state.use_ma_tools_syntax,
    command = hook.state.command,
    replace_existing = hook.state.replace_existing,
  }

  -- the state table lives in the plugin and survives between scenarios,
  -- so every run starts from the documented defaults
  hook.state.use_ma_tools_syntax = true
  hook.state.command = "Top"
  hook.state.replace_existing = true

  for key, value in pairs(scenario.state or {}) do
    hook.state[key] = value
  end

  return hook
end

local fails = 0

local function run(name, setup, check)
  scenario = setup
  local hook = load_plugin()
  local ok, detail = check(hook)
  print(string.format("%-46s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  if not ok then fails = fails + 1 end
end

local function names_equal(got, want)
  if #got ~= #want then
    return false, #got .. " markers: " .. table.concat(got, " ")
  end
  for index, value in ipairs(want) do
    if got[index] ~= value then
      return false, "marker " .. index .. " is " .. string.format("%q", got[index])
    end
  end
  return true
end

-- one track, four notes: C1 C2 C1 C3
local function kick_track(name, color)
  return {
    name = name or "Kick (12)",
    color = color or 0x10A141E,
    items = { { pos = 0.0, length = 4.0, notes = {
      { ppq = 0, pitch = 24 }, { ppq = 960, pitch = 36 },
      { ppq = 1920, pitch = 24 }, { ppq = 2880, pitch = 48 },
    } } },
  }
end

print("MIDI notes to project markers -- grouping, ranking, lanes:\n")

-- a) rank follows the pitch, and repeats keep their rank
run("a  pitch rank, not pitch, one group", {
  tracks = { kick_track() },
}, function(hook)
  local groups, collisions = hook.plan_groups(hook.collect_all_midi_takes())
  if #groups ~= 1 then return false, #groups .. " groups" end
  if #collisions ~= 0 then return false, "collision reported" end

  local group = groups[1]
  if group.basename ~= "Kick" then return false, "basename " .. group.basename end
  if group.pitches[24] ~= 1 or group.pitches[36] ~= 2 or group.pitches[48] ~= 3 then
    return false, "ranks " .. tostring(group.pitches[24]) .. "," ..
      tostring(group.pitches[36]) .. "," .. tostring(group.pitches[48])
  end

  hook.execute(groups)
  return names_equal(marker_names(), {
    "C1(1)[Top]^Kick^", "C2(2)[Top]^Kick^", "C1(1)[Top]^Kick^", "C3(3)[Top]^Kick^",
  })
end)

-- b) a custom note name becomes the cue name; the rank stays with the pitch
run("b  custom note name, rank still by pitch", {
  tracks = { {
    name = "Kick (12)", color = 0x10A141E,
    note_names = { [36] = "Boom" },
    items = { { pos = 0.0, length = 4.0, notes = {
      { ppq = 0, pitch = 36 }, { ppq = 960, pitch = 48 },
    } } },
  } },
}, function(hook)
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  hook.execute(groups)
  return names_equal(marker_names(), { "Boom(1)[Top]^Kick^", "C3(2)[Top]^Kick^" })
end)

-- c) the syntax is a choice, and an empty command drops its brackets
run("c  syntax off, and an empty command", {
  tracks = { kick_track() },
  state = { use_ma_tools_syntax = false },
}, function(hook)
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  local note = groups[1].notes[1]
  if hook.marker_name(groups[1], note) ~= "C1" then
    return false, "plain name is " .. hook.marker_name(groups[1], note)
  end

  hook.state.use_ma_tools_syntax = true
  hook.state.command = ""
  if hook.marker_name(groups[1], note) ~= "C1(1)^Kick^" then
    return false, "empty command gives " .. hook.marker_name(groups[1], note)
  end

  hook.state.command = "Top"
  return hook.marker_name(groups[1], groups[1].notes[2]) == "C2(2)[Top]^Kick^",
    "C1 / C1(1)^Kick^ / C2(2)[Top]^Kick^"
end)

-- d) two tracks, one basename: one lane, one ranking, and a warning first
run("d  same basename: one group, one warning", {
  tracks = {
    { name = "Kick (12)", color = 0x10A141E, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 0, pitch = 36 } } } } },
    { name = "Kick (13)", color = 0x1C80A0A, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 960, pitch = 24 } } } } },
  },
  answer = 7, -- No
}, function(hook)
  local groups, collisions = hook.plan_groups(hook.collect_all_midi_takes())
  if #groups ~= 1 then return false, #groups .. " groups" end
  if #collisions ~= 1 then return false, #collisions .. " collisions" end
  if #groups[1].tracks ~= 2 then return false, #groups[1].tracks .. " tracks in the group" end
  -- ranked across both tracks: pitch 24 from the second track is cue 1
  if groups[1].pitches[24] ~= 1 or groups[1].pitches[36] ~= 2 then
    return false, "ranks " .. tostring(groups[1].pitches[24]) .. "," .. tostring(groups[1].pitches[36])
  end

  hook.run_with_scope("all")

  if #messages == 0 then return false, "no warning shown" end
  local box = messages[1]
  if not box.text:find("These tracks share the name 'Kick'", 1, true) then
    return false, "wrong text: " .. box.text
  end
  if not box.text:find("Kick (12)", 1, true) or not box.text:find("Kick (13)", 1, true) then
    return false, "the box does not name both tracks"
  end
  if box.kind ~= 4 then return false, "box type " .. tostring(box.kind) end
  if marker_count() ~= 0 then return false, marker_count() .. " markers created after No" end
  return #messages == 1, "No: warned once, created nothing"
end)

run("d2 same basename, Yes: one lane for both", {
  tracks = {
    { name = "Kick (12)", color = 0x10A141E, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 0, pitch = 36 } } } } },
    { name = "Kick (13)", color = 0x1C80A0A, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 960, pitch = 24 } } } } },
  },
}, function(hook)
  hook.run_with_scope("all")

  if #lanes ~= 3 then return false, #lanes .. " lanes" end
  if lanes[3].name ~= "Kick" then return false, "lane named " .. lanes[3].name end
  -- the colour of the FIRST track of the group
  if lanes[3].color ~= 0x10A141E then return false, "lane colour " .. tostring(lanes[3].color) end

  local ok, detail = names_equal(marker_names(), { "C2(2)[Top]^Kick^", "C1(1)[Top]^Kick^" })
  if not ok then return false, detail end

  for _, entry in ipairs(PROJECT) do
    if entry.lane ~= 2 then return false, "a marker landed in lane " .. tostring(entry.lane) end
    if entry.color ~= 0x10A141E then return false, "marker colour " .. tostring(entry.color) end
  end
  return true, "one lane 'Kick', both tracks, ranked across both"
end)

-- e) different basenames: a lane each, in that track's colour
run("e  two tracks, two lanes, two colours", {
  tracks = {
    { name = "Kick", color = 0x10A141E, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 0, pitch = 36 } } } } },
    { name = "Snare", color = 0x1C80A0A, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 960, pitch = 38 } } } } },
  },
}, function(hook)
  local result = hook.execute((hook.plan_groups(hook.collect_all_midi_takes())))
  if result.lanes ~= 2 then return false, result.lanes .. " lanes reported" end
  if #lanes ~= 4 then return false, #lanes .. " lanes in the project" end
  if lanes[3].name ~= "Kick" or lanes[4].name ~= "Snare" then
    return false, "lanes " .. lanes[3].name .. "/" .. lanes[4].name
  end
  if lanes[3].color ~= 0x10A141E or lanes[4].color ~= 0x1C80A0A then
    return false, "lane colours " .. tostring(lanes[3].color) .. "/" .. tostring(lanes[4].color)
  end

  local kick = markers_named("C2(1)[Top]^Kick^")[1]
  local snare = markers_named("D2(1)[Top]^Snare^")[1]
  if not kick or not snare then return false, table.concat(marker_names(), " ") end
  if kick.lane ~= 2 or kick.color ~= 0x10A141E then
    return false, "kick marker lane " .. tostring(kick.lane) .. " colour " .. tostring(kick.color)
  end
  if snare.lane ~= 3 or snare.color ~= 0x1C80A0A then
    return false, "snare marker lane " .. tostring(snare.lane) .. " colour " .. tostring(snare.color)
  end
  return true, "lane 2 blue, lane 3 pink"
end)

-- f) no track colour: the palette, picked by track index
run("f  no track colour falls back to the palette", {
  tracks = {
    { name = "Kick", color = 0, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 0, pitch = 36 } } } } },
    { name = "Snare", color = 0, items = { { pos = 0.0, length = 4.0,
      notes = { { ppq = 0, pitch = 38 } } } } },
  },
}, function(hook)
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  -- track indexes 0 and 1 -> the first two palette entries
  if groups[1].colour ~= hook.palette_colour(0) then
    return false, "first group " .. string.format("%x", groups[1].colour)
  end
  if groups[2].colour ~= hook.palette_colour(1) then
    return false, "second group " .. string.format("%x", groups[2].colour)
  end
  if groups[1].colour == groups[2].colour then return false, "both got the same colour" end
  -- (70,130,180) is the first entry, and the high bit marks it as set
  if hook.palette_colour(0) ~= 0x14682B4 then
    return false, "palette 0 is " .. string.format("%x", hook.palette_colour(0))
  end
  -- and it wraps, so a project with 13 tracks still gets a colour
  return hook.palette_colour(#hook.PALETTE) == hook.palette_colour(0), "palette 0, palette 1, wraps"
end)

-- g) run twice with Replace on: same lane, the old markers gone
run("g  second run replaces what is in the lane", {
  tracks = { kick_track() },
}, function(hook)
  hook.run_with_scope("all")
  local first = marker_count()
  local lanes_after_first = #lanes

  local result = hook.execute((hook.plan_groups(hook.collect_all_midi_takes())))

  if #lanes ~= lanes_after_first then return false, "a second lane appeared" end
  if result.replaced ~= first then
    return false, "replaced " .. result.replaced .. " of " .. first
  end
  if marker_count() ~= first then
    return false, marker_count() .. " markers, expected " .. first
  end
  if count("delete") ~= first then return false, count("delete") .. " deletes" end
  return names_equal(marker_names(), {
    "C1(1)[Top]^Kick^", "C2(2)[Top]^Kick^", "C1(1)[Top]^Kick^", "C3(3)[Top]^Kick^",
  })
end)

-- h) the same run with Replace off doubles everything, on purpose
run("h  Replace off keeps the old markers", {
  tracks = { kick_track() },
  state = { replace_existing = false },
}, function(hook)
  hook.run_with_scope("all")
  local first = marker_count()

  local result = hook.execute((hook.plan_groups(hook.collect_all_midi_takes())))

  if result.replaced ~= 0 then return false, "replaced " .. result.replaced end
  if count("delete") ~= 0 then return false, count("delete") .. " deletes" end
  return marker_count() == first * 2, marker_count() .. " markers after two runs"
end)

-- i) a REAPER without the lane API: names and colours, and it says so
run("i  7.75: no lanes, no lane calls", {
  version = "7.75/OSX64",
  lane_api = false,
  tracks = { kick_track() },
}, function(hook)
  hook.run_with_scope("all")

  if count("add_project_marker2") ~= 4 then
    return false, count("add_project_marker2") .. " AddProjectMarker2 calls"
  end
  if count("add_region_or_marker") ~= 0 then return false, "used the 7.72 API" end
  if count("lane_order") ~= 0 or count("set_lane") ~= 0 then return false, "touched lanes" end

  local ok, detail = names_equal(marker_names(), {
    "C1(1)[Top]^Kick^", "C2(2)[Top]^Kick^", "C1(1)[Top]^Kick^", "C3(3)[Top]^Kick^",
  })
  if not ok then return false, detail end

  local last = messages[#messages]
  return last and last.text == "4 markers created.", "final box: " .. tostring(last and last.text)
end)

-- j) the lane could not be created: markers anyway, and the box says which
run("j  lane creation fails: markers anyway", {
  tracks = { kick_track() },
  lane_create = false,
}, function(hook)
  local result = hook.execute((hook.plan_groups(hook.collect_all_midi_takes())))

  if result.created ~= 4 then return false, result.created .. " markers" end
  if result.lanes ~= 0 then return false, result.lanes .. " lanes claimed" end
  if #result.failed_lanes ~= 1 or result.failed_lanes[1] ~= "Kick" then
    return false, "failed_lanes " .. table.concat(result.failed_lanes, ",")
  end

  build_world()
  hook.run_with_scope("all")
  local last = messages[#messages]
  if not last then return false, "no final box" end
  if not last.text:find("Could not create a ruler lane for: Kick.", 1, true) then
    return false, "final box: " .. last.text
  end
  return last.text:find("^4 markers created%.") ~= nil, "markers created, lane named as failed"
end)

-- k) a looped item repeats the note, and the loop logic still follows it
run("k  a looped item repeats the note", {
  tracks = { {
    name = "Kick", color = 0x10A141E,
    items = { { pos = 0.0, length = 8.0, loop = true, source_ppq = PPQ_PER_SECOND * 4,
      notes = { { ppq = 0, pitch = 36 } } } },
  } },
}, function(hook)
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  if #groups[1].notes ~= 1 then return false, #groups[1].notes .. " notes" end

  local result = hook.execute(groups)
  if result.created ~= 2 then return false, result.created .. " markers from one looped note" end

  local made = markers_named("C2(1)[Top]^Kick^")
  if #made ~= 2 then return false, #made .. " markers with that name" end
  return math.abs(made[1].pos - 0.0) < 0.001 and math.abs(made[2].pos - 4.0) < 0.001,
    "markers at " .. made[1].pos .. " and " .. made[2].pos
end)

-- l) the number in the warning is the number that gets created
run("l  the preflight count is the real count", {
  tracks = {
    kick_track(),
    { name = "Snare", color = 0, items = { { pos = 2.0, length = 8.0, loop = true,
      source_ppq = PPQ_PER_SECOND * 2, notes = { { ppq = 0, pitch = 38 } } } } },
  },
}, function(hook)
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  local planned = hook.count_markers(groups, 50000)
  if planned == 0 then return false, "planned nothing" end
  if marker_count() ~= 0 then return false, "the preflight created markers" end

  local result = hook.execute(groups)
  return result.created == planned, planned .. " planned, " .. result.created .. " created"
end)

-- m) the plugin starts with Top, and the Command list offers Go/Top/Flash
run("m  default command Top, list Go/Top/Flash", {
  tracks = { kick_track() },
}, function(hook)
  local d = hook.loaded_defaults
  if d.command ~= "Top" then return false, "default command " .. string.format("%q", d.command) end
  if not d.use_ma_tools_syntax then return false, "syntax off by default" end
  if not d.replace_existing then return false, "replace off by default" end

  if table.concat(hook.COMMANDS, "/") ~= "Go/Top/Flash" then
    return false, "list is " .. table.concat(hook.COMMANDS, "/")
  end

  local items, index, list = hook.command_choices("Top")
  if items ~= "Go\0Top\0Flash\0" then return false, "items " .. string.format("%q", items) end
  if index ~= 1 then return false, "Top is index " .. tostring(index) end
  if #list ~= 3 then return false, #list .. " entries for a standard command" end

  -- a command outside the three is shown as a fourth entry while it is active
  items, index, list = hook.command_choices("On")
  if items ~= "Go\0Top\0Flash\0On\0" then return false, "items " .. string.format("%q", items) end
  if index ~= 3 or list[4] ~= "On" then return false, "On is index " .. tostring(index) end

  -- and the name built from the loaded default reads [Top]
  hook.state.command = d.command
  local groups = hook.plan_groups(hook.collect_all_midi_takes())
  local name = hook.marker_name(groups[1], groups[1].notes[1])
  return name == "C1(1)[Top]^Kick^", name
end)

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
