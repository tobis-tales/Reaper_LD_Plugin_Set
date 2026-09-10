-- Phase 2b: Copy Markers must keep each marker's ruler lane when copying, and
-- must tell the user once at start-up if ReaImGui or JS_ReaScriptAPI is
-- missing, via steelblue_boot.check_dependencies.
--
-- Drives CopyMarkers.lua exactly like copy_click_test.lua (dofile, capture
-- the deferred loop, fire "Copy to cursor" by its button label) against a
-- fake REAPER built the way markers_test.lua builds one: a project, a
-- Region/Marker Manager selection, and -- for 7.78 -- the split lane API
-- (numeric GetSetProjectInfo answering RULER_LANE_COUNT = 3.0, string
-- GetSetProjectInfo_String answering only NAME/GUID -- everything else,
-- COUNT included, reads false there, which is the split the first probe run
-- got wrong).

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

-- Names that must read as MISSING when a scenario does not enable them --
-- the generic fallback below answers every unknown reaper.* call with a
-- harmless stub (needed so the ReaImGui frame renders without special-casing
-- every widget call), which would otherwise make "the extension is missing"
-- impossible to simulate: reaper.somename would never be nil.
local GATED_NAMES = {}
for _, name in ipairs({
  "JS_Localize", "JS_Window_ArrayFind", "JS_Window_HandleFromAddress",
  "JS_Window_FindChildByID", "JS_ListView_ListAllSelItems", "JS_ListView_GetItemText",
  "new_array",
  "GetSetProjectInfo", "GetSetProjectInfo_String", "GetNumRegionsOrMarkers",
  "GetRegionOrMarker", "GetRegionOrMarkerInfo_Value", "SetRegionOrMarkerInfo_Value",
  "GetSetRegionOrMarkerInfo_String", "AddRegionOrMarker",
}) do
  GATED_NAMES[name] = true
end

-- Three markers, spread out, each in a different lane -- lane 0 included on
-- purpose: a copy that lands in "no lane" must not be mistaken for a copy
-- correctly placed in lane 0.
local BASE_PROJECT = {
  { pos = 0.0,  name = "one",   id = 1, color = 100, lane = 2, guid = "{M1}" },
  { pos = 3.0,  name = "two",   id = 2, color = 200, lane = 1, guid = "{M2}" },
  { pos = 6.25, name = "three", id = 3, color = 300, lane = 0, guid = "{M3}" },
}

-- New markers land here first, distinct from every lane already used above,
-- so a copy that never gets its lane set is caught instead of accidentally
-- matching a real lane index (in particular lane 0).
local UNSET_LANE = 9

local function build_reaper(scenario)
  local PROJECT = {}
  for index, entry in ipairs(BASE_PROJECT) do
    local clone = {}
    for key, value in pairs(entry) do clone[key] = value end
    PROJECT[index] = clone
  end

  local added = {}
  local calls = {}
  local boxes = {}
  local click_label = nil
  local deferred = nil
  local footer_text = nil
  local next_id = #PROJECT

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn end,
    GetCursorPosition = function() return 100.0 end,
    format_timestr_pos = function() return "19.3.00" end,
    parse_timestr_pos = function() return 100.0 end,
    EnumProjectMarkers3 = function(_, i)
      local e = PROJECT[i + 1]
      if not e then return 0 end
      return 1, false, e.pos, e.pos, e.name, e.id, e.color
    end,
    ShowMessageBox = function(m) boxes[#boxes + 1] = m return 0 end,
    GetAppVersion = function() return scenario.version end,
    Undo_BeginBlock = function() end,
    Undo_EndBlock = function() end,
    PreventUIRefresh = function() end,
    UpdateArrange = function() end,
  }

  if scenario.js then
    specific.new_array = function() return { table = function() return { 1234 } end } end
    specific.JS_Localize = function(s) return s end
    specific.JS_Window_ArrayFind = function() return 1 end
    specific.JS_Window_HandleFromAddress = function() return "hwnd" end
    specific.JS_Window_FindChildByID = function(_, id)
      if id == 1056 then return "container" end
      if id == 1071 then return "listview" end
      return nil
    end
    specific.JS_ListView_ListAllSelItems = function()
      local rows = scenario.selected_rows or {}
      return #rows, table.concat(rows, ",")
    end
    specific.JS_ListView_GetItemText = function(_, row)
      local e = PROJECT[row + 1]
      return e and ("M" .. e.id) or nil
    end
  end

  if scenario.lanes then
    specific.GetSetProjectInfo = function(_, desc, value, is_set)
      if desc == "RULER_LANE_COUNT" then return 3.0 end
      return 0
    end
    specific.GetSetProjectInfo_String = function(_, desc, value, is_set)
      local param = desc:match("^RULER_LANE_(%u+):")
      if param == "NAME" or param == "GUID" then return true, "" end
      -- every numeric descriptor, COUNT included, reads false here
      return false, ""
    end
    specific.GetNumRegionsOrMarkers = function() return #PROJECT end
    specific.GetRegionOrMarker = function(_, index, guid)
      if index and index >= 0 then return PROJECT[index + 1] end
      for _, e in ipairs(PROJECT) do
        if e.guid == guid then return e end
      end
      return nil
    end
    specific.GetRegionOrMarkerInfo_Value = function(_, e, param)
      if param == "B_ISREGION" then return 0 end
      if param == "I_NUMBER" then return e.id end
      if param == "I_LANENUMBER" then return (e.lane or 0) + 0.0 end
      return 0
    end
    specific.GetSetRegionOrMarkerInfo_String = function(_, e, param, str, is_set)
      if param == "GUID" then return true, e.guid end
      if param == "P_NAME" then
        if is_set then
          e.name = str
          return true
        end
        return true, e.name
      end
      return false, ""
    end
    specific.SetRegionOrMarkerInfo_Value = function(_, e, param, value)
      if param == "I_LANENUMBER" then
        e.lane = value
        calls[#calls + 1] = { kind = "set_lane", guid = e.guid, value = value }
      end
      return 0
    end
    specific.AddRegionOrMarker = function(_, isrgn, pos, rgnend, name, wantidx, color)
      next_id = next_id + 1
      local entry = {
        pos = pos, name = name, id = next_id, color = color,
        lane = UNSET_LANE, guid = "{Mnew" .. next_id .. "}",
      }
      PROJECT[#PROJECT + 1] = entry
      added[#added + 1] = entry
      calls[#calls + 1] = { kind = "add_region_or_marker", pos = pos, name = name, color = color }
      return entry
    end
  end

  specific.AddProjectMarker2 = function(_, isrgn, pos, rgnend, name, wantidx, color)
    next_id = next_id + 1
    local entry = { pos = pos, name = name, id = next_id, color = color }
    added[#added + 1] = entry
    calls[#calls + 1] = { kind = "add_project_marker2", pos = pos, name = name, color = color }
    return next_id
  end

  local r = setmetatable({}, {
    __index = function(_, key)
      if specific[key] then return specific[key] end
      if GATED_NAMES[key] then return nil end
      if key:match("^ImGui_") then
        if not real_imgui[key] then return nil end
        return function(_, a, b)
          if key == "ImGui_CreateContext" then return "ctx" end
          if key == "ImGui_CreateFont" then return "font" end
          if key == "ImGui_GetWindowDrawList" then return "dl" end
          if key == "ImGui_Begin" then return true, true end
          if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
          if key == "ImGui_GetContentRegionAvail" then return 400, 300 end
          if key == "ImGui_CalcTextSize" then return 50, 12 end
          if key == "ImGui_Button" then return a == click_label end
          if key == "ImGui_Checkbox" then return false, a end
          if key == "ImGui_InputText" then return false, "19.3.00" end
          if key == "ImGui_InputInt" then return false, 24 end
          if key == "ImGui_DrawList_AddTextEx" then return nil end
          if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
            or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
          return nil
        end
      end
      return function() return 0 end
    end,
  })

  local real_index = getmetatable(r).__index
  setmetatable(r, { __index = function(t, key)
    local fn = real_index(t, key)
    if key == "ImGui_DrawList_AddTextEx" then
      return function(dl, font, size, x, y, col, text)
        if size == 11 then footer_text = text end
        return nil
      end
    end
    return fn
  end })

  return r, {
    added = added,
    calls = calls,
    boxes = boxes,
    click = function(label)
      click_label = label
      return deferred()
    end,
    frame = function() return deferred() end,
    footer = function() return footer_text end,
  }
end

local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

-- Drives one click of "Copy to cursor", the same three-frame dance as
-- copy_click_test.lua: frame 1 (no click, just to poll the selection once),
-- frame 2 (click -- the footer still shows the OLD status, because the
-- footer draws before the queued work runs), frame 3 (no click, footer now
-- shows the result).
local function run_click(name, scenario, check_fn)
  local helpers
  reaper, helpers = build_reaper(scenario)

  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then
    print(string.format("%-58s FAIL  -- load error: %s", name, tostring(err)))
    return false
  end

  helpers.frame()
  helpers.click("Copy to cursor")
  helpers.click(nil)

  local ok2, detail = check_fn(helpers)
  print(string.format("%-58s %s%s", name, ok2 and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok2
end

-- check_dependencies runs at the top of the script, before any frame is
-- rendered, so no click is needed here -- just load and inspect the boxes.
local function run_load(name, scenario, check_fn)
  local helpers
  reaper, helpers = build_reaper(scenario)

  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then
    print(string.format("%-58s FAIL  -- load error: %s", name, tostring(err)))
    return false
  end

  local ok2, detail = check_fn(helpers)
  print(string.format("%-58s %s%s", name, ok2 and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok2
end

print("CopyMarkers.lua -- lane preservation and start-up dependency check:\n")

check(run_click("a) 7.78: copies land in the same lanes as their originals", {
  version = "7.78/OSX64", lanes = true, js = true, manager_open = true, selected_rows = { 0, 1, 2 },
}, function(h)
  if #h.added ~= 3 then return false, "added " .. #h.added end

  local want = {
    [1] = { name = "one", color = 100, lane = 2 },
    [2] = { name = "two", color = 200, lane = 1 },
    [3] = { name = "three", color = 300, lane = 0 },
  }
  for i, expect in pairs(want) do
    local got = h.added[i]
    if got.name ~= expect.name then return false, "copy " .. i .. " name " .. tostring(got.name) end
    if got.color ~= expect.color then return false, "copy " .. i .. " color " .. tostring(got.color) end
    if got.lane ~= expect.lane then
      return false, "copy " .. i .. " lane " .. tostring(got.lane) .. ", want " .. expect.lane
    end
  end

  if h.added[2].pos - h.added[1].pos ~= 3.0 then return false, "spacing 1->2 broken" end
  if h.added[3].pos - h.added[1].pos ~= 6.25 then return false, "spacing 1->3 broken" end

  return true, "lanes 2,1,0 preserved, spacing 3.0/6.25 kept"
end))

check(run_click("b) 7.78: a lane-0 original copies into lane 0, not \"no lane\"", {
  version = "7.78/OSX64", lanes = true, js = true, manager_open = true, selected_rows = { 0, 1, 2 },
}, function(h)
  local copy = h.added[3] -- "three", originally in lane 0
  if copy == nil then return false, "no third copy" end
  if copy.lane == nil then return false, "copy has no lane at all" end
  if copy.lane ~= 0 then return false, "lane " .. tostring(copy.lane) end
  return true, "lane 0, not nil"
end))

check(run_click("c) 7.75: AddProjectMarker2 is used, no lane call", {
  version = "7.75/OSX64", lanes = false, js = true, manager_open = true, selected_rows = { 0, 1, 2 },
}, function(h)
  local adds, lane_sets = 0, 0
  for _, c in ipairs(h.calls) do
    if c.kind == "add_project_marker2" then adds = adds + 1 end
    if c.kind == "add_region_or_marker" then return false, "used the 7.72+ call on 7.75" end
    if c.kind == "set_lane" then lane_sets = lane_sets + 1 end
  end
  if adds ~= 3 then return false, "add_project_marker2 called " .. adds .. " times" end
  if lane_sets ~= 0 then return false, "set_lane called " .. lane_sets .. " times" end
  if h.footer() ~= "3 markers copied." then return false, "footer = " .. tostring(h.footer()) end
  return true, "3x AddProjectMarker2, no lane call, footer OK"
end))

check(run_load("d) check_dependencies: no JS -> exactly one box, the js_cost text", {
  version = "7.78/OSX64", js = false,
}, function(h)
  if #h.boxes ~= 1 then return false, #h.boxes .. " boxes" end
  if not h.boxes[1]:find(
    "the selection is read from the arrange view instead of the Region/Marker Manager.", 1, true
  ) then
    return false, "box text: " .. h.boxes[1]
  end
  return true, "one box, right sentence"
end))

check(run_load("d) check_dependencies: everything present -> no box", {
  version = "7.78/OSX64", js = true, lanes = true, selected_rows = {},
}, function(h)
  if #h.boxes ~= 0 then return false, #h.boxes .. " boxes: " .. table.concat(h.boxes, " | ") end
  return true, "no box"
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
