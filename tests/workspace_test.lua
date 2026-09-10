-- v2a: the workspace shell's state rules, through the WORKSPACE_TEST hook.
--
-- Everything here is decided outside the ImGui frame, which is exactly why it
-- can be tested without REAPER: whether a frame asks for the docker, whether
-- the user pulled the window out on purpose, which tab is open, and what the
-- selection line says.
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
    DeleteExtState = function(section, key)
      ext_calls[#ext_calls + 1] = { kind = "delete", section = section, key = key }
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

local function deleted(key)
  for _, call in ipairs(ext_calls) do
    if call.kind == "delete" and call.key == key then
      return true
    end
  end
  return false
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

run("a) the first frame of a run asks for the docker", function()
  local W = load_workspace()
  local dock_now = W.dock_decision(true, nil, false, false)
  return dock_now == true, "dock_decision(first frame) = " .. tostring(dock_now)
end)

-- The one rule the probe forced on us: Cond_Always would drag a deliberately
-- floating window straight back into the docker on every start.
run("b) a window the user pulled out is never dragged back", function()
  local W = load_workspace({ undocked = "1" })
  if W.state.undocked ~= true then
    return false, "undocked flag not read from ExtState"
  end
  local dock_now = W.dock_decision(true, nil, W.state.undocked, false)
  return dock_now == false, "dock_decision(first frame, undocked) = " .. tostring(dock_now)
end)

-- Cond_Always on every frame would pin the window down: it could never be
-- dragged anywhere, and a machine where this docker number is wrong would
-- fight the user forever.
run("c) later frames do not ask again, docked or not", function()
  local W = load_workspace()
  local docked = W.dock_decision(false, true, false, false)
  local floating = W.dock_decision(false, false, false, false)
  return docked == false and floating == false,
    "docked=" .. tostring(docked) .. " floating=" .. tostring(floating)
end)

run("d) the Dock button re-docks even after the window was pulled out", function()
  local W = load_workspace({ undocked = "1" })
  local dock_now = W.dock_decision(false, false, true, true)
  return dock_now == true, "dock_decision(redock) = " .. tostring(dock_now)
end)

run("e) only a window that WAS docked counts as pulled out", function()
  local W = load_workspace()
  local pulled_out = W.undock_choice(true, false, false)
  local never_docked = W.undock_choice(false, false, false)
  local still_docked = W.undock_choice(true, true, false)
  local remembered = W.undock_choice(false, true, true)
  return pulled_out == true and never_docked == false
    and still_docked == false and remembered == true,
    string.format("pulled_out=%s never_docked=%s still_docked=%s remembered=%s",
      tostring(pulled_out), tostring(never_docked), tostring(still_docked), tostring(remembered))
end)

run("f) the undocked choice is remembered across REAPER restarts", function()
  local W = load_workspace()
  W.set_undocked(true)
  local calls = set_calls("undocked")
  if #calls ~= 1 then return false, #calls .. " writes, expected 1" end
  if calls[1].value ~= "1" then return false, "wrote " .. tostring(calls[1].value) end
  if calls[1].persist ~= true then return false, "written without persist" end

  local W2 = load_workspace(ext_state)
  return W2.state.undocked == true, "written as \"1\" with persist, read back as true"
end)

-- ---------------------------------------------------------------- tabs

run("g) the open tab is remembered across REAPER restarts", function()
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

run("h) a stored tab id that no longer exists falls back to the first tab", function()
  local W = load_workspace({ active_tab = "bpm" })
  return W.state.active_tab == "rename", "opened " .. tostring(W.state.active_tab)
end)

-- The request has to be CLEARED, not just read: left in place it would drag
-- the workspace back to that tab on every single frame, and the user could
-- never switch away from it.
run("i) an open_tab request is taken over and cleared", function()
  local W = load_workspace({ open_tab = "midi" })
  local requested = W.read_open_tab_request()
  if requested ~= "midi" then return false, "read " .. tostring(requested) end
  if not deleted("open_tab") then return false, "request was left in the ExtState" end

  local again = W.read_open_tab_request()
  return again == nil, "read once as midi, gone on the next frame"
end)

run("j) an unknown open_tab request is ignored, and still cleared", function()
  local W = load_workspace({ open_tab = "nonsense" })
  local requested = W.read_open_tab_request()
  if requested ~= nil then return false, "accepted " .. tostring(requested) end
  return deleted("open_tab"), "ignored and cleared"
end)

run("k) set_active_tab refuses an id that is not a tab", function()
  local W = load_workspace()
  local changed = W.set_active_tab("bpm")
  return changed == false and W.state.active_tab == "rename",
    "stayed on " .. tostring(W.state.active_tab)
end)

-- ---------------------------------------------------------------- read-out

run("l) the selection line says where the order came from", function()
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
