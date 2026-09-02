-- Exercise steelblue_markers.lua against a fake REAPER: a project with markers
-- and regions, a Region/Marker Manager with a list selection, the various
-- degraded setups (no JS extension, manager closed, old REAPER), and ruler
-- lanes.
--
-- The lane half of the fake deliberately inserts a newly created lane at the
-- FRONT. REAPER may put it anywhere, and "the last lane is the new one" is the
-- assumption the module must not make.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

-- project: markers 1,2,3 and region 1 interleaved, deliberately out of ID order
local BASE_PROJECT = {
  { is_region = false, pos = 10.0, name = "start", id = 1, color = 100, guid = "{M1}" },
  { is_region = true, pos = 12.0, name = "chorus", id = 1, color = 0, guid = "{R1}" },
  { is_region = false, pos = 25.0, name = "verse", id = 2, color = 200, guid = "{M2}" },
  { is_region = false, pos = 5.0, name = "intro", id = 3, color = 300, guid = "{M3}" },
}

local scenario = {}
local PROJECT = {}
local lanes = {}
local lane_base = 1
local next_marker_id = 3
local calls = {}

-- a fresh project per scenario, or markers created in one leak into the next
local function copy_project()
  local copy = {}
  for index, entry in ipairs(BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do
      clone[key] = value
    end
    clone.lane = lane_base
    copy[index] = clone
  end
  return copy
end

local function lane_at(descriptor_index)
  return lanes[descriptor_index - lane_base + 1]
end

local function insert_lane()
  -- at the front on purpose: see the header
  table.insert(lanes, 1, { name = "", color = "", guid = "{Lnew" .. (#lanes + 1) .. "}" })
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

local function build_reaper()
  local r = {}

  lane_base = scenario.lane_base or 1
  lanes = {}
  for _, lane in ipairs(scenario.lanes or {}) do
    lanes[#lanes + 1] = {
      name = lane.name, color = lane.color, guid = lane.guid or ("{L" .. (#lanes + 1) .. "}"),
    }
  end
  PROJECT = copy_project()
  next_marker_id = 3
  calls = {}

  r.EnumProjectMarkers3 = function(_, index)
    local e = PROJECT[index + 1]
    if not e then return 0 end
    return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
  end

  r.GetAppVersion = function() return scenario.version or "7.75/OSX64" end

  if scenario.js then
    r.new_array = function() return { table = function() return { 1234 } end } end
    r.JS_Localize = function(s) return s end
    r.JS_Window_ArrayFind = function() end
    r.JS_Window_HandleFromAddress = function() return scenario.manager_open and "hwnd" or nil end
    r.JS_Window_FindChildByID = function(_, id)
      if not scenario.manager_open then return nil end
      if id == 1056 then return "listcontainer" end
      if id == 1071 then return "listview" end
      return nil
    end
    r.JS_ListView_ListAllSelItems = function()
      local sel = scenario.selected_rows or {}
      return #sel, table.concat(sel, ",")
    end
    r.JS_ListView_GetItemText = function(_, row)
      -- rows mirror PROJECT order: M1, R1, M2, M3
      local labels = { [0] = "M1", [1] = "R1", [2] = "M2", [3] = "M3" }
      return labels[row]
    end
  end

  if scenario.new_api then
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
    r.GetRegionOrMarkerInfo_Value = function(_, e, param)
      if param == "B_ISREGION" then return e.is_region and 1 or 0 end
      if param == "B_UISEL" then
        for _, id in ipairs(scenario.arrange_selected or {}) do
          if not e.is_region and e.id == id then return 1 end
        end
        return 0
      end
      if param == "I_NUMBER" then return e.id end
      if param == "I_LANENUMBER" then return e.lane end
      return 0
    end
  end

  -- the discouraged calls exist on every REAPER, so a test can prove the module
  -- did NOT reach for them
  r.SetProjectMarker4 = function(_, id, isrgn, pos, rgnend, name, color, flags)
    calls[#calls + 1] = {
      kind = "set_project_marker4",
      id = id, isrgn = isrgn, pos = pos, name = name, color = color, flags = flags,
    }
    return true
  end

  r.AddProjectMarker2 = function(_, isrgn, pos, rgnend, name, wantidx, color)
    next_marker_id = next_marker_id + 1
    PROJECT[#PROJECT + 1] = {
      is_region = isrgn, pos = pos, name = name, id = next_marker_id, color = color,
    }
    calls[#calls + 1] = { kind = "add_project_marker2", pos = pos, name = name, color = color }
    return next_marker_id
  end

  if scenario.lane_api then
    r.GetSetProjectInfo_String = function(_, desc, value, is_set)
      if desc == "RULER_LANE_COUNT" then
        -- a 7.78 build whose project has no lane support answers false here,
        -- which is the module's whole feature detection
        if not scenario.lanes or is_set then return false, "" end
        return true, tostring(#lanes)
      end

      if not scenario.lanes then return false, "" end

      if desc == "RULER_LANE_ORDER:-1" and is_set then
        calls[#calls + 1] = { kind = "lane_order", value = value }
        if scenario.create_via == "order" then
          insert_lane()
          return true
        end
        return false
      end

      if desc == "RULER_LANE_TYPE" and is_set then
        calls[#calls + 1] = { kind = "lane_type", value = value }
        if scenario.create_via == "type" then
          insert_lane()
          return true
        end
        return false
      end

      local param, index = desc:match("^RULER_LANE_(%u+):(-?%d+)$")
      if not param then return false, "" end

      local lane = lane_at(tonumber(index))
      if not lane then return false, "" end

      local key = param:lower()
      if key == "guid" then
        if is_set then return false, "" end
        return true, lane.guid
      end

      if is_set then
        lane[key] = value
        return true
      end

      return true, tostring(lane[key] or "")
    end

    r.AddRegionOrMarker = function(_, isrgn, pos, rgnend, name, wantidx, color)
      next_marker_id = next_marker_id + 1
      local entry = {
        is_region = isrgn, pos = pos, name = name, id = next_marker_id, color = color,
        lane = lane_base, guid = "{Mnew" .. next_marker_id .. "}",
      }
      PROJECT[#PROJECT + 1] = entry
      calls[#calls + 1] = { kind = "add_region_or_marker", pos = pos, name = name, color = color }
      return entry
    end

    r.SetRegionOrMarkerInfo_Value = function(_, e, param, value)
      if param == "I_LANENUMBER" then
        e.lane = value
        calls[#calls + 1] = { kind = "set_lane", guid = e.guid, value = value }
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

local function run(name, setup, check)
  scenario = setup
  reaper = build_reaper()
  package.loaded.markers = nil
  local M = dofile(folder .. "steelblue_markers.lua")
  local entries, reason, source = M.selected()
  local ok, detail = check(M, entries, reason, source)
  print(string.format("%-42s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok
end

local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

print("steelblue_markers.lua behaviour:\n")

check(run("manager: 2 markers selected, ordered", {
  js = true, manager_open = true, selected_rows = { 3, 0 }, -- clicked M3 then M1
}, function(M, e, reason, source)
  if #e ~= 2 then return false, "got " .. #e .. " entries" end
  if source ~= "manager" then return false, "source=" .. tostring(source) end
  if e[1].id ~= 3 or e[2].id ~= 1 then return false, "wrong ids" end
  if e[1].selection_order ~= 1 or e[2].selection_order ~= 2 then return false, "order lost" end
  return true, "click order M3,M1 preserved"
end))

check(run("manager: region in selection is ignored", {
  js = true, manager_open = true, selected_rows = { 0, 1, 2 }, -- M1, R1, M2
}, function(M, e)
  if #e ~= 2 then return false, "got " .. #e end
  if e[1].id ~= 1 or e[2].id ~= 2 then return false, "wrong ids" end
  return true, "region dropped"
end))

check(run("manager: nothing selected", {
  js = true, manager_open = true, selected_rows = {},
}, function(M, e, reason)
  return #e == 0 and reason == M.NONE_SELECTED, "reason=" .. tostring(reason)
end))

check(run("manager closed -> arrange fallback", {
  js = true, manager_open = false, new_api = true, arrange_selected = { 2, 3 },
}, function(M, e, reason, source)
  if #e ~= 2 then return false, "got " .. #e end
  if source ~= "arrange" then return false, "source=" .. tostring(source) end
  return true, "found 2 via B_UISEL"
end))

check(run("manager closed, nothing in arrange", {
  js = true, manager_open = false, new_api = true, arrange_selected = {},
}, function(M, e, reason)
  return #e == 0 and reason == M.MANAGER_CLOSED, "reason=" .. tostring(reason)
end))

check(run("no JS extension, REAPER 7.75", {
  js = false, new_api = true, arrange_selected = { 1 },
}, function(M, e, reason, source)
  return #e == 1 and source == "arrange", "works without JS"
end))

check(run("no JS, old REAPER (no new API)", {
  js = false, new_api = false,
}, function(M, e, reason)
  return #e == 0 and reason == M.NO_API, "reason=" .. tostring(reason)
end))

check(run("sorted_by_position orders the copy", {
  js = true, manager_open = true, selected_rows = { 3, 0, 2 }, -- M3(5.0) M1(10.0) M2(25.0)
}, function(M, e)
  local sorted = M.sorted_by_position(e)
  if sorted[1].pos ~= 5.0 or sorted[2].pos ~= 10.0 or sorted[3].pos ~= 25.0 then
    return false, "wrong order"
  end
  -- original click order must survive untouched
  if e[1].id ~= 3 or e[2].id ~= 1 or e[3].id ~= 2 then return false, "input mutated" end
  return true, "5.0, 10.0, 25.0"
end))

-- ------------------------------------------------------------- ruler lanes
--
-- These do not go through selected(), so they get their own runner.

local function run_lane(name, setup, fn)
  scenario = setup
  reaper = build_reaper()
  local M = dofile(folder .. "steelblue_markers.lua")
  local ok, detail = fn(M)
  print(string.format("%-42s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok
end

local LANES_178 = function(extra)
  local setup = {
    version = "7.78/OSX64", new_api = true, lane_api = true, lane_base = 1,
    lanes = { { name = "Kick", color = 111 }, { name = "Snare", color = 222 } },
  }
  for key, value in pairs(extra or {}) do setup[key] = value end
  return setup
end

print("")

check(run_lane("7.78 but no lane support: nothing pretends", {
  version = "7.78/OSX64", new_api = true, lane_api = true, lanes = nil,
}, function(M)
  if M.lanes_available() then return false, "claims lanes" end
  if M.lane_count() ~= 0 then return false, "count " .. M.lane_count() end
  local by_id = M.markers_by_id()
  if by_id[1].lane ~= nil or by_id[1].guid ~= nil then
    return false, "lane/guid filled in anyway"
  end
  return true, "RULER_LANE_COUNT said no"
end))

check(run_lane("lanes, 1-based: entries carry lane and guid", LANES_178(), function(M)
  if not M.lanes_available() then return false, "no lanes" end
  if M.lane_index_base() ~= 1 then return false, "base " .. M.lane_index_base() end
  if M.lane_count() ~= 2 then return false, "count " .. M.lane_count() end
  local by_id = M.markers_by_id()
  if by_id[1].guid ~= "{M1}" then return false, "guid=" .. tostring(by_id[1].guid) end
  if by_id[1].lane ~= 1 then return false, "lane=" .. tostring(by_id[1].lane) end
  if by_id[3].guid ~= "{M3}" then return false, "guid=" .. tostring(by_id[3].guid) end
  return true, "guid {M1}, lane 1"
end))

check(run_lane("lanes, 0-based: base detected, not assumed", LANES_178({
  lane_base = 0,
}), function(M)
  if M.lane_index_base() ~= 0 then return false, "base " .. M.lane_index_base() end
  if M.lane_by_name("Kick") ~= 0 then return false, "Kick at " .. tostring(M.lane_by_name("Kick")) end
  if M.lane_by_name("Snare") ~= 1 then return false, "Snare at " .. tostring(M.lane_by_name("Snare")) end
  local by_id = M.markers_by_id()
  return by_id[1].lane == 0, "markers report lane 0"
end))

check(run_lane("lane_by_name: hit and miss", LANES_178(), function(M)
  if M.lane_by_name("Kick") ~= 1 then return false, "Kick at " .. tostring(M.lane_by_name("Kick")) end
  if M.lane_by_name("Snare") ~= 2 then return false, "Snare at " .. tostring(M.lane_by_name("Snare")) end
  if M.lane_name(2) ~= "Snare" then return false, "lane_name(2)=" .. M.lane_name(2) end
  return M.lane_by_name("Hat") == nil, "no lane called Hat"
end))

check(run_lane("ensure_lane reuses, and keeps its colour", LANES_178({
  create_via = "order",
}), function(M)
  local index, reason = M.ensure_lane("Kick", 999)
  if index ~= 1 then return false, "index=" .. tostring(index) .. " reason=" .. tostring(reason) end
  if M.lane_count() ~= 2 then return false, "created one anyway: " .. M.lane_count() end
  if M.lane_color(1) ~= 111 then return false, "colour became " .. tostring(M.lane_color(1)) end
  return true, "lane 1, colour 111 untouched"
end))

check(run_lane("ensure_lane creates via RULER_LANE_ORDER:-1", LANES_178({
  lanes = { { name = "Kick", color = 111 } }, create_via = "order",
}), function(M)
  local index, reason = M.ensure_lane("Snare", 222)
  if not index then return false, "reason=" .. tostring(reason) end
  if M.lane_count() ~= 2 then return false, "count " .. M.lane_count() end
  -- the fake inserts at the front, so "the last lane" would answer 2 here
  if index ~= 1 then return false, "found lane " .. index .. ", not the new one" end
  if M.lane_name(1) ~= "Snare" then return false, "name " .. M.lane_name(1) end
  if M.lane_color(1) ~= 222 then return false, "colour " .. tostring(M.lane_color(1)) end
  if M.lane_name(2) ~= "Kick" or M.lane_color(2) ~= 111 then
    return false, "the existing lane was disturbed"
  end
  return true, "new lane found by GUID, not by position"
end))

check(run_lane("ensure_lane falls back to RULER_LANE_TYPE", LANES_178({
  lanes = { { name = "Kick", color = 111 } }, create_via = "type",
}), function(M)
  local index, reason = M.ensure_lane("Snare", 222)
  if not index then return false, "reason=" .. tostring(reason) end
  if count("lane_order") ~= 2 then return false, count("lane_order") .. " ORDER attempts" end
  if count("lane_type") ~= 1 then return false, count("lane_type") .. " TYPE attempts" end
  if M.lane_name(index) ~= "Snare" then return false, "name " .. M.lane_name(index) end
  return M.lane_count() == 2, "ORDER twice, then TYPE"
end))

check(run_lane("ensure_lane gives up honestly", LANES_178({
  lanes = { { name = "Kick", color = 111 } }, create_via = "none",
}), function(M)
  local index, reason = M.ensure_lane("Snare", 222)
  if index ~= nil then return false, "claims lane " .. tostring(index) end
  if M.lane_count() ~= 1 then return false, "count changed" end
  return reason == M.LANE_CREATE_FAILED, "reason=" .. tostring(reason)
end))

check(run_lane("set_lane writes and reads back", LANES_178(), function(M)
  local entry = M.markers_by_id()[2]
  if not M.set_lane(entry, 2) then return false, "returned false" end
  local call = last("set_lane")
  if not call or call.guid ~= "{M2}" or call.value ~= 2 then return false, "wrong set call" end
  if entry.lane ~= 2 then return false, "entry still says " .. tostring(entry.lane) end
  return M.markers_by_id()[2].lane == 2, "marker 2 is in lane 2"
end))

check(run_lane("rename on 7.78 writes only the name", LANES_178(), function(M)
  local entry = M.markers_by_id()[1]
  if not M.rename(entry, "drop") then return false, "returned false" end
  if count("set_project_marker4") ~= 0 then return false, "reached for SetProjectMarker4" end
  local call = last("set_name")
  if not call or call.guid ~= "{M1}" or call.name ~= "drop" then return false, "wrong P_NAME call" end
  return M.markers_by_id()[1].name == "drop", "P_NAME via GUID, lane untouched"
end))

check(run_lane("rename on 7.75 falls back to SetProjectMarker4", {
  version = "7.75/OSX64", new_api = true,
}, function(M)
  local entry = M.markers_by_id()[1]
  if not M.rename(entry, "drop") then return false, "returned false" end
  local call = last("set_project_marker4")
  if not call then return false, "nothing written" end
  if call.id ~= 1 or call.pos ~= 10.0 or call.name ~= "drop" or call.color ~= 100 then
    return false, "wrong arguments"
  end
  if call.isrgn ~= false then return false, "wrote a region" end
  if call.flags ~= 0 then return false, "clear flag " .. tostring(call.flags) end
  M.rename(entry, "")
  return last("set_project_marker4").flags == 1, "clear flag 1 for an empty name"
end))

check(run_lane("add_marker creates in the lane", LANES_178(), function(M)
  local entry, reason = M.add_marker(30.0, "drop", 555, 2)
  if not entry then return false, "reason=" .. tostring(reason) end
  if reason ~= nil then return false, "reason=" .. tostring(reason) end
  if count("add_region_or_marker") ~= 1 then return false, "wrong creation call" end
  if count("add_project_marker2") ~= 0 then return false, "used the discouraged call" end
  if not entry.guid then return false, "no guid" end
  if entry.lane ~= 2 then return false, "lane " .. tostring(entry.lane) end
  return M.markers_by_id()[entry.id].lane == 2, "marker " .. entry.id .. " in lane 2"
end))

check(run_lane("add_marker on 7.75: no lane, and it says so", {
  version = "7.75/OSX64", new_api = true,
}, function(M)
  local entry, reason = M.add_marker(30.0, "drop", 555, 2)
  if not entry then return false, "nothing created" end
  if reason ~= M.NO_LANES then return false, "reason=" .. tostring(reason) end
  if count("add_project_marker2") ~= 1 then return false, "wrong creation call" end
  if count("add_region_or_marker") ~= 0 then return false, "called an API that is not there" end
  if entry.lane ~= nil or entry.guid ~= nil then return false, "invented lane/guid" end
  return entry.id ~= nil and entry.name == "drop", "id " .. tostring(entry.id) .. ", no lane"
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
