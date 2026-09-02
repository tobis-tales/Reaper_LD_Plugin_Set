-- probe_lanes.lua
-- Answers the three open ruler-lane questions that cannot be answered outside
-- REAPER: where the lane index starts (0 or 1), what value RULER_LANE_ORDER:-1
-- wants, and how markers behave once they sit in a lane.
--
-- HOW TO RUN
--   1. Open a NEW, EMPTY project (File -> New project). This script creates a
--      lane and two markers, so do not run it in real work.
--   2. Actions -> Show action list -> "Load ReaScript..." -> pick this file.
--   3. Copy the whole console text and hand it back.
--   4. Save the project as tests/fixtures/lanes_probe.RPP.
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

local function lane_string(desc)
  local retval, str = reaper.GetSetProjectInfo_String(0, desc, "", false)
  return retval, str
end

local function lane_count()
  local _, str = lane_string("RULER_LANE_COUNT")
  return tonumber(str) or 0
end

-- X = 0..count covers both possible index bases without assuming one.
local function list_lanes(tag)
  local count = lane_count()
  say(tag .. " COUNT", count)
  for x = 0, count do
    local name_ok, name = lane_string("RULER_LANE_NAME:" .. x)
    local color_ok, color = lane_string("RULER_LANE_COLOR:" .. x)
    local guid_ok, guid = lane_string("RULER_LANE_GUID:" .. x)
    say(tag .. " LANE " .. x, string.format(
      "name_ok=%s name=%q color_ok=%s color=%q guid_ok=%s guid=%q",
      tostring(name_ok), tostring(name),
      tostring(color_ok), tostring(color),
      tostring(guid_ok), tostring(guid)
    ))
  end
end

-- GUID -> index, for spotting which lane is the new one.
local function lane_guids()
  local by_guid, in_order = {}, {}
  for x = 0, lane_count() do
    local ok, guid = lane_string("RULER_LANE_GUID:" .. x)
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

say("PROBE", "steelblue ruler lane probe")

-- ------------------------------------------------------------------ a) API

step("a", function()
  say("APP_VERSION", reaper.GetAppVersion and reaper.GetAppVersion() or "unknown")

  local names = {
    "GetSetProjectInfo_String",
    "GetNumRegionsOrMarkers",
    "GetRegionOrMarker",
    "GetRegionOrMarkerInfo_Value",
    "SetRegionOrMarkerInfo_Value",
    "GetSetRegionOrMarkerInfo_String",
    "AddRegionOrMarker",
    "AddProjectMarker2",
    "ColorToNative",
  }

  for _, name in ipairs(names) do
    say("HAS " .. name, reaper[name] ~= nil and "yes" or "no")
  end
end)

-- ------------------------------------------------------- b) count and base

step("b", function()
  local count_ok, count_str = lane_string("RULER_LANE_COUNT")
  say("RULER_LANE_COUNT retval", tostring(count_ok))
  say("RULER_LANE_COUNT str", string.format("%q", tostring(count_str)))

  local zero_ok, zero_str = lane_string("RULER_LANE_NAME:0")
  say("RULER_LANE_NAME:0 retval", tostring(zero_ok))
  say("RULER_LANE_NAME:0 str", string.format("%q", tostring(zero_str)))

  local one_ok, one_str = lane_string("RULER_LANE_NAME:1")
  say("RULER_LANE_NAME:1 retval", tostring(one_ok))
  say("RULER_LANE_NAME:1 str", string.format("%q", tostring(one_str)))

  say("LANE_INDEX_BASE (from NAME:0 retval)", zero_ok and 0 or 1)

  list_lanes("BEFORE")
end)

-- -------------------------------------------------------- c) create a lane

local guids_before = {}
local created_index = nil

step("c", function()
  local before = lane_count()
  guids_before = lane_guids()
  say("COUNT BEFORE CREATE", before)

  local attempts = {
    { desc = "RULER_LANE_ORDER:-1", value = tostring(before + 1) },
    { desc = "RULER_LANE_ORDER:-1", value = tostring(before) },
    { desc = "RULER_LANE_ORDER:-1", value = "" },
    { desc = "RULER_LANE_TYPE",     value = "2" },
    { desc = "RULER_LANE_TYPE",     value = "1" },
  }

  for index, attempt in ipairs(attempts) do
    local retval = reaper.GetSetProjectInfo_String(0, attempt.desc, attempt.value, true)
    local after = lane_count()
    say(string.format("CREATE TRY %d desc", index), attempt.desc)
    say(string.format("CREATE TRY %d value", index), string.format("%q", attempt.value))
    say(string.format("CREATE TRY %d retval", index), tostring(retval))
    say(string.format("CREATE TRY %d count after", index), after)

    if after > before then
      say("CREATE WORKED VIA", attempt.desc .. " = " .. string.format("%q", attempt.value))
      break
    end
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
  say("SET NAME retval", tostring(
    reaper.GetSetProjectInfo_String(0, "RULER_LANE_NAME:" .. created_index, "probe", true)))
  say("SET COLOR value", color)
  say("SET COLOR retval", tostring(
    reaper.GetSetProjectInfo_String(0, "RULER_LANE_COLOR:" .. created_index, tostring(color), true)))

  for _, param in ipairs({ "NAME", "COLOR", "GUID", "DEFAULT", "TIMEBASE", "HIDDEN", "VISIBLE" }) do
    local desc = "RULER_LANE_" .. param .. ":" .. created_index
    local ok, str = lane_string(desc)
    say("READBACK " .. desc, string.format("retval=%s str=%q", tostring(ok), tostring(str)))
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
  say("SET I_LANENUMBER arg", created_index)
  say("SET I_LANENUMBER retval", tostring(retval))
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

  say("SET HIDDEN 1 retval", tostring(
    reaper.GetSetProjectInfo_String(0, "RULER_LANE_HIDDEN:" .. created_index, "1", true)))
  if probe_marker then
    say("MARKER B_VISIBLE while lane hidden",
      tostring(reaper.GetRegionOrMarkerInfo_Value(0, probe_marker, "B_VISIBLE")))
  end

  say("SET HIDDEN 0 retval", tostring(
    reaper.GetSetProjectInfo_String(0, "RULER_LANE_HIDDEN:" .. created_index, "0", true)))
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
end)

-- ------------------------------------------------------------------ j) end

reaper.ShowConsoleMsg(
  "PROBE DONE - save this project as tests/fixtures/lanes_probe.RPP " ..
  "and paste this console to the conductor.\n"
)
