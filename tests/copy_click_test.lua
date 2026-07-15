-- Reproduce the "Copy to cursor" click offline: fake REAPER with a Region/Marker
-- Manager holding 3 selected markers, then make the button fire and see whether
-- the frame survives and the status updates.

local folder = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/"
local dylib = "/Users/tobiaspehla/Library/Application Support/REAPER/UserPlugins/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

local PROJECT = {
  { is_region = false, pos = 0.0, name = "intro", id = 1, color = 0 },
  { is_region = false, pos = 3.75, name = "verse", id = 2, color = 0 },
  { is_region = false, pos = 7.5, name = "buildup", id = 3, color = 0 },
  { is_region = false, pos = 11.25, name = "drop", id = 4, color = 0 },
  { is_region = false, pos = 13.1, name = "break", id = 5, color = 0 },
}

local added = {}
local click_label = nil
local deferred = nil
local footer_text = nil

local specific = {
  APIExists = function(name)
    if name:match("^ImGui_") then return real_imgui[name] == true end
    return true
  end,
  defer = function(fn) deferred = fn end,
  GetCursorPosition = function() return 34.2 end,
  format_timestr_pos = function() return "19.3.00" end,
  parse_timestr_pos = function() return 34.2 end,
  EnumProjectMarkers3 = function(_, i)
    local e = PROJECT[i + 1]
    if not e then return 0 end
    return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
  end,
  AddProjectMarker2 = function(_, _, pos, _, name)
    added[#added + 1] = { pos = pos, name = name }
    return #added
  end,
  ShowMessageBox = function(m) print("  MSGBOX: " .. tostring(m)) return 6 end,
  GetAppVersion = function() return "7.75/OSX64" end,
  new_array = function() return { table = function() return { 1234 } end } end,
  JS_Localize = function(s) return s end,
  JS_Window_ArrayFind = function() return 1 end,
  JS_Window_HandleFromAddress = function() return "hwnd" end,
  JS_Window_FindChildByID = function(_, id)
    if id == 1056 then return "container" end
    if id == 1071 then return "listview" end
    return nil
  end,
  -- rows 1,2,3 selected = verse, buildup, drop
  JS_ListView_ListAllSelItems = function() return 3, "1,2,3" end,
  JS_ListView_GetItemText = function(_, row)
    local labels = { [0] = "M1", [1] = "M2", [2] = "M3", [3] = "M4", [4] = "M5" }
    return labels[row]
  end,
  Undo_BeginBlock = function() end,
  Undo_EndBlock = function() end,
  PreventUIRefresh = function() end,
  UpdateArrange = function() end,
}

reaper = setmetatable({}, {
  __index = function(_, key)
    if specific[key] then return specific[key] end
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
        if key == "ImGui_DrawList_AddTextEx" then
          -- (dl, font, size, x, y, col, text) -> capture the footer line
          return nil
        end
        if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
          or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
        return nil
      end
    end
    return function() return 0 end
  end,
})

-- capture what the footer draws
local real_index = getmetatable(reaper).__index
setmetatable(reaper, { __index = function(t, key)
  local fn = real_index(t, key)
  if key == "ImGui_DrawList_AddTextEx" then
    return function(dl, font, size, x, y, col, text)
      if size == 11 then footer_text = text end
      return nil
    end
  end
  return fn
end })

print("loading CopyMarkers.lua ...")
local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
if not ok then print("LOAD ERROR: " .. tostring(err)) os.exit(1) end

print("\nframe 1 (no click):")
local ok1, err1 = pcall(deferred)
print("  ok=" .. tostring(ok1) .. (err1 and ("  err=" .. tostring(err1)) or ""))
print("  footer = " .. tostring(footer_text))
print("  markers added = " .. #added)

print("\nframe 2 (Copy to cursor CLICKED):")
click_label = "Copy to cursor"
local ok2, err2 = pcall(deferred)
print("  ok=" .. tostring(ok2) .. (err2 and ("  err=" .. tostring(err2)) or ""))
print("  footer = " .. tostring(footer_text))
print("  markers added = " .. #added)
for _, m in ipairs(added) do
  print(string.format("    -> %-8s at %.2f", m.name, m.pos))
end

print("\nframe 3 (no click, should still show the result):")
click_label = nil
local ok3, err3 = pcall(deferred)
print("  ok=" .. tostring(ok3) .. (err3 and ("  err=" .. tostring(err3)) or ""))
print("  footer = " .. tostring(footer_text))

if footer_text == "3 markers copied." then
  print("\nOK: status updates as expected -- the freeze is NOT in this code path")
  os.exit(0)
else
  print("\nREPRODUCED: footer stays '" .. tostring(footer_text) .. "'")
  os.exit(1)
end
