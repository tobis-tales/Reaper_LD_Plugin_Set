-- probe_lanes.lua
-- Answers what cannot be answered outside REAPER: how a ruler lane is created
-- at all, and how a marker behaves once it sits in one.
--
-- HOW TO RUN
--   1. Open a NEW, EMPTY project (File > New project tab). This script creates
--      a lane and two markers, so it refuses to run in a project that already
--      has markers or tracks.
--   2. Actions > Show action list > "Load ReaScript..." > pick this file.
--   3. Copy the whole console text and hand it back.
--   4. File > Save project as... > tests/fixtures/lanes_probe.RPP
--
-- Two functions, and which descriptor belongs to which is the thing v1 got
-- wrong (verified against the doc blocks in the 7.79 binary, 2026-09-05):
--   GetSetProjectInfo(proj, desc, value, is_set) -> number
--     RULER_LANE_COUNT, RULER_LANE_ORDER:X, RULER_LANE_COLOR:X,
--     RULER_LANE_HIDDEN:X, RULER_LANE_LOCKED:X, RULER_LANE_VISIBLE:X,
--     RULER_LANE_DEFAULT:X, RULER_LANE_TIMEBASE:X, RULER_LANE_FROM_GUID:X
--   GetSetProjectInfo_String(proj, desc, str, is_set) -> retval, str
--     RULER_LANE_NAME:X, RULER_LANE_GUID:X
--
-- Lane indexes are 0-based in the API; the Ruler Lane Manager and the .RPP
-- show them 1-based.
--
-- WHAT v3 CHANGES (probe v2 found that creating a lane fails)
--   v2 passed a position as the VALUE of RULER_LANE_ORDER:-1 and nothing
--   happened. The binary's own doc block reads the other way round:
--     "RULER_LANE_ORDER:X : move lane at position X to a new position,
--      -1 to insert a new lane"
--   so X is the position and -1 is the value. v3 tries that first, keeps the
--   v2 spelling as a control, and then falls back to the action
--   "Ruler: Quick add ruler lane", which the 7.79 binary does have.
--
-- It writes no file and touches nothing but the open project. Every step runs
-- in pcall, so one unsupported call cannot cut the probe short. Output is
-- "KEY = value" per line so the console text stays copyable and greppable.

local function say(key, value)
  reaper.ShowConsoleMsg(tostring(key) .. " = " .. tostring(value) .. "\n")
end

local function step(label, fn)
  local ok, err = pcall(fn)
  if not ok then
    say("STEP " .. label .. " ERROR", err)
  end
end

-- numeric descriptors
local function lane_number(desc)
  return reaper.GetSetProjectInfo(0, desc, 0, false)
end

local function set_lane_number(desc, value)
  return reaper.GetSetProjectInfo(0, desc, value, true)
end

-- string descriptors (NAME and GUID only)
local function lane_text(desc)
  local retval, str = reaper.GetSetProjectInfo_String(0, desc, "", false)
  return retval, str
end

local function set_lane_text(desc, value)
  return reaper.GetSetProjectInfo_String(0, desc, value, true)
end

-- REAPER answers every numeric descriptor as a FLOAT (2.0, not 2), and a
-- descriptor built from one reads "RULER_LANE_NAME:2.0", which REAPER does not
-- parse. Every index this probe puts into a descriptor goes through here first.
local function lane_index(value)
  local number = tonumber(value)
  if not number then
    return nil
  end
  return math.floor(number + 0.5)
end

local function lane_count()
  return lane_index(lane_number("RULER_LANE_COUNT")) or 0
end

local function list_lanes(tag)
  local count = lane_count()
  say(tag .. " COUNT", count)

  for x = 0, count - 1 do
    local name_ok, name = lane_text("RULER_LANE_NAME:" .. x)
    local guid_ok, guid = lane_text("RULER_LANE_GUID:" .. x)
    say(tag .. " LANE " .. x, string.format(
      "name_ok=%s name=%q guid_ok=%s guid=%q color=%s default=%s timebase=%s hidden=%s visible=%s locked=%s",
      tostring(name_ok), tostring(name),
      tostring(guid_ok), tostring(guid),
      tostring(lane_number("RULER_LANE_COLOR:" .. x)),
      tostring(lane_number("RULER_LANE_DEFAULT:" .. x)),
      tostring(lane_number("RULER_LANE_TIMEBASE:" .. x)),
      tostring(lane_number("RULER_LANE_HIDDEN:" .. x)),
      tostring(lane_number("RULER_LANE_VISIBLE:" .. x)),
      tostring(lane_number("RULER_LANE_LOCKED:" .. x))
    ))
  end

  -- one index past the end, to show what out of range answers
  local past_ok, past = lane_text("RULER_LANE_NAME:" .. count)
  say(tag .. " LANE " .. count .. " (out of range)",
    string.format("name_ok=%s name=%q", tostring(past_ok), tostring(past)))
end

-- GUID -> index, for spotting which lane is the new one
local function lane_guids()
  local by_guid, in_order = {}, {}

  for x = 0, lane_count() - 1 do
    local ok, guid = lane_text("RULER_LANE_GUID:" .. x)
    if ok and guid and guid ~= "" and by_guid[guid] == nil then
      by_guid[guid] = x
      in_order[#in_order + 1] = guid
    end
  end

  return by_guid, in_order
end

if reaper.ClearConsole then
  reaper.ClearConsole()
end

-- ------------------------------------------------- refuse a busy project

local existing_markers = reaper.GetNumRegionsOrMarkers and reaper.GetNumRegionsOrMarkers(0) or 0
local existing_tracks = reaper.CountTracks and reaper.CountTracks(0) or 0

if existing_markers > 0 or existing_tracks > 0 then
  reaper.ShowConsoleMsg(string.format(
    "REFUSING: project is not empty (%d markers/regions, %d tracks). " ..
    "In REAPER: File > New project tab, then run this script again.\n",
    existing_markers, existing_tracks
  ))
  return
end

say("PROBE", "steelblue ruler lane probe v3")

-- ------------------------------------------------------------------ a) API

step("a", function()
  say("APP_VERSION", reaper.GetAppVersion and reaper.GetAppVersion() or "unknown")

  local names = {
    "GetSetProjectInfo",
    "GetSetProjectInfo_String",
    "GetNumRegionsOrMarkers",
    "GetRegionOrMarker",
    "GetRegionOrMarkerInfo_Value",
    "SetRegionOrMarkerInfo_Value",
    "GetSetRegionOrMarkerInfo_String",
    "AddRegionOrMarker",
    "AddProjectMarker2",
    "ColorToNative",
    "CountTracks",
    "SectionFromUniqueID",
    "kbd_enumerateActions",
    "Main_OnCommand",
    "UpdateTimeline",
  }

  for _, name in ipairs(names) do
    say("HAS " .. name, reaper[name] ~= nil and "yes" or "no")
  end
end)

-- ------------------------------------------------------- b) what is there

step("b", function()
  say("RULER_LANE_COUNT (numeric)", tostring(lane_number("RULER_LANE_COUNT")))

  -- v1 asked this through _String and got false, which is how the wrong
  -- function was found; recorded here so the difference stays visible
  local string_ok, string_value = lane_text("RULER_LANE_COUNT")
  say("RULER_LANE_COUNT via _String retval", tostring(string_ok))
  say("RULER_LANE_COUNT via _String str", string.format("%q", tostring(string_value)))

  list_lanes("BEFORE")
end)

-- -------------------------------------------------------- c) create a lane
--
-- Five things are unknown at once here, so each try prints what it called,
-- what came back, and the only answer that counts: RULER_LANE_COUNT after.
-- The first try that moves the count wins and the rest are skipped, so the
-- console says exactly one way to create a lane rather than "one of these".

local guids_before = {}
local created_index = nil
local create_won = nil

step("c", function()
  local before = lane_count()
  guids_before = lane_guids()
  say("COUNT BEFORE CREATE", before)

  local number = 0

  -- returns true once the count has moved
  local function try(label, call_text, run)
    if create_won then
      return true
    end

    number = number + 1
    say("CREATE TRY " .. number .. " call", call_text)

    local ok, result = pcall(run)
    if not ok then
      say("CREATE TRY " .. number .. " ERROR", result)
    else
      say("CREATE TRY " .. number .. " return", tostring(result))
    end

    local after = lane_count()
    say("CREATE TRY " .. number .. " count after", after)

    if after > before then
      create_won = label
      say("CREATE WON", label)
      return true
    end

    return false
  end

  -- c1: the binary's own wording -- "RULER_LANE_ORDER:X : move lane at
  -- position X to a new position, -1 to insert a new lane". Read that way X
  -- is the target position and -1 is the value, which is the opposite of what
  -- v2 tried.
  try("ORDER:count = -1",
    string.format("GetSetProjectInfo(0, \"RULER_LANE_ORDER:%d\", -1, true)", before),
    function() return set_lane_number("RULER_LANE_ORDER:" .. before, -1) end)

  -- c2: same reading, but insert at the front instead of past the end, in
  -- case a position equal to the count is rejected as out of range
  try("ORDER:0 = -1",
    "GetSetProjectInfo(0, \"RULER_LANE_ORDER:0\", -1, true)",
    function() return set_lane_number("RULER_LANE_ORDER:0", -1) end)

  -- c3: -1 on both sides, the one combination v2 did not try
  try("ORDER:-1 = -1",
    "GetSetProjectInfo(0, \"RULER_LANE_ORDER:-1\", -1, true)",
    function() return set_lane_number("RULER_LANE_ORDER:-1", -1) end)

  -- c4: the action list. The 7.79 binary carries "Ruler: Quick add ruler
  -- lane" and "Ruler: Add ruler lane..." (the second opens a dialog and must
  -- NOT be fired from a script). Command IDs are not stable across builds, so
  -- the name is looked up rather than hard-coded -- and every ruler-lane
  -- action is printed, because the module will need one of these IDs later.
  if not create_won then
    if not (reaper.SectionFromUniqueID and reaper.kbd_enumerateActions and reaper.Main_OnCommand) then
      say("ACTIONS", "kbd_enumerateActions / SectionFromUniqueID / Main_OnCommand missing")
      return
    end

    local section = reaper.SectionFromUniqueID(0) -- 0 = Main
    say("MAIN SECTION", tostring(section))

    local quick_add_id, quick_add_name = nil, nil
    local seen = 0
    local index = 0

    while index < 100000 do -- a cap, so a misbehaving enumerator cannot hang REAPER
      local command_id, name = reaper.kbd_enumerateActions(section, index)
      if not command_id or command_id == 0 then
        break
      end

      local lower = tostring(name):lower()
      if lower:find("ruler lane", 1, true) then
        seen = seen + 1
        say("ACTION " .. tostring(command_id), tostring(name))
        if quick_add_id == nil and lower:find("quick add ruler lane", 1, true) then
          quick_add_id, quick_add_name = command_id, name
        end
      end

      index = index + 1
    end

    say("ACTIONS SCANNED", index)
    say("ACTIONS MATCHING \"ruler lane\"", seen)
    say("QUICK ADD ACTION ID", tostring(quick_add_id))
    say("QUICK ADD ACTION NAME", tostring(quick_add_name))

    if quick_add_id then
      try("action: " .. tostring(quick_add_name),
        string.format("Main_OnCommand(%d, 0)", quick_add_id),
        function() return reaper.Main_OnCommand(quick_add_id, 0) end)
    end
  end

  if not create_won then
    say("CREATE", "no attempt changed RULER_LANE_COUNT")
  end

  list_lanes("AFTER CREATE")
end)

-- ------------------------------------------- d) name and color the new lane

step("d", function()
  local by_guid, in_order = lane_guids()
  for _, guid in ipairs(in_order) do
    if guids_before[guid] == nil then
      created_index = by_guid[guid]
      say("NEW LANE GUID", guid)
      break
    end
  end

  say("NEW LANE INDEX", tostring(created_index))
  if not created_index then
    say("NEW LANE", "not found -- nothing to configure, later steps degrade")
    return
  end

  -- a fresh lane should be default for nothing; the module must not assume it
  -- inherits "default for new markers" from the lane it was inserted next to
  say("NEW LANE RULER_LANE_DEFAULT (expect 0)",
    tostring(lane_number("RULER_LANE_DEFAULT:" .. created_index)))

  local color = reaper.ColorToNative(70, 130, 180) | 0x1000000
  say("SET NAME retval", tostring(set_lane_text("RULER_LANE_NAME:" .. created_index, "probe")))
  say("SET COLOR value", color)
  say("SET COLOR return", tostring(set_lane_number("RULER_LANE_COLOR:" .. created_index, color)))

  local name_ok, name = lane_text("RULER_LANE_NAME:" .. created_index)
  say("READBACK NAME", string.format("retval=%s str=%q", tostring(name_ok), tostring(name)))
  local guid_ok, guid = lane_text("RULER_LANE_GUID:" .. created_index)
  say("READBACK GUID", string.format("retval=%s str=%q", tostring(guid_ok), tostring(guid)))

  for _, param in ipairs({ "COLOR", "DEFAULT", "TIMEBASE", "HIDDEN", "VISIBLE", "LOCKED" }) do
    local desc = "RULER_LANE_" .. param .. ":" .. created_index
    say("READBACK " .. desc, tostring(lane_number(desc)))
  end
end)

-- --------------------------------------------------------- e) add a marker

local probe_marker = nil
local probe_guid = nil

step("e", function()
  probe_marker = reaper.AddRegionOrMarker(0, false, 1.0, 0, "probe-marker", -1, 0)
  say("AddRegionOrMarker type", type(probe_marker))
  say("AddRegionOrMarker tostring", tostring(probe_marker))

  if not probe_marker then
    return
  end

  for _, param in ipairs({ "I_INDEX", "I_NUMBER", "I_LANENUMBER", "B_VISIBLE" }) do
    say("MARKER " .. param .. " (before set)",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, param)))
  end

  -- v2 read B_VISIBLE = 0 on a fresh marker whose lane was visible. The guess
  -- was that the flag is only computed when the ruler redraws; this settles it.
  if reaper.UpdateTimeline then
    reaper.UpdateTimeline()
    say("MARKER B_VISIBLE after UpdateTimeline",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  else
    say("MARKER B_VISIBLE after UpdateTimeline", "UpdateTimeline missing")
  end

  local ok, guid = reaper.GetSetRegionOrMarkerInfo_String(0, probe_marker, "GUID", "", false)
  probe_guid = guid
  say("MARKER GUID retval", tostring(ok))
  say("MARKER GUID", string.format("%q", tostring(guid)))
end)

-- ------------------------------------------------------ f) put it in a lane

step("f", function()
  if not probe_marker or not created_index then
    say("STEP f SKIPPED", "no marker or no new lane")
    return
  end

  local retval = reaper.SetRegionOrMarkerInfo_Value(0, probe_marker, "I_LANENUMBER", created_index)
  say("SET I_LANENUMBER arg (0-based)", created_index)
  say("SET I_LANENUMBER return", tostring(retval))
  say("MARKER I_LANENUMBER readback",
    tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "I_LANENUMBER")))

  if probe_guid and probe_guid ~= "" then
    local again = reaper.GetRegionOrMarker(0, -1, probe_guid)
    say("GetRegionOrMarker by GUID tostring", tostring(again))
    say("GetRegionOrMarker by GUID same pointer",
      tostring(tostring(again) == tostring(probe_marker)))
  end

  say("MARKER B_VISIBLE (after set)",
    tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))

  if reaper.UpdateTimeline then
    reaper.UpdateTimeline()
    say("MARKER B_VISIBLE (after set, after UpdateTimeline)",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  end
end)

-- --------------------------------------------------------- g) hide the lane

step("g", function()
  if not created_index then
    say("STEP g SKIPPED", "no new lane")
    return
  end

  say("SET HIDDEN 1 return", tostring(set_lane_number("RULER_LANE_HIDDEN:" .. created_index, 1)))
  say("READBACK HIDDEN", tostring(lane_number("RULER_LANE_HIDDEN:" .. created_index)))
  if reaper.UpdateTimeline then
    reaper.UpdateTimeline()
  end
  if probe_marker then
    say("MARKER B_VISIBLE while lane hidden",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  end

  say("SET HIDDEN 0 return", tostring(set_lane_number("RULER_LANE_HIDDEN:" .. created_index, 0)))
  if reaper.UpdateTimeline then
    reaper.UpdateTimeline()
  end
  if probe_marker then
    say("MARKER B_VISIBLE after unhide",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  end
end)

-- ------------------------------------------- h) which lane does legacy pick

step("h", function()
  local id = reaper.AddProjectMarker2(0, false, 2.0, 0, "legacy-marker", -1, 0)
  say("AddProjectMarker2 return", tostring(id))
  if not id then
    return
  end

  local total = reaper.GetNumRegionsOrMarkers(0)
  say("GetNumRegionsOrMarkers", total)

  local found = false
  for index = 0, total - 1 do
    local rm = reaper.GetRegionOrMarker(0, index, "")
    if rm then
      -- match on I_NUMBER, never on the index: GetRegionOrMarker counts markers
      -- AND regions, AddProjectMarker2 hands back the displayed marker number
      local is_region = reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_ISREGION") == 1
      local number = reaper.GetRegionOrMarkerInfo_Value(0, rm, "I_NUMBER")
      if not is_region and math.floor(number + 0.5) == id then
        found = true
        say("LEGACY MARKER I_LANENUMBER",
          tostring(reaper.GetRegionOrMarkerInfo_Value(0, rm, "I_LANENUMBER")))
        say("LEGACY MARKER I_INDEX",
          tostring(reaper.GetRegionOrMarkerInfo_Value(0, rm, "I_INDEX")))
        break
      end
    end
  end

  if not found then
    say("LEGACY MARKER", "not found by I_NUMBER " .. tostring(id))
  end
end)

-- ------------------------------------------------------------- i) renaming

step("i", function()
  -- resolve fresh: step h added a marker, so the old pointer may be stale
  local rm = probe_marker
  if probe_guid and probe_guid ~= "" then
    rm = reaper.GetRegionOrMarker(0, -1, probe_guid) or probe_marker
  end

  if not rm then
    say("STEP i SKIPPED", "no probe marker")
    return
  end

  say("SET P_NAME retval", tostring(
    reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "probe-renamed", true)))
  local ok, str = reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "", false)
  say("P_NAME readback", string.format("retval=%s str=%q", tostring(ok), tostring(str)))

  say("SET P_NAME empty retval", tostring(
    reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "", true)))
  local empty_ok, empty_str = reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "", false)
  say("P_NAME readback after clear",
    string.format("retval=%s str=%q", tostring(empty_ok), tostring(empty_str)))

  say("MARKER I_LANENUMBER after renames",
    tostring(reaper.GetRegionOrMarkerInfo_Value(0, rm, "I_LANENUMBER")))
end)

-- ------------------------------------------------------------------ j) end

say("CREATE METHOD THAT WORKED", tostring(create_won))

reaper.ShowConsoleMsg(
  "PROBE DONE - save this project as tests/fixtures/lanes_probe.RPP " ..
  "(File > Save project as) and paste this console to the conductor.\n"
)
