-- Exercise the naming, prefill and colour logic of "Rename selected markers"
-- against a fake REAPER, through the RENAME_TEST hook.
--
-- The plugin's own steelblue_markers.lua does the writing, and it runs against
-- the same fake, so a scenario proves the whole path: which call was used
-- (P_NAME on 7.78, SetProjectMarker4 below), what ended up in the project, and
-- what was remembered in the ExtState.
--
-- The plugin seeds math.random from reaper.time_precise, and the fake's clock
-- stands still -- that, not a randomseed here, is what makes the colours
-- reproducible; seeding in this file would be overwritten the moment the
-- plugin loads.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

-- six markers, distinct names, evenly spaced, ids in timeline order
local BASE_PROJECT = {
  { pos =  5.0, name = "Kick",  id = 1, color = 0, guid = "{M1}" },
  { pos = 10.0, name = "Snare", id = 2, color = 0, guid = "{M2}" },
  { pos = 15.0, name = "Hat",   id = 3, color = 0, guid = "{M3}" },
  { pos = 20.0, name = "Tom",   id = 4, color = 0, guid = "{M4}" },
  { pos = 25.0, name = "Ride",  id = 5, color = 0, guid = "{M5}" },
  { pos = 30.0, name = "Crash", id = 6, color = 0, guid = "{M6}" },
}

local scenario = {}
local PROJECT = {}
local ext_state = {}
local calls = {}

local function copy_project()
  local copy = {}
  for index, entry in ipairs(BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do
      clone[key] = value
    end
    clone.is_region = false
    clone.lane = 0
    copy[index] = clone
  end
  return copy
end

local function count(kind)
  local total = 0
  for _, entry in ipairs(calls) do
    if entry.kind == kind then total = total + 1 end
  end
  return total
end

local function last(kind)
  for index = #calls, 1, -1 do
    if calls[index].kind == kind then return calls[index] end
  end
  return nil
end

local function ext(section, key)
  return ext_state[section .. "/" .. key]
end

local function marker(id)
  for _, entry in ipairs(PROJECT) do
    if entry.id == id then return entry end
  end
  return nil
end

local function build_reaper()
  local r = {}

  PROJECT = copy_project()
  ext_state = {}
  for key, value in pairs(scenario.ext_state or {}) do ext_state[key] = value end
  calls = {}

  r.APIExists = function() return true end
  r.ShowMessageBox = function(text)
    calls[#calls + 1] = { kind = "message", text = text }
    return 0
  end

  -- a clock that stands still: the plugin's random seed is the same every run
  r.time_precise = function() return 1234.5678 end
  r.GetAppVersion = function() return scenario.version or "7.78/OSX64" end

  -- inverses of each other, which is all the plugin needs them to be
  r.ColorToNative = function(red, green, blue) return red | (green << 8) | (blue << 16) end
  r.ColorFromNative = function(value) return value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF end

  r.GetExtState = function(section, key) return ext(section, key) or "" end
  r.SetExtState = function(section, key, value, persist)
    ext_state[section .. "/" .. key] = value
    calls[#calls + 1] = { kind = "set_ext_state", key = key, value = value, persist = persist }
  end
  r.HasExtState = function(section, key) return ext(section, key) ~= nil end

  r.Undo_BeginBlock = function() calls[#calls + 1] = { kind = "undo_begin" } end
  r.Undo_EndBlock = function(name) calls[#calls + 1] = { kind = "undo_end", name = name } end
  r.PreventUIRefresh = function() end
  r.UpdateTimeline = function() end
  r.UpdateArrange = function() end

  r.EnumProjectMarkers3 = function(_, index)
    local e = PROJECT[index + 1]
    if not e then return 0 end
    return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
  end

  r.SetProjectMarker4 = function(_, id, isrgn, pos, rgnend, name, color, flags)
    local e = marker(id)
    if e then
      e.name = name
      e.color = color
    end
    calls[#calls + 1] = {
      kind = "set_project_marker4",
      id = id, isrgn = isrgn, pos = pos, name = name, color = color, flags = flags,
    }
    return true
  end

  r.GetNumRegionsOrMarkers = function() return #PROJECT end
  r.GetRegionOrMarker = function(_, index, guid)
    if index < 0 then
      for _, e in ipairs(PROJECT) do
        if e.guid == guid then return e end
      end
      return nil
    end
    return PROJECT[index + 1]
  end
  -- REAPER answers every one of these as a float
  r.GetRegionOrMarkerInfo_Value = function(_, e, param)
    if param == "B_ISREGION" then return e.is_region and 1 or 0 end
    if param == "B_UISEL" then return 0 end
    if param == "I_NUMBER" then return e.id + 0.0 end
    if param == "I_LANENUMBER" then return e.lane + 0.0 end
    if param == "I_CUSTOMCOLOR" then return e.color + 0.0 end
    return 0
  end

  if scenario.lane_api ~= false then
    r.GetSetProjectInfo = function(_, desc)
      if desc == "RULER_LANE_COUNT" then return 2.0 end
      return 0
    end

    r.GetSetProjectInfo_String = function(_, desc)
      local param, index = desc:match("^RULER_LANE_(%u+):(-?%d+)$")
      if param == "NAME" then return true, "lane " .. index end
      if param == "GUID" then return true, "{L" .. index .. "}" end
      return false, ""
    end

    r.AddRegionOrMarker = function() return nil end

    r.SetRegionOrMarkerInfo_Value = function(_, e, param, value)
      if param == "I_LANENUMBER" then
        e.lane = value
        calls[#calls + 1] = { kind = "set_lane", guid = e.guid, value = value }
      end
      if param == "I_CUSTOMCOLOR" then
        e.color = value
        calls[#calls + 1] = { kind = "set_color", guid = e.guid, value = value }
      end
      -- REAPER documents the return value of this call as meaningless
      return 0
    end

    r.GetSetRegionOrMarkerInfo_String = function(_, e, param, str, is_set)
      if param == "GUID" then
        if is_set then return false, "" end
        return true, e.guid
      end

      if param == "P_NAME" then
        if is_set then
          e.name = str
          calls[#calls + 1] = { kind = "set_name", guid = e.guid, name = str }
          return true
        end
        return true, e.name
      end

      return false, ""
    end
  end

  return r
end

-- entries in the shape the plugin gets them from MARKERS.selected(): the click
-- order for "manager", nothing but the markers for "arrange"
local function entries_for(MARKERS, ids, source)
  local by_id = MARKERS.markers_by_id()
  local list = {}

  for order, id in ipairs(ids) do
    local entry = by_id[id]
    if source == "manager" then
      entry.selection_order = order
    end
    list[#list + 1] = entry
  end

  return list
end

local function run(name, setup, fn)
  scenario = setup or {}
  reaper = build_reaper()

  RENAME_TEST = {}
  local hook = RENAME_TEST
  dofile(folder .. "Rename selected markers.lua")
  RENAME_TEST = nil

  local MARKERS = dofile(folder .. "steelblue_markers.lua")

  local ok, detail = fn(hook, MARKERS)
  print(string.format("%-46s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok
end

local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

print("Rename selected markers -- naming, prefill, colour:\n")

check(run("defaults build the full MA syntax", {}, function(hook)
  local built = hook.build_marker_name("Kick", 0)
  return built == "Kick(1)[Top]^Kick^", built
end))

check(run("an empty field leaves its element out", {}, function(hook)
  local cases = {
    { { command_name = "" }, "Kick(1)^Kick^" },
    { { sequence_name = "" }, "Kick(1)[Top]" },
    { { use_cue_number = false }, "Kick[Top]^Kick^" },
    { { sequence_name = "Main" }, "Kick(1)[Top]^Main^" },
    -- MarkerName is the MARKER's name, not whatever the cue field says. The
    -- checkbox "sequence name = cue name" is gone; typing the name into both
    -- fields is how that is done now.
    { { cue_name = "Intro" }, "Intro(1)[Top]^Kick^" },
    { { cue_name = "Intro", sequence_name = "Intro" }, "Intro(1)[Top]^Intro^" },
  }

  for _, case in ipairs(cases) do
    hook.reset_to_defaults()
    hook.set_state(case[1])
    local built = hook.build_marker_name("Kick", 0)
    if built ~= case[2] then
      return false, "got " .. built .. ", wanted " .. case[2]
    end
  end

  return true, "6 field combinations"
end))

check(run("multiple cues wrap in click order", {}, function(hook, MARKERS)
  hook.set_state({ create_multiple_cues = true, multiple_cue_count = 5 })
  -- clicked last marker first
  local entries = entries_for(MARKERS, { 6, 5, 4, 3, 2, 1 }, "manager")
  if hook.run_rename(entries, "manager") ~= 6 then return false, "did not rename 6" end

  local wanted = { [6] = 1, [5] = 2, [4] = 3, [3] = 4, [2] = 5, [1] = 1 }
  for id, number in pairs(wanted) do
    local expected = "(" .. number .. ")"
    if not marker(id).name:find(expected, 1, true) then
      return false, "marker " .. id .. " is " .. marker(id).name
    end
  end

  return true, "1 2 3 4 5 1 along the click order"
end))

check(run("without click order the cues follow the timeline", {}, function(hook, MARKERS)
  hook.set_state({ create_multiple_cues = true, multiple_cue_count = 5 })
  -- arrange view hands them over unordered, and out of timeline order here
  local entries = entries_for(MARKERS, { 4, 1, 6, 3, 5, 2 }, "arrange")
  if hook.run_rename(entries, "arrange") ~= 6 then return false, "did not rename 6" end

  local wanted = { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 1 }
  for id, number in pairs(wanted) do
    if not marker(id).name:find("(" .. number .. ")", 1, true) then
      return false, "marker " .. id .. " is " .. marker(id).name
    end
  end

  return true, "1 2 3 4 5 1 along the timeline"
end))

check(run("a marker with syntax is not wrapped twice", {}, function(hook)
  local built = hook.build_marker_name("Kick(1)[Top]^Kick^", 0)
  if built ~= "Kick(1)[Top]^Kick^" then return false, "got " .. built end

  local base = hook.base_name("Kick (12)(1)[GO]^Kick^")
  if base ~= "Kick (12)" then return false, "base " .. string.format("%q", base) end

  hook.set_state({ command_name = "GO" })
  built = hook.build_marker_name("Kick (12)(1)[GO]^Kick^", 0)
  if built ~= "Kick (12)(1)[GO]^Kick (12)^" then return false, "got " .. built end

  return true, "the track's own brackets survive"
end))

check(run("prefill takes the parts it finds", {}, function(hook)
  if not hook.prefill_from("Snare(3)[GO]^Main^") then return false, "returned false" end

  local s = hook.get_state()
  if s.command_name ~= "GO" then return false, "command " .. s.command_name end
  if s.cue_number ~= "3" then return false, "number " .. string.format("%q", s.cue_number) end
  if s.use_cue_number ~= true then return false, "cue number switched off" end
  if s.sequence_name ~= "Main" then return false, "sequence " .. s.sequence_name end
  if s.cue_name ~= "MarkerName" then return false, "cue name " .. s.cue_name end

  local text = hook.last_status()
  if text ~= "Fields taken from the selected marker." then return false, "status " .. text end

  -- and it does not happen a second time
  if hook.prefill_from("Other(9)[X]^Y^") then return false, "prefilled twice" end
  if hook.get_state().command_name ~= "GO" then return false, "second prefill changed the fields" end

  return true, "GO, 3, Main -- once"
end))

check(run("a sequence equal to the cue becomes MarkerName", {}, function(hook)
  if not hook.prefill_from("Snare(3)[GO]^Snare^") then return false, "returned false" end
  local s = hook.get_state()
  return s.sequence_name == "MarkerName", "sequence " .. s.sequence_name
end))

check(run("a missing command prefills as empty", {}, function(hook)
  if not hook.prefill_from("Snare(2)^Snare^") then return false, "returned false" end
  local s = hook.get_state()
  if s.command_name ~= "" then return false, "command " .. string.format("%q", s.command_name) end
  return s.cue_number == "2", "number " .. s.cue_number
end))

check(run("a marker without syntax changes nothing", {}, function(hook)
  local before = hook.get_state()
  if hook.prefill_from("Snare") then return false, "claims it prefilled" end

  local after = hook.get_state()
  for key, value in pairs(before) do
    if after[key] ~= value then return false, key .. " changed" end
  end

  return true, "fields untouched, returns false"
end))

check(run("reset puts every field back", {}, function(hook)
  hook.set_state({
    cue_name = "Intro", use_cue_number = false, cue_number = "7",
    create_multiple_cues = true, multiple_cue_count = 4, command_name = "Off",
    sequence_name = "Main", set_colour = true, colour_mode = "last",
  })

  hook.reset_to_defaults()

  local s = hook.get_state()
  for key, value in pairs(hook.DEFAULTS) do
    if s[key] ~= value then
      return false, key .. " is " .. tostring(s[key]) .. ", not " .. tostring(value)
    end
  end
  for key in pairs(s) do
    if hook.DEFAULTS[key] == nil then return false, "extra field " .. key end
  end

  local text = hook.last_status()
  if text ~= "Defaults restored." then return false, "status " .. text end

  -- and the prefill counts as done, or it would undo the reset on the next poll
  if hook.prefill_from("Snare(3)[GO]^Main^") then return false, "prefilled after reset" end

  return true, "all 9 fields, status, prefill closed"
end))

check(run("renaming without the colour option touches no colour", {}, function(hook, MARKERS)
  local entries = entries_for(MARKERS, { 1, 2, 3, 4, 5, 6 }, "manager")
  hook.run_rename(entries, "manager")

  if count("set_color") ~= 0 then return false, count("set_color") .. " colour writes" end
  for id = 1, 6 do
    if marker(id).color ~= 0 then return false, "marker " .. id .. " was coloured" end
  end
  if ext("steelblue_rename", "last_color") ~= nil then return false, "wrote an ExtState" end

  local text, kind = hook.last_status()
  return text == "6 markers renamed." and kind == "success", text .. " / " .. tostring(kind)
end))

check(run("random colours all six the same, and remembers it", {}, function(hook, MARKERS)
  hook.set_state({ set_colour = true, colour_mode = "random" })
  local chosen = hook.pick_colour()
  if not chosen then return false, "no colour offered" end

  local entries = entries_for(MARKERS, { 1, 2, 3, 4, 5, 6 }, "manager")
  hook.run_rename(entries, "manager")

  for id = 1, 6 do
    if marker(id).color ~= chosen then
      return false, "marker " .. id .. " is " .. marker(id).color .. ", not " .. chosen
    end
  end
  if chosen & 0x1000000 == 0 then return false, "colour flag missing" end

  local stored = ext("steelblue_rename", "last_color")
  if stored ~= tostring(chosen) then return false, "ExtState " .. tostring(stored) end
  if not last("set_ext_state").persist then return false, "not written persistently" end

  if hook.pick_colour() == chosen then return false, "the next run would reuse the colour" end

  local text, kind = hook.last_status()
  return text == "6 markers renamed and coloured." and kind == "success", "colour " .. chosen
end))

check(run("last used takes exactly the remembered colour", {
  ext_state = { ["steelblue_rename/last_color"] = "16744576" },
}, function(hook, MARKERS)
  hook.set_state({ set_colour = true, colour_mode = "last" })
  if hook.pick_colour() ~= 16744576 then return false, "offered " .. tostring(hook.pick_colour()) end

  local entries = entries_for(MARKERS, { 1, 2, 3 }, "manager")
  hook.run_rename(entries, "manager")

  for id = 1, 3 do
    if marker(id).color ~= 16744576 then return false, "marker " .. id .. " is " .. marker(id).color end
  end

  local text, kind = hook.last_status()
  return text == "3 markers renamed and coloured." and kind == "success", text
end))

check(run("last used without a memory renames but does not colour", {}, function(hook, MARKERS)
  hook.set_state({ set_colour = true, colour_mode = "last" })
  if hook.pick_colour() ~= nil then return false, "invented a colour" end

  local entries = entries_for(MARKERS, { 1, 2, 3 }, "manager")
  if hook.run_rename(entries, "manager") ~= 3 then return false, "did not rename" end

  if count("set_color") ~= 0 then return false, "coloured anyway" end
  if marker(1).name ~= "Kick(1)[Top]^Kick^" then return false, "marker 1 is " .. marker(1).name end

  local text, kind = hook.last_status()
  return text == "No colour used yet - pick Random." and kind == "warning", text .. " / " .. tostring(kind)
end))

check(run("on 7.78 renaming goes through P_NAME", {}, function(hook, MARKERS)
  local entries = entries_for(MARKERS, { 1, 2, 3 }, "manager")
  hook.run_rename(entries, "manager")

  if count("set_project_marker4") ~= 0 then return false, "reached for SetProjectMarker4" end
  if count("set_name") ~= 3 then return false, count("set_name") .. " P_NAME writes" end
  if count("undo_begin") ~= 1 then return false, "no undo block" end
  return marker(1).name == "Kick(1)[Top]^Kick^", "3 names via GUID, lane untouched"
end))

check(run("on 7.75 renaming falls back to SetProjectMarker4", { lane_api = false }, function(hook, MARKERS)
  local entries = entries_for(MARKERS, { 1, 2, 3 }, "manager")
  hook.run_rename(entries, "manager")

  if count("set_name") ~= 0 then return false, "used an API that is not there" end
  if count("set_project_marker4") ~= 3 then return false, count("set_project_marker4") .. " writes" end
  local call = last("set_project_marker4")
  if call.pos ~= 15.0 or call.id ~= 3 then return false, "id or position changed" end
  return marker(3).name == "Hat(1)[Top]^Hat^", "3 markers via the old call"
end))

check(run("an empty selection writes nothing", {}, function(hook)
  if hook.run_rename({}, "manager") ~= 0 then return false, "claims it renamed something" end

  if count("undo_begin") ~= 0 then return false, "opened an undo block" end
  if count("set_name") ~= 0 or count("set_project_marker4") ~= 0 then return false, "wrote a marker" end

  local text, kind = hook.last_status()
  return text == "No selected markers found." and kind == "warning", text .. " / " .. tostring(kind)
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
