-- v2a: the workspace shell's state rules, through the WORKSPACE_TEST hook.
--
-- Everything here is decided outside the ImGui frame, which is exactly why it
-- can be tested without REAPER: whether a frame asks for the docker, which tab
-- is open, and what the selection line says.
--
-- The ExtState fake records the persist flag, because "remembered across
-- REAPER restarts" is half the point of storing these at all -- a call that
-- passes false would still look right in every other assertion.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

local ext_state, ext_calls

local function build_reaper(initial)
  ext_state = {}
  ext_calls = {}
  for key, value in pairs(initial or {}) do
    ext_state[key] = value
  end

  local specific = {
    GetExtState = function(section, key)
      ext_calls[#ext_calls + 1] = { kind = "get", section = section, key = key }
      return ext_state[key] or ""
    end,
    SetExtState = function(section, key, value, persist)
      ext_calls[#ext_calls + 1] = { kind = "set", section = section, key = key,
                                    value = value, persist = persist }
      ext_state[key] = value
    end,
    DeleteExtState = function(section, key, persist)
      ext_calls[#ext_calls + 1] = { kind = "delete", section = section, key = key,
                                    persist = persist }
      ext_state[key] = nil
    end,
    HasExtState = function(_, key) return ext_state[key] ~= nil end,
    GetOS = function() return "macOS-arm64" end,
    GetAppVersion = function() return "7.79/OSX64" end,
    APIExists = function() return true end,
    ShowMessageBox = function() return 6 end,
    defer = function() end,
    time_precise = function() return 0 end,
  }

  return setmetatable({}, {
    __index = function(_, key)
      if specific[key] then return specific[key] end
      return function() return 0 end
    end,
  })
end

-- Loads the workspace with the hook set, against a fresh ExtState.
local function load_workspace(initial)
  reaper = build_reaper(initial)
  WORKSPACE_TEST = {}
  local ok, err = pcall(dofile, folder .. "steelblue_workspace.lua")
  local hook = WORKSPACE_TEST
  WORKSPACE_TEST = nil
  if not ok then
    error(err)
  end
  return hook
end

local function set_calls(key)
  local found = {}
  for _, call in ipairs(ext_calls) do
    if call.kind == "set" and call.key == key then
      found[#found + 1] = call
    end
  end
  return found
end

local function delete_calls(key)
  local found = {}
  for _, call in ipairs(ext_calls) do
    if call.kind == "delete" and call.key == key then
      found[#found + 1] = call
    end
  end
  return found
end

local function deleted(key)
  return #delete_calls(key) > 0
end

local fails = 0

local function run(name, body)
  local ok, passed, detail = pcall(body)
  if not ok then
    fails = fails + 1
    print(string.format("  FAIL  %-64s error: %s", name, tostring(passed)))
    return
  end
  if not passed then
    fails = fails + 1
  end
  print(string.format("  %s  %-64s %s", passed and "PASS" or "FAIL", name, detail or ""))
end

print("\nsteelblue_workspace.lua -- shell state rules:\n")

-- ---------------------------------------------------------------- docking

-- Both halves of Tobi's decision (2026-09-11: the workspace is always docked).
-- The docker placement does not survive a REAPER restart, so every run has to
-- ask again -- but only once: Cond_Always on every frame would pin the window
-- down and it could never be dragged anywhere at all.
run("a) docks on the first frame of every run, and never again by itself", function()
  local W = load_workspace()
  local first = W.dock_decision(true)
  local later = W.dock_decision(false)
  return first == true and later == false,
    "dock_decision(true)=" .. tostring(first) .. " dock_decision(false)=" .. tostring(later)
end)

-- The 2.0 previews had a "Dock" button and remembered a deliberately floating
-- window in this entry. Both are gone; the leftover is written with persist,
-- so without this it would sit in reaper-extstate.ini forever.
run("b) a stale undocked flag from 2.0 previews is deleted on load", function()
  local W = load_workspace({ undocked = "1" })
  local calls = delete_calls("undocked")
  if #calls ~= 1 then return false, #calls .. " deletes, expected 1" end
  if calls[1].persist ~= true then return false, "deleted without persist" end
  if W.state.undocked ~= nil then return false, "the state still carries an undocked field" end
  return true, "deleted with persist, no undocked field left in the state"
end)

-- ---------------------------------------------------------------- tabs

run("c) the open tab is remembered across REAPER restarts", function()
  local W = load_workspace()
  if W.state.active_tab ~= "rename" then
    return false, "fresh install opened " .. tostring(W.state.active_tab)
  end

  W.set_active_tab("copy")
  local calls = set_calls("active_tab")
  if #calls ~= 1 then return false, #calls .. " writes, expected 1" end
  if calls[1].persist ~= true then return false, "written without persist" end

  local W2 = load_workspace(ext_state)
  return W2.state.active_tab == "copy", "copy survived a reload"
end)

run("d) a stored tab id that no longer exists falls back to the first tab", function()
  local W = load_workspace({ active_tab = "bpm" })
  return W.state.active_tab == "rename", "opened " .. tostring(W.state.active_tab)
end)

-- The request has to be CLEARED, not just read: left in place it would drag
-- the workspace back to that tab on every single frame, and the user could
-- never switch away from it.
run("e) an open_tab request is taken over and cleared", function()
  local W = load_workspace({ open_tab = "midi" })
  local requested = W.read_open_tab_request()
  if requested ~= "midi" then return false, "read " .. tostring(requested) end
  if not deleted("open_tab") then return false, "request was left in the ExtState" end

  local again = W.read_open_tab_request()
  return again == nil, "read once as midi, gone on the next frame"
end)

run("f) an unknown open_tab request is ignored, and still cleared", function()
  local W = load_workspace({ open_tab = "nonsense" })
  local requested = W.read_open_tab_request()
  if requested ~= nil then return false, "accepted " .. tostring(requested) end
  return deleted("open_tab"), "ignored and cleared"
end)

run("g) set_active_tab refuses an id that is not a tab", function()
  local W = load_workspace()
  local changed = W.set_active_tab("bpm")
  return changed == false and W.state.active_tab == "rename",
    "stayed on " .. tostring(W.state.active_tab)
end)

-- ---------------------------------------------------------------- read-out

run("h) the selection line says where the order came from", function()
  local W = load_workspace()
  local manager = W.selection_text(3, "manager")
  local arrange = W.selection_text(3, "arrange")
  local none = W.selection_text(0, nil)

  if not manager:find("3 selected", 1, true) then return false, manager end
  if not manager:find("click order", 1, true) then return false, manager end
  if not arrange:find("arrange view", 1, true) then return false, arrange end
  if not none:find("nothing selected", 1, true) then return false, none end
  return true, none
end)

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
