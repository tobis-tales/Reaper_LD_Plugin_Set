-- Exercise steelblue_markers.lua against a fake REAPER: a project with markers
-- and regions, a Region/Marker Manager with a list selection, and the various
-- degraded setups (no JS extension, manager closed, old REAPER).

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

-- project: markers 1,2,3 and region 1 interleaved, deliberately out of ID order
local PROJECT = {
  { is_region = false, pos = 10.0, name = "start", id = 1, color = 100 },
  { is_region = true, pos = 12.0, name = "chorus", id = 1, color = 0 },
  { is_region = false, pos = 25.0, name = "verse", id = 2, color = 200 },
  { is_region = false, pos = 5.0, name = "intro", id = 3, color = 300 },
}

local scenario = {}

local function build_reaper()
  local r = {}

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
    r.GetRegionOrMarker = function(_, index) return PROJECT[index + 1] and ("rm" .. index) or nil end
    r.GetRegionOrMarkerInfo_Value = function(_, rm, param)
      local index = tonumber(rm:match("%d+"))
      local e = PROJECT[index + 1]
      if param == "B_ISREGION" then return e.is_region and 1 or 0 end
      if param == "B_UISEL" then
        for _, id in ipairs(scenario.arrange_selected or {}) do
          if not e.is_region and e.id == id then return 1 end
        end
        return 0
      end
      if param == "I_NUMBER" then return e.id end
      return 0
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

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
