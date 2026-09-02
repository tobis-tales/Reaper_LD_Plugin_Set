-- probe_lanes.lua
-- Answers what cannot be answered outside REAPER: what RULER_LANE_ORDER:-1
-- wants in order to create a lane, and how a marker behaves once it sits in
-- one.
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
-- wrong (verified against the doc blocks in the 7.78 binary, 2026-09-02):
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

local function lane_count()
  return tonumber(lane_number("RULER_LANE_COUNT")) or 0
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

say("PROBE", "steelblue ruler lane probe v2")

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

local guids_before = {}
local created_index = nil

step("c", function()
  local before = lane_count()
  guids_before = lane_guids()
  say("COUNT BEFORE CREATE", before)

  -- value is the position of the new lane, 0-based, so `before` appends
  local first = set_lane_number("RULER_LANE_ORDER:-1", before)
  say("CREATE TRY 1 call", string.format("GetSetProjectInfo(0, \"RULER_LANE_ORDER:-1\", %d, true)", before))
  say("CREATE TRY 1 return", tostring(first))
  say("CREATE TRY 1 count after", lane_count())

  if lane_count() == before then
    local second = set_lane_number("RULER_LANE_ORDER:-1", 0)
    say("CREATE TRY 2 call", "GetSetProjectInfo(0, \"RULER_LANE_ORDER:-1\", 0, true)")
    say("CREATE TRY 2 return", tostring(second))
    say("CREATE TRY 2 count after", lane_count())
  end

  if lane_count() == before then
    local third = set_lane_text("RULER_LANE_TYPE", "2")
    say("CREATE TRY 3 call", "GetSetProjectInfo_String(0, \"RULER_LANE_TYPE\", \"2\", true)")
    say("CREATE TRY 3 retval", tostring(third))
    say("CREATE TRY 3 count after", lane_count())
  end

  if lane_count() == before then
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
end)

-- --------------------------------------------------------- g) hide the lane

step("g", function()
  if not created_index then
    say("STEP g SKIPPED", "no new lane")
    return
  end

  say("SET HIDDEN 1 return", tostring(set_lane_number("RULER_LANE_HIDDEN:" .. created_index, 1)))
  say("READBACK HIDDEN", tostring(lane_number("RULER_LANE_HIDDEN:" .. created_index)))
  if probe_marker then
    say("MARKER B_VISIBLE while lane hidden",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  end

  say("SET HIDDEN 0 return", tostring(set_lane_number("RULER_LANE_HIDDEN:" .. created_index, 0)))
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

reaper.ShowConsoleMsg(
  "PROBE DONE - save this project as tests/fixtures/lanes_probe.RPP " ..
  "(File > Save project as) and paste this console to the conductor.\n"
)
