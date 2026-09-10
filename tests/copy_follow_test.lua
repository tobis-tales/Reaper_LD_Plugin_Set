-- Phase 2d: the "measure.beats" and "hh:mm:ss:ff" target fields in Copy
-- Markers follow the edit cursor on their own, and the "Refresh from cursor"
-- button is gone.
--
-- Rule under test: an empty field follows the cursor every frame. Typing into
-- a field pins it (it stops following). Emptying it again makes it follow.
--
-- Driven like copy_lanes_test.lua (dofile, capture the deferred loop), but
-- with a fake that tracks a controllable cursor position and echoes back
-- whatever ImGui_InputText is told to return for a given label on a given
-- frame -- everything else keeps following.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = ((arg[0]:match("(.*/)") or "./").."../").."extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

-- One selected marker so each "Copy to ..." click adds exactly one new
-- marker, at exactly the target position (zero offset from source_start) --
-- makes the assertions below a direct check of "did it copy to the position
-- I expect".
local PROJECT = {
  { is_region = false, pos = 0.0, name = "intro", id = 1, color = 0 },
}

local function build_reaper()
  local added = {}
  local click_label = nil
  local deferred = nil
  local cursor_pos = 0.0
  local input_overrides = {}
  local button_labels = {}
  local field_buf = {}

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn end,
    GetCursorPosition = function() return cursor_pos end,
    -- Recognizable, invertible mapping instead of a realistic timecode: "M:"
    -- for measure.beats (mode 2), "T:" for hh:mm:ss:ff (mode 5).
    format_timestr_pos = function(pos, _, mode)
      if mode == 2 then return "M:" .. tostring(pos) end
      if mode == 5 then return "T:" .. tostring(pos) end
      return tostring(pos)
    end,
    -- Inverts the mapping above for a following field ("M:42" -> 42), and
    -- returns a fixed sentinel for anything else (a typed position) so a
    -- pinned copy is distinguishable from a following one.
    parse_timestr_pos = function(input, _mode)
      local prefix, num = input:match("^([MT]):(.+)$")
      if prefix then return tonumber(num) end
      return 555.5
    end,
    EnumProjectMarkers3 = function(_, i)
      local e = PROJECT[i + 1]
      if not e then return 0 end
      return 1, e.is_region, e.pos, e.pos, e.name, e.id, e.color
    end,
    AddProjectMarker2 = function(_, _, pos, _, name)
      added[#added + 1] = { pos = pos, name = name }
      return #added
    end,
    ShowMessageBox = function() return 6 end,
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
    -- row 0 selected = intro
    JS_ListView_ListAllSelItems = function() return 1, "0" end,
    JS_ListView_GetItemText = function(_, row)
      local labels = { [0] = "M1" }
      return labels[row]
    end,
    Undo_BeginBlock = function() end,
    Undo_EndBlock = function() end,
    PreventUIRefresh = function() end,
    UpdateArrange = function() end,
  }

  local r = setmetatable({}, {
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
          if key == "ImGui_Button" then
            button_labels[a] = true
            return a == click_label
          end
          if key == "ImGui_Checkbox" then return false, a end
          if key == "ImGui_InputText" then
            local label, buf = a, b
            local override = input_overrides[label]
            if override ~= nil then
              field_buf[label] = override
              return true, override
            end
            field_buf[label] = buf
            return false, buf
          end
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

  return r, {
    added = added,
    button_labels = button_labels,
    field_value = function(label) return field_buf[label] end,
    -- One rendered frame. opts.cursor moves the edit cursor first (as REAPER
    -- would before the script reads it); opts.type_into = { [label] = text }
    -- simulates the user editing that field THIS frame (ImGui_InputText
    -- reports changed=true with that text); opts.click fires that button.
    -- The pending-work queue in CopyMarkers.lua runs synchronously right
    -- after end_window, so a click's effect is visible once this returns.
    frame = function(opts)
      opts = opts or {}
      if opts.cursor ~= nil then cursor_pos = opts.cursor end
      input_overrides = opts.type_into or {}
      click_label = opts.click
      local ok, err = pcall(deferred)
      click_label = nil
      input_overrides = {}
      if not ok then error(err) end
    end,
  }
end

local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

local function run(name, driver)
  local helpers
  reaper, helpers = build_reaper()

  local ok, err = pcall(dofile, folder .. "CopyMarkers.lua")
  if not ok then
    print(string.format("%-70s FAIL  -- load error: %s", name, tostring(err)))
    return false
  end

  local ok2, ok3, detail = pcall(driver, helpers)
  if not ok2 then
    print(string.format("%-70s FAIL  -- driver error: %s", name, tostring(ok3)))
    return false
  end

  print(string.format("%-70s %s%s", name, ok3 and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
  return ok3
end

print("CopyMarkers.lua -- target fields follow the edit cursor:\n")

-- (a) Cursor moves 10 -> 20 -> 30 over three frames: both fields show the new
-- position every time. Catches "field only filled at start" (would freeze
-- both fields at whatever the cursor was on frame 1).
check(run("a) empty fields follow the cursor across three frames", function(h)
  h.frame({ cursor = 10 })
  if h.field_value("measure.beats") ~= "M:10" then return false, "frame1 measure=" .. tostring(h.field_value("measure.beats")) end
  if h.field_value("hh:mm:ss:ff") ~= "T:10" then return false, "frame1 timecode=" .. tostring(h.field_value("hh:mm:ss:ff")) end

  h.frame({ cursor = 20 })
  if h.field_value("measure.beats") ~= "M:20" then return false, "frame2 measure=" .. tostring(h.field_value("measure.beats")) end
  if h.field_value("hh:mm:ss:ff") ~= "T:20" then return false, "frame2 timecode=" .. tostring(h.field_value("hh:mm:ss:ff")) end

  h.frame({ cursor = 30 })
  if h.field_value("measure.beats") ~= "M:30" then return false, "frame3 measure=" .. tostring(h.field_value("measure.beats")) end
  if h.field_value("hh:mm:ss:ff") ~= "T:30" then return false, "frame3 timecode=" .. tostring(h.field_value("hh:mm:ss:ff")) end

  return true, "10 -> 20 -> 30, both fields tracked every frame"
end))

-- (b) Typing into measure.beats pins it; hh:mm:ss:ff keeps following. Catches
-- "flag never set" (the field would keep following and overwrite the typed
-- text on the very next frame).
check(run("b) typing into measure.beats pins it, hh:mm:ss:ff keeps following", function(h)
  h.frame({ cursor = 10 })
  h.frame({ cursor = 20, type_into = { ["measure.beats"] = "5.1.00" } })
  if h.field_value("measure.beats") ~= "5.1.00" then return false, "right after typing: " .. tostring(h.field_value("measure.beats")) end

  h.frame({ cursor = 30 })
  if h.field_value("measure.beats") ~= "5.1.00" then return false, "cursor moved again, field became " .. tostring(h.field_value("measure.beats")) end
  if h.field_value("hh:mm:ss:ff") ~= "T:30" then return false, "timecode stopped following: " .. tostring(h.field_value("hh:mm:ss:ff")) end

  return true, "measure.beats stayed 5.1.00, hh:mm:ss:ff followed to T:30"
end))

-- (c) Emptying the field makes it follow again. Catches "flag never reset"
-- (the field would stay stuck on "" forever instead of resuming).
check(run("c) emptying a pinned field makes it follow again", function(h)
  h.frame({ cursor = 10 })
  h.frame({ cursor = 10, type_into = { ["measure.beats"] = "5.1.00" } })
  h.frame({ cursor = 15, type_into = { ["measure.beats"] = "" } })
  if h.field_value("measure.beats") ~= "" then return false, "frame it was cleared on: " .. tostring(h.field_value("measure.beats")) end

  h.frame({ cursor = 20 })
  if h.field_value("measure.beats") ~= "M:20" then return false, "did not resume following: " .. tostring(h.field_value("measure.beats")) end

  return true, "cleared, then resumed following at M:20"
end))

-- (d) "Copy to measure.beats" targets the cursor while the field follows it,
-- and the parsed typed position once the field is pinned.
check(run("d) Copy to measure.beats: cursor while following, typed value once pinned", function(h)
  h.frame({ cursor = 42 })
  h.frame({ cursor = 42, click = "Copy to measure.beats" })
  if #h.added == 0 then return false, "no marker added while following" end
  if h.added[1].pos ~= 42 then return false, "following: copied to " .. tostring(h.added[1].pos) .. ", want cursor 42" end

  h.frame({ cursor = 42, type_into = { ["measure.beats"] = "5.1.00" } })
  h.frame({ cursor = 99, click = "Copy to measure.beats" })
  if #h.added ~= 2 then return false, "pinned click did not add a marker (added=" .. #h.added .. ")" end
  if h.added[2].pos ~= 555.5 then return false, "pinned: copied to " .. tostring(h.added[2].pos) .. ", want the parsed pinned value" end

  return true, "following -> copied to cursor (42), pinned -> copied to parsed 5.1.00"
end))

-- (e) The removed button must never render again.
check(run("e) the \"Refresh from cursor\" button never renders", function(h)
  h.frame({ cursor = 10 })
  h.frame({ cursor = 20 })
  h.frame({ cursor = 30 })
  if h.button_labels["Refresh from cursor"] then return false, "button was rendered" end
  return true, "button is gone"
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
