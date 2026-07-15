-- Exercise steelblue_install.lua without REAPER.
--
-- Two checks:
--   1. every reaper.* name the installer calls really exists in the REAPER
--      binary (a typo here would only surface on a stranger's machine, halfway
--      through their install)
--   2. the flow does the right things: registers all four, asks about
--      shortcuts, reports honestly about missing extensions

local PKG = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/"
local REAPER_BIN = "/Applications/REAPER.app/Contents/MacOS/REAPER"

-- ---------------------------------------------------------------- 1. names

local used = {}
for line in io.lines(PKG .. "steelblue_install.lua") do
  for name in line:gmatch("reaper%.([A-Za-z_0-9]+)") do
    used[name] = true
  end
end

local names = {}
for n in pairs(used) do names[#names + 1] = n end
table.sort(names)

print(string.format("installer calls %d distinct reaper.* functions", #names))

local unknown = {}
for _, name in ipairs(names) do
  local p = io.popen(string.format("strings %q | grep -cx %q", REAPER_BIN, name))
  local hits = tonumber(p:read("a")) or 0
  p:close()
  if hits == 0 then
    unknown[#unknown + 1] = name
  end
end

if #unknown > 0 then
  print("\nNOT FOUND IN THE REAPER BINARY (typo? wrong name?):")
  for _, n in ipairs(unknown) do print("   reaper." .. n) end
else
  print("  all of them exist in REAPER " .. (function()
    local p = io.popen("defaults read /Applications/REAPER.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null")
    local v = (p:read("a") or "?"):gsub("%s+$", "")
    p:close()
    return v
  end)())
end

-- ---------------------------------------------------------------- 2. flow

local log, answers, answer_at = {}, {}, 0
local scenario

local function next_answer()
  answer_at = answer_at + 1
  return answers[answer_at] or 1
end

local function fake()
  local r = {}
  r.ShowMessageBox = function(msg)
    log[#log + 1] = { kind = "dialog", text = msg }
    return next_answer()
  end
  r.APIExists = function(name)
    if name == "ImGui_CreateContext" then return scenario.imgui end
    if name == "JS_Window_ArrayFind" then return scenario.js end
    return true
  end
  r.file_exists = function(path)
    if scenario.missing_file and path:find(scenario.missing_file, 1, true) then return false end
    return true
  end
  r.SectionFromUniqueID = function() return "MAIN" end
  r.AddRemoveReaScript = function(add, sec, fn, commit)
    log[#log + 1] = { kind = "register", file = fn:match("([^/]+)$"), commit = commit }
    return 40000 + #log
  end
  r.CountActionShortcuts = function() return scenario.existing_shortcuts and 1 or 0 end
  r.GetActionShortcutDesc = function() return true, scenario.existing_shortcuts and "Cmd+Shift+B" or "" end
  r.DoActionShortcutDialog = function(_, _, cmd)
    log[#log + 1] = { kind = "shortcut_dialog", cmd = cmd }
  end
  r.GetUserFileNameForRead = function() return false, "" end
  r.GetResourcePath = function() return "/fake/REAPER" end
  r.RecursiveCreateDirectory = function() return 1 end
  r.ExecProcess = function(cmd) log[#log + 1] = { kind = "exec", cmd = cmd } return "0\n" end
  return r
end

local function run(name, setup, check)
  scenario = setup
  answers = setup.answers or {}
  answer_at = 0
  log = {}
  reaper = fake()

  local ok, err = pcall(dofile, PKG .. "steelblue_install.lua")
  if not ok then
    print(string.format("  FAIL  %-42s error: %s", name, err))
    return false
  end

  local passed, detail = check(log)
  print(string.format("  %s  %-42s %s", passed and "PASS" or "FAIL", name, detail or ""))
  return passed
end

local function count(log, kind)
  local n = 0
  for _, e in ipairs(log) do if e.kind == kind then n = n + 1 end end
  return n
end

local function dialogs_matching(log, pattern)
  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:find(pattern) then return e.text end
  end
  return nil
end

print("\ninstaller flow:\n")
local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

-- OK, both extensions there, yes to shortcuts
check(run("happy path: 4 registered, 4 shortcut dialogs", {
  imgui = true, js = true, answers = { 1, 6, 1, 1, 1, 1 },
}, function(log)
  local reg, dlg = count(log, "register"), count(log, "shortcut_dialog")
  if reg ~= 4 then return false, "registered " .. reg .. ", expected 4" end
  if dlg ~= 4 then return false, "opened " .. dlg .. " shortcut dialogs, expected 4" end
  return true, "4 registered, 4 dialogs"
end))

-- the last AddRemoveReaScript must commit
check(run("only the last register commits", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  local commits = 0
  for _, e in ipairs(log) do
    if e.kind == "register" and e.commit then commits = commits + 1 end
  end
  return commits == 1, commits .. " commit(s) — REAPER wants exactly one, on the last call"
end))

-- user says no to shortcuts
check(run("declining shortcuts skips the dialogs", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  return count(log, "shortcut_dialog") == 0, "no dialogs opened"
end))

-- shortcut already assigned -> do not nag
check(run("existing shortcut is left alone", {
  imgui = true, js = true, existing_shortcuts = true, answers = { 1, 6 },
}, function(log)
  return count(log, "shortcut_dialog") == 0, "no dialog for already-bound actions"
end))

-- ReaImGui missing -> must be told
check(run("missing ReaImGui is reported", {
  imgui = false, js = true, answers = { 1, 2, 7 },
}, function(log)
  local said = dialogs_matching(log, "ReaImGui is required")
  local warned = dialogs_matching(log, "ReaImGui is still missing")
  return said ~= nil and warned ~= nil, "warned up front and in the summary"
end))

-- JS missing -> must explain the real consequence, not just "missing"
check(run("missing JS_ReaScriptAPI explains the consequence", {
  imgui = true, js = false, answers = { 1, 2, 7 },
}, function(log)
  local text = dialogs_matching(log, "JS_ReaScriptAPI is not installed")
  if not text then return false, "never mentioned" end
  if not text:find("Rename selected markers") then return false, "did not say which plugin is affected" end
  return true, "names the plugin and the effect"
end))

-- an incomplete copy must stop before touching anything
check(run("missing plugin file aborts before registering", {
  imgui = true, js = true, missing_file = "CopyMarkers.lua", answers = { 1 },
}, function(log)
  if count(log, "register") > 0 then return false, "registered anyway!" end
  return dialogs_matching(log, "missing next to the installer") ~= nil, "stopped and said what is missing"
end))

-- cancelling at the first dialog changes nothing
check(run("cancel at the welcome does nothing", {
  imgui = true, js = true, answers = { 2 },
}, function(log)
  return count(log, "register") == 0 and count(log, "exec") == 0, "no side effects"
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit((fails == 0 and #unknown == 0) and 0 or 1)
