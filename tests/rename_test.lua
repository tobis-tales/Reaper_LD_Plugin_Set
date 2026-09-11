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
  -- 1.1.1: colour on by default, command Top from the Go/Top/Flash list
  local d = hook.DEFAULTS
  if d.set_colour ~= true then return false, "set_colour defaults to " .. tostring(d.set_colour) end
  if d.colour_mode ~= "random" then return false, "colour_mode defaults to " .. tostring(d.colour_mode) end
  if d.command_name ~= "Top" then return false, "command defaults to " .. string.format("%q", d.command_name) end
  if table.concat(hook.COMMANDS, "/") ~= "Go/Top/Flash" then
    return false, "list is " .. table.concat(hook.COMMANDS, "/")
  end

  local s = hook.get_state()
  if s.set_colour ~= true or s.command_name ~= "Top" then return false, "state does not start from the defaults" end

  local built = hook.build_marker_name("Kick", 0)
  return built == "Kick(1)[Top]^Kick^", built
end))

check(run("the command list carries the current text", {}, function(hook)
  -- one of the three: three entries, the current one selected
  for i, name in ipairs({ "Go", "Top", "Flash" }) do
    local items, index, list = hook.command_choices(name)
    if items ~= "Go\0Top\0Flash\0" then return false, name .. ": items " .. string.format("%q", items) end
    if index ~= i - 1 then return false, name .. " is index " .. tostring(index) end
    if #list ~= 3 or list[index + 1] ~= name then return false, name .. ": list does not point at it" end
  end

  -- a prefilled command outside the three is a fourth entry while it is active
  hook.prefill_from("Snare(3)[On]^Main^")
  local current = hook.get_state().command_name
  if current ~= "On" then return false, "prefill gave " .. string.format("%q", current) end

  local items, index, list = hook.command_choices(current)
  if items ~= "Go\0Top\0Flash\0On\0" then return false, "items " .. string.format("%q", items) end
  if index ~= 3 or list[4] ~= "On" then return false, "On is index " .. tostring(index) end

  -- picking a standard entry means: that text, and the fourth entry is gone
  hook.set_state({ command_name = list[1] })
  items, index = hook.command_choices(hook.get_state().command_name)
  if items ~= "Go\0Top\0Flash\0" or index ~= 0 then return false, "after picking Go: " .. string.format("%q", items) end

  return hook.build_marker_name("Kick", 0) == "Kick(3)[Go]^Main^", "3 + On as fourth, Go picked"
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

-- The full name is checked, not just the number in it: the cue name proves
-- which marker the run took as its template, and only the number changes from
-- marker to marker.
local function names_are(wanted)
  for id, name in pairs(wanted) do
    if marker(id).name ~= name then
      return false, "marker " .. id .. " is " .. marker(id).name .. ", not " .. name
    end
  end
  return true
end

check(run("multiple cues wrap in click order", {}, function(hook, MARKERS)
  hook.set_state({ create_multiple_cues = true, multiple_cue_count = 5 })
  -- clicked Crash first, so Crash is the template for all six
  local entries = entries_for(MARKERS, { 6, 5, 4, 3, 2, 1 }, "manager")
  if hook.run_rename(entries, "manager") ~= 6 then return false, "did not rename 6" end

  local ok, detail = names_are({
    [6] = "Crash(1)[Top]^Crash^",
    [5] = "Crash(2)[Top]^Crash^",
    [4] = "Crash(3)[Top]^Crash^",
    [3] = "Crash(4)[Top]^Crash^",
    [2] = "Crash(5)[Top]^Crash^",
    [1] = "Crash(1)[Top]^Crash^",
  })
  if not ok then return false, detail end

  return true, "all six are Crash, numbered 1 2 3 4 5 1 in click order"
end))

check(run("without click order the cues follow the timeline", {}, function(hook, MARKERS)
  hook.set_state({ create_multiple_cues = true, multiple_cue_count = 5 })
  -- arrange view hands them over unordered, and out of timeline order here;
  -- the earliest marker (Kick) becomes the template
  local entries = entries_for(MARKERS, { 4, 1, 6, 3, 5, 2 }, "arrange")
  if hook.run_rename(entries, "arrange") ~= 6 then return false, "did not rename 6" end

  local ok, detail = names_are({
    [1] = "Kick(1)[Top]^Kick^",
    [2] = "Kick(2)[Top]^Kick^",
    [3] = "Kick(3)[Top]^Kick^",
    [4] = "Kick(4)[Top]^Kick^",
    [5] = "Kick(5)[Top]^Kick^",
    [6] = "Kick(1)[Top]^Kick^",
  })
  if not ok then return false, detail end

  return true, "all six are Kick, numbered 1 2 3 4 5 1 along the timeline"
end))

check(run("MarkerName means the first selected marker", {}, function(hook, MARKERS)
  -- clicked Hat, then Kick, then Snare -- and all three end up called Hat
  local entries = entries_for(MARKERS, { 3, 1, 2 }, "manager")
  if hook.run_rename(entries, "manager") ~= 3 then return false, "did not rename 3" end

  local ok, detail = names_are({
    [3] = "Hat(1)[Top]^Hat^",
    [1] = "Hat(1)[Top]^Hat^",
    [2] = "Hat(1)[Top]^Hat^",
  })
  if not ok then return false, detail end

  return true, "Hat, Hat, Hat -- one cue list"
end))

check(run("the first marker's syntax defines the base", {}, function(hook, MARKERS)
  marker(1).name = "Kick(1)[Top]^Kick^"

  local entries = entries_for(MARKERS, { 1, 2 }, "manager")
  if hook.run_rename(entries, "manager") ~= 2 then return false, "did not rename 2" end

  local ok, detail = names_are({
    [1] = "Kick(1)[Top]^Kick^",
    [2] = "Kick(1)[Top]^Kick^",
  })
  if not ok then return false, detail end

  return true, "no double wrapping, and Snare becomes Kick"
end))

check(run("arrange picks the earliest marker as the template", {}, function(hook, MARKERS)
  local entries = entries_for(MARKERS, { 4, 1, 6 }, "arrange")
  if hook.run_rename(entries, "arrange") ~= 3 then return false, "did not rename 3" end

  local ok, detail = names_are({
    [4] = "Kick(1)[Top]^Kick^",
    [1] = "Kick(1)[Top]^Kick^",
    [6] = "Kick(1)[Top]^Kick^",
  })
  if not ok then return false, detail end

  return true, "Kick at 5.0 s wins, though it was handed over second"
end))

check(run("prefill reads the first marker in numbering order", {}, function(hook, MARKERS)
  marker(3).name = "Hat(2)[GO]^Main^"

  -- Hat was clicked first, so its syntax fills the fields -- not Kick's, which
  -- has none and would have used up the one chance
  local entries = entries_for(MARKERS, { 3, 1 }, "manager")
  if not hook.prefill_from_selection(entries, "manager") then return false, "returned false" end

  local s = hook.get_state()
  if s.command_name ~= "GO" then return false, "command " .. string.format("%q", s.command_name) end
  if s.cue_number ~= "2" then return false, "number " .. string.format("%q", s.cue_number) end
  if s.sequence_name ~= "Main" then return false, "sequence " .. s.sequence_name end

  return true, "GO, 2, Main -- from the marker clicked first"
end))

-- The arrange fallback is the case where the list order and the numbering order
-- genuinely differ: the manager already hands its entries over in click order,
-- so there entries[1] and ordered[1] are the same marker either way.
check(run("prefill without a click order reads the earliest marker", {}, function(hook, MARKERS)
  marker(1).name = "Kick(4)[On]^Solo^"

  -- Tom comes first in the list, Kick is first on the timeline
  local entries = entries_for(MARKERS, { 4, 1, 6 }, "arrange")
  if not hook.prefill_from_selection(entries, "arrange") then
    return false, "took Tom, which has no syntax"
  end

  local s = hook.get_state()
  if s.command_name ~= "On" then return false, "command " .. string.format("%q", s.command_name) end
  if s.cue_number ~= "4" then return false, "number " .. string.format("%q", s.cue_number) end
  if s.sequence_name ~= "Solo" then return false, "sequence " .. s.sequence_name end

  return true, "On, 4, Solo -- from Kick at 5.0 s, not from Tom"
end))

-- What the preview shows must be the marker the rename will use, so the pick
-- itself is checked directly.
check(run("the template is the same marker everywhere", {}, function(hook, MARKERS)
  local clicked = hook.template_for(entries_for(MARKERS, { 6, 5, 4 }, "manager"), "manager")
  if not clicked or clicked.id ~= 6 then
    return false, "manager picked " .. tostring(clicked and clicked.id)
  end

  local earliest = hook.template_for(entries_for(MARKERS, { 4, 1, 6 }, "arrange"), "arrange")
  if not earliest or earliest.id ~= 1 then
    return false, "arrange picked " .. tostring(earliest and earliest.id)
  end

  if hook.template_for({}, "manager") ~= nil then return false, "invented a template" end

  return true, "clicked first / earliest / nothing"
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
  -- colour is on by default since 1.1.1, so "without" has to be said
  hook.set_state({ set_colour = false })
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
  -- no colour here, so every SetProjectMarker4 call is a rename
  hook.set_state({ set_colour = false })
  local entries = entries_for(MARKERS, { 1, 2, 3 }, "manager")
  hook.run_rename(entries, "manager")

  if count("set_name") ~= 0 then return false, "used an API that is not there" end
  if count("set_project_marker4") ~= 3 then return false, count("set_project_marker4") .. " writes" end
  local call = last("set_project_marker4")
  if call.pos ~= 15.0 or call.id ~= 3 then return false, "id or position changed" end
  -- Kick was clicked first, so Hat is renamed to Kick like the rest
  return marker(3).name == "Kick(1)[Top]^Kick^", "3 markers via the old call"
end))

check(run("the cue number arrows step by one", {}, function(hook)
  local cases = {
    { "1", 1, "2" },
    { "2", -1, "1" },
    { "1", -1, "1" },
    { "1.5", 1, "2.5" },
    { "", 1, "1" },
    { "abc", -1, "1" },
    -- "2.0" parses as a Lua float, not an integer -- without format_cue_number
    -- the result prints as "3.0" instead of "3"
    { "2.0", 1, "3" },
  }

  for _, case in ipairs(cases) do
    local got = hook.step_cue_number(case[1], case[2])
    if got ~= case[3] then
      return false, string.format("%q %+d -> %q, wanted %q", case[1], case[2], got, case[3])
    end
  end

  return true, "7 cases"
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
