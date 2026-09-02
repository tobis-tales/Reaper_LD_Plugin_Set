-- steelblue_markers.lua
-- Shared Region/Marker Manager access for the steelblue studios package.
--
-- Usage from a script in the same folder:
--   local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
--   local MARKERS = dofile(folder .. "steelblue_markers.lua")
--
-- Reading "which markers did the user select" is the one job several plugins
-- share, and the one with the most edge cases, so it lives here once.

local M = {}

M.VERSION = "1.1"

-- Why callers came up empty, so they can say something useful.
M.NO_API = "no-api"
M.MANAGER_CLOSED = "manager-closed"
M.NONE_SELECTED = "none-selected"
M.NO_LANES = "no-lanes"
M.LANE_CREATE_FAILED = "lane-create-failed"
M.ADD_FAILED = "add-failed"

-- Ruler lanes need all of this together, and AddRegionOrMarker only arrived in
-- 7.72. Below that the lane functions say so and the callers degrade to name
-- and colour, which is what the plugins do today anyway.
local LANE_API = {
  "GetSetProjectInfo_String",
  "GetNumRegionsOrMarkers",
  "GetRegionOrMarker",
  "GetRegionOrMarkerInfo_Value",
  "SetRegionOrMarkerInfo_Value",
  "GetSetRegionOrMarkerInfo_String",
  "AddRegionOrMarker",
}
local LANE_MIN_VERSION = 7.72

local function have(...)
  for _, name in ipairs({ ... }) do
    if not reaper[name] then
      return false
    end
  end
  return true
end

function M.app_version()
  local version = reaper.GetAppVersion and reaper.GetAppVersion() or "0"
  return tonumber((version:match("^(%d+%.%d+)"))) or 0
end

function M.js_available()
  return have(
    "JS_Localize",
    "JS_Window_ArrayFind",
    "JS_Window_HandleFromAddress",
    "JS_Window_FindChildByID",
    "JS_ListView_ListAllSelItems",
    "JS_ListView_GetItemText"
  ) and reaper.new_array ~= nil
end

-- Project markers (never regions), keyed by the ID number shown in the manager.
function M.markers_by_id()
  local by_id = {}
  local index = 0

  while true do
    local ok, is_region, pos, region_end, name, id, color = reaper.EnumProjectMarkers3(0, index)
    if ok == 0 then
      break
    end

    if not is_region then
      by_id[id] = {
        enum_index = index,
        id = id,
        pos = pos,
        name = name,
        color = color or 0,
      }
    end

    index = index + 1
  end

  -- Lane and GUID come from the newer region/marker API; EnumProjectMarkers3
  -- knows nothing about either. Both stay nil when lanes are unavailable, so a
  -- caller can tell "no lane" from "lane 0".
  if M.lanes_available() then
    local total = reaper.GetNumRegionsOrMarkers(0)

    for region_marker_index = 0, total - 1 do
      local region_marker = reaper.GetRegionOrMarker(0, region_marker_index, "")
      if region_marker and reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "B_ISREGION") ~= 1 then
        -- match by displayed ID number, never by index: GetRegionOrMarker counts
        -- markers AND regions, EnumProjectMarkers3 indexes differently
        local id = math.floor(reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_NUMBER") + 0.5)
        local entry = by_id[id]
        if entry then
          local _, guid = reaper.GetSetRegionOrMarkerInfo_String(0, region_marker, "GUID", "", false)
          entry.guid = guid
          entry.lane = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_LANENUMBER")
        end
      end
    end
  end

  return by_id
end

-- Several windows can carry the title "Region/Marker Manager" (docked, floating,
-- other locales); the real one is the one owning child 1056.
function M.manager_window()
  if not M.js_available() then
    return nil
  end

  local title = reaper.JS_Localize("Region/Marker Manager", "common")
  local addresses = reaper.new_array({}, 1024)
  reaper.JS_Window_ArrayFind(title, true, addresses)

  for _, address in ipairs(addresses.table()) do
    local hwnd = reaper.JS_Window_HandleFromAddress(address)
    if hwnd and reaper.JS_Window_FindChildByID(hwnd, 1056) then
      return hwnd
    end
  end

  return nil
end

-- The manager's list selection. This is the only source that knows in which
-- ORDER the user clicked, which the cue numbering depends on.
function M.selected_from_manager()
  if not M.js_available() then
    return nil, M.NO_API
  end

  local window = M.manager_window()
  if not window then
    return nil, M.MANAGER_CLOSED
  end

  local list = reaper.JS_Window_FindChildByID(window, 1071)
  if not list then
    return nil, M.MANAGER_CLOSED
  end

  local count, indexes = reaper.JS_ListView_ListAllSelItems(list)
  if not count or count == 0 then
    return {}, M.NONE_SELECTED
  end

  local by_id = M.markers_by_id()
  local entries = {}
  local order = 0

  for index in tostring(indexes):gmatch("[^,]+") do
    -- column 1 reads "M3" for marker 3, "R2" for region 2
    local type_and_id = reaper.JS_ListView_GetItemText(list, tonumber(index), 1)
    if type_and_id and type_and_id:find("M") then
      local id = tonumber(type_and_id:match("%d+"))
      local entry = id and by_id[id]
      if entry then
        order = order + 1
        entry.selection_order = order
        entries[#entries + 1] = entry
      end
    end
  end

  if #entries == 0 then
    return {}, M.NONE_SELECTED
  end

  return entries
end

-- REAPER 7.62+ reports selection without JS_ReaScriptAPI.
-- Two caveats, both deliberate: B_UISEL is documented as "selected in arrange
-- view", which is not literally the manager's list selection, and it carries no
-- selection order. Fine for copying (which sorts by position anyway), not fine
-- for cue numbering.
function M.selected_from_arrange()
  if not have("GetNumRegionsOrMarkers", "GetRegionOrMarker", "GetRegionOrMarkerInfo_Value") then
    return nil, M.NO_API
  end

  local by_id = M.markers_by_id()
  local total = reaper.GetNumRegionsOrMarkers(0)
  local entries = {}

  for index = 0, total - 1 do
    local region_marker = reaper.GetRegionOrMarker(0, index, "")
    if region_marker then
      local is_region = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "B_ISREGION") == 1
      local is_selected = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "B_UISEL") == 1

      if not is_region and is_selected then
        -- match by displayed ID number, never by index: GetRegionOrMarker counts
        -- markers AND regions, EnumProjectMarkers3 indexes differently
        local id = math.floor(reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_NUMBER") + 0.5)
        local entry = by_id[id]
        if entry then
          entries[#entries + 1] = entry
        end
      end
    end
  end

  if #entries == 0 then
    return {}, M.NONE_SELECTED
  end

  return entries
end

-- Best available selection.
-- Returns entries, reason, source. source is "manager" (ordered) or "arrange"
-- (unordered), so callers that care about order can tell the difference.
function M.selected()
  if M.js_available() then
    local entries, reason = M.selected_from_manager()
    if entries and #entries > 0 then
      return entries, nil, "manager"
    end

    -- manager not open: fall back before giving up, rather than telling the
    -- user to open a window they may not need
    if reason == M.MANAGER_CLOSED then
      local fallback = M.selected_from_arrange()
      if fallback and #fallback > 0 then
        return fallback, nil, "arrange"
      end
    end

    return {}, reason or M.NONE_SELECTED, nil
  end

  local entries, reason = M.selected_from_arrange()
  if entries and #entries > 0 then
    return entries, nil, "arrange"
  end

  return {}, reason or M.NO_API, nil
end


-- ------------------------------------------------------------- ruler lanes
--
-- REAPER has ruler lanes since 7.62, and markers can be assigned to one. Two
-- things about the API decide the shape of everything below:
--
--   * lane descriptors are strings with the index baked in ("RULER_LANE_NAME:2"),
--     and whether that index starts at 0 or 1 is not documented. It is detected
--     at runtime instead of assumed.
--   * a marker pointer is only valid for as long as nothing else changes the
--     project, so every mutation resolves the marker again from its GUID.

local function lane_string(desc)
  local retval, str = reaper.GetSetProjectInfo_String(0, desc, "", false)
  return retval, str
end

local function set_lane_string(desc, value)
  return reaper.GetSetProjectInfo_String(0, desc, value, true)
end

-- Asked fresh every time, never cached: the project can be swapped underneath a
-- running script, and a cached "yes" from another project would be a crash.
function M.lanes_available()
  if M.app_version() < LANE_MIN_VERSION then
    return false
  end

  if not have(table.unpack(LANE_API)) then
    return false
  end

  local retval = lane_string("RULER_LANE_COUNT")
  return retval and true or false
end

function M.lane_count()
  if not M.lanes_available() then
    return 0
  end

  local _, str = lane_string("RULER_LANE_COUNT")
  return tonumber(str) or 0
end

-- 0 or 1. RULER_LANE_NAME:0 answering at all is the tell; with no lanes at all
-- there is nothing to ask, so assume 1 (what the Ruler Lane Manager displays).
function M.lane_index_base()
  if not M.lanes_available() or M.lane_count() == 0 then
    return 1
  end

  local retval = lane_string("RULER_LANE_NAME:0")
  return retval and 0 or 1
end

function M.lane_name(index)
  if not M.lanes_available() then
    return ""
  end

  local retval, str = lane_string("RULER_LANE_NAME:" .. index)
  return retval and str or ""
end

function M.lane_color(index)
  if not M.lanes_available() then
    return nil
  end

  local retval, str = lane_string("RULER_LANE_COLOR:" .. index)
  if not retval then
    return nil
  end

  return tonumber(str)
end

function M.lane_by_name(name)
  if not M.lanes_available() then
    return nil
  end

  local base = M.lane_index_base()
  for index = base, base + M.lane_count() - 1 do
    if M.lane_name(index) == name then
      return index
    end
  end

  return nil
end

-- guid -> index, so a newly created lane can be found by what was not there
-- before. Never "the last lane": REAPER may insert it anywhere.
local function lane_guids()
  local by_guid = {}
  local base = M.lane_index_base()

  for index = base, base + M.lane_count() - 1 do
    local retval, guid = lane_string("RULER_LANE_GUID:" .. index)
    if retval and guid and guid ~= "" then
      by_guid[guid] = index
    end
  end

  return by_guid
end

-- The lane called `name`, created if it is not there yet. Returns index, or
-- nil and a reason.
--
-- An existing lane keeps its colour: the user may well have picked their own,
-- and a second run must not take it away again.
function M.ensure_lane(name, color)
  if not M.lanes_available() then
    return nil, M.NO_LANES
  end

  local existing = M.lane_by_name(name)
  if existing then
    return existing
  end

  local before_count = M.lane_count()
  local before_guids = lane_guids()

  -- ASSUMPTION(probe): value passed to RULER_LANE_ORDER:-1
  set_lane_string("RULER_LANE_ORDER:-1", tostring(before_count + M.lane_index_base()))

  if M.lane_count() == before_count then
    set_lane_string("RULER_LANE_ORDER:-1", "")
  end

  if M.lane_count() == before_count then
    -- whatsnew 7.62 documents RULER_LANE_TYPE for this; the string is gone from
    -- the 7.78 binary, so it is the fallback for 7.62..7.7x builds, not the way
    set_lane_string("RULER_LANE_TYPE", "2")
  end

  if M.lane_count() == before_count then
    return nil, M.LANE_CREATE_FAILED
  end

  local created
  for guid, index in pairs(lane_guids()) do
    if before_guids[guid] == nil then
      created = index
      break
    end
  end

  if not created then
    -- the lane exists but we cannot address it, which is the same problem for
    -- the caller as not having created it
    return nil, M.LANE_CREATE_FAILED
  end

  set_lane_string("RULER_LANE_NAME:" .. created, name)
  if color then
    set_lane_string("RULER_LANE_COLOR:" .. created, tostring(color))
  end

  return created
end

-- Moves a marker into a lane. The return value of SetRegionOrMarkerInfo_Value
-- is documented as meaningless, so the read-back is the only proof.
function M.set_lane(entry, index)
  if not M.lanes_available() or not entry or not entry.guid then
    return false
  end

  local region_marker = reaper.GetRegionOrMarker(0, -1, entry.guid)
  if not region_marker then
    return false
  end

  -- ASSUMPTION(probe): I_LANENUMBER uses the same base as RULER_LANE_*:X
  reaper.SetRegionOrMarkerInfo_Value(0, region_marker, "I_LANENUMBER", index)

  local now = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_LANENUMBER")
  if now ~= index then
    return false
  end

  entry.lane = index
  return true
end

-- Renames a marker in place. On 7.72+ this only writes the name; the old
-- SetProjectMarker4 rewrites the whole marker, which is what puts its lane at
-- risk.
function M.rename(entry, name)
  if not entry then
    return false
  end

  if M.lanes_available() and entry.guid then
    local region_marker = reaper.GetRegionOrMarker(0, -1, entry.guid)
    if region_marker then
      local retval = reaper.GetSetRegionOrMarkerInfo_String(0, region_marker, "P_NAME", name, true)
      if retval then
        entry.name = name
      end
      return retval and true or false
    end
  end

  local retval = reaper.SetProjectMarker4(
    0, entry.id, false, entry.pos, 0, name, entry.color, name == "" and 1 or 0
  )

  if retval then
    entry.name = name
  end

  return retval and true or false
end

-- Creates a marker, in a lane when the build can do it. Returns an entry in the
-- same shape markers_by_id produces, or nil and a reason. A lane that was asked
-- for but could not be honoured comes back as the reason "no-lanes" alongside a
-- perfectly good marker -- the caller decides whether that matters.
function M.add_marker(pos, name, color, lane)
  if M.lanes_available() then
    local region_marker = reaper.AddRegionOrMarker(0, false, pos, 0, name, -1, color or 0)
    if not region_marker then
      return nil, M.ADD_FAILED
    end

    if lane then
      -- ASSUMPTION(probe): I_LANENUMBER uses the same base as RULER_LANE_*:X
      reaper.SetRegionOrMarkerInfo_Value(0, region_marker, "I_LANENUMBER", lane)
    end

    local _, guid = reaper.GetSetRegionOrMarkerInfo_String(0, region_marker, "GUID", "", false)

    return {
      id = math.floor(reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_NUMBER") + 0.5),
      guid = guid,
      lane = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "I_LANENUMBER"),
      pos = pos,
      name = name,
      color = color or 0,
    }
  end

  local id = reaper.AddProjectMarker2(0, false, pos, 0, name, -1, color or 0)
  if not id then
    return nil, M.ADD_FAILED
  end

  return {
    id = id,
    guid = nil,
    lane = nil,
    pos = pos,
    name = name,
    color = color or 0,
  }, lane and M.NO_LANES or nil
end

-- A copy in timeline order. The input keeps the caller's click order, which
-- the cue numbering depends on.
function M.sorted_by_position(entries)
  local copy = {}
  for index, entry in ipairs(entries) do
    copy[index] = entry
  end

  table.sort(copy, function(left, right)
    if left.pos == right.pos then
      return left.id < right.id
    end
    return left.pos < right.pos
  end)

  return copy
end

return M
