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

M.VERSION = "1.0"

-- Why callers came up empty, so they can say something useful.
M.NO_API = "no-api"
M.MANAGER_CLOSED = "manager-closed"
M.NONE_SELECTED = "none-selected"

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

-- Loader helper so a missing module file gives a sentence, not a traceback.
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
