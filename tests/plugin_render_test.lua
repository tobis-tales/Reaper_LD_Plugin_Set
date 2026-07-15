-- Load each real plugin file against a fake REAPER and actually run its defer
-- loop for a number of frames. Compiling proves nothing: this catches missing
-- module functions, wrong argument counts, and style-stack leaks -- the things
-- that in REAPER only appear once the window is open.

local folder = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/"
local dylib = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local count_real_imgui = 0
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do
  real_imgui[line:gsub("^-API_", "")] = true
  count_real_imgui = count_real_imgui + 1
end
p:close()

local state

local function make_reaper()
  local r = {}
  local deferred = nil

  local specific = {
    APIExists = function(name)
      if name:match("^ImGui_") then return real_imgui[name] == true end
      return true
    end,
    defer = function(fn) deferred = fn end,
    time_precise = function() return state.frame * 0.1 end,
    GetCursorPosition = function() return 12.5 end,
    GetPlayPosition = function() return 12.5 end,
    GetPlayState = function() return 0 end,
    format_timestr_pos = function() return "1.1.00" end,
    parse_timestr_pos = function() return 10.0 end,
    Master_GetTempo = function() return 130.0 end,
    GetAppVersion = function() return "7.75/OSX64" end,
    CountSelectedMediaItems = function() return 2 end,
    CountTracks = function() return 0 end,
    CountTrackMediaItems = function() return 0 end,
    GetSelectedMediaItem = function() return nil end,
    EnumProjectMarkers3 = function(_, i)
      if i >= 2 then return 0 end
      return 1, false, 10.0 + i, 0, "cue" .. i, i + 1, 0
    end,
    ShowMessageBox = function(msg)
      state.messages[#state.messages + 1] = msg
      return 6
    end,
    new_array = function() return { table = function() return {} end } end,
    -- JS_ReaScriptAPI present but manager closed, so scripts take the
    -- "nothing selected" path -- the state a user sees on first launch
    JS_Localize = function(s) return s end,
    JS_Window_ArrayFind = function() return 0 end,
    JS_Window_HandleFromAddress = function() return nil end,
    JS_Window_FindChildByID = function() return nil end,
    JS_ListView_ListAllSelItems = function() return 0, "" end,
    JS_ListView_GetItemText = function() return "" end,
    GetNumRegionsOrMarkers = function() return 0 end,
    GetRegionOrMarker = function() return nil end,
    GetRegionOrMarkerInfo_Value = function() return 0 end,
  }

  setmetatable(r, {
    __index = function(_, key)
      if specific[key] then return specific[key] end

      if key:match("^ImGui_") then
        if not real_imgui[key] then
          state.missing[key] = true
          return nil
        end

        return function(_, a)
          if key == "ImGui_PushStyleColor" then state.colors = state.colors + 1 end
          if key == "ImGui_PopStyleColor" then state.colors = state.colors - (a or 1) end
          if key == "ImGui_PushStyleVar" then state.vars = state.vars + 1 end
          if key == "ImGui_PopStyleVar" then state.vars = state.vars - (a or 1) end
          if key == "ImGui_PushFont" then state.fonts = state.fonts + 1 end
          if key == "ImGui_PopFont" then state.fonts = state.fonts - 1 end
          if key == "ImGui_Begin" then state.windows = state.windows + 1 end
          if key == "ImGui_End" then state.windows = state.windows - 1 end
          if key == "ImGui_PushItemWidth" then state.widths = state.widths + 1 end
          if key == "ImGui_PopItemWidth" then state.widths = state.widths - 1 end

          if key == "ImGui_CreateContext" then return "ctx" end
          if key == "ImGui_CreateFont" then return "font" end
          if key == "ImGui_GetWindowDrawList" then return "dl" end
          if key == "ImGui_Begin" then return true, true end
          if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
          if key == "ImGui_GetContentRegionAvail" then return 400, 300 end
          if key == "ImGui_CalcTextSize" then return 50, 12 end
          if key == "ImGui_Button" then return false end
          if key == "ImGui_Checkbox" then return false, a end
          if key == "ImGui_InputText" then return false, "text" end
          if key == "ImGui_InputInt" then return false, 24 end
          if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
            or key:match("^ImGui_Cond_") or key:match("Flags") then
            return 1
          end
          return nil
        end
      end

      -- any other REAPER API: harmless no-op
      return function() return 0 end
    end,
  })

  return r, function() return deferred end
end

local plugins = {
  "Live BPM Analyzer.lua",
  "CopyMarkers.lua",
  "MIDI notes to project markers.lua",
  "Rename selected markers.lua",
}

local fails = 0
print("rendering each plugin for 30 frames against a fake REAPER:\n")

for _, name in ipairs(plugins) do
  state = { frame = 0, colors = 0, vars = 0, fonts = 0, windows = 0, widths = 0,
            missing = {}, messages = {} }

  local get_deferred
  reaper, get_deferred = make_reaper()

  local ok, err = pcall(dofile, folder .. name)

  local frames = 0
  if ok then
    for _ = 1, 30 do
      local fn = get_deferred()
      if not fn then break end
      state.frame = state.frame + 1
      local frame_ok, frame_err = pcall(fn)
      if not frame_ok then
        ok, err = false, frame_err
        break
      end
      frames = frames + 1
    end
  end

  local problems = {}
  if not ok then problems[#problems + 1] = "ERROR: " .. tostring(err) end
  for k in pairs(state.missing) do problems[#problems + 1] = "missing API " .. k end
  for _, key in ipairs({ "colors", "vars", "fonts", "windows", "widths" }) do
    if state[key] ~= 0 then
      problems[#problems + 1] = string.format("%s stack %+d", key, state[key])
    end
  end

  if frames == 0 then
    problems[#problems + 1] = "rendered 0 frames — the plugin never drew anything"
  end

  if #problems == 0 then
    print(string.format("  PASS  %-34s %2d frames rendered", name, frames))
  else
    fails = fails + 1
    print(string.format("  FAIL  %-34s", name))
    for _, problem in ipairs(problems) do print("          " .. problem) end
  end
end

print(fails == 0 and "\nALL PLUGINS RENDER CLEAN" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
