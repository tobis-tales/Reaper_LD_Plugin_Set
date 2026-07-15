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

-- ImGui_* names live in the ReaImGui extension, not in REAPER itself, so look
-- there too before calling a name a typo.
local REAIMGUI_DYLIB = PKG .. "extensions/macOS/reaper_imgui-arm64.dylib"

local unknown = {}
for _, name in ipairs(names) do
  local bin = name:match("^ImGui_") and REAIMGUI_DYLIB or REAPER_BIN
  local pattern = name:match("^ImGui_") and ("-API_" .. name) or name
  local p = io.popen(string.format("strings %q | grep -cx %q", bin, pattern))
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
    if name == "ImGui_GetVersion" then return scenario.imgui end
    return true
  end
  r.ImGui_GetVersion = function()
    return "1.92.1", 19201, scenario.imgui_version or "0.10.0.5"
  end
  r.GetOS = function() return scenario.os or "macOS-arm64" end
  r.file_exists = function(path)
    if scenario.missing_file and path:find(scenario.missing_file, 1, true) then return false end
    if scenario.no_bundled and path:find("/extensions/", 1, true) then return false end
    return true
  end
  r.SectionFromUniqueID = function() return "MAIN" end
  r.AddRemoveReaScript = function(add, sec, fn, commit)
    log[#log + 1] = { kind = "register", file = fn:match("([^/]+)$"), path = fn, commit = commit }
    return 40000 + #log
  end
  r.CountActionShortcuts = function() return scenario.existing_shortcuts and 1 or 0 end
  r.GetActionShortcutDesc = function() return true, scenario.existing_shortcuts and "Cmd+Shift+B" or "" end
  r.DoActionShortcutDialog = function(_, _, cmd)
    log[#log + 1] = { kind = "shortcut_dialog", cmd = cmd }
  end
  r.GetUserFileNameForRead = function() return false, "" end
  -- a real temp dir, so the copy step is actually exercised instead of faked
  r.GetResourcePath = function() return scenario.resource_path end
  r.RecursiveCreateDirectory = function(path)
    os.execute(string.format("mkdir -p %q", path))
    return 1
  end
  r.ExecProcess = function(cmd) log[#log + 1] = { kind = "exec", cmd = cmd } return "0\n" end
  return r
end

local function run(name, setup, check)
  scenario = setup
  -- fresh throwaway REAPER resource path per scenario
  local p = io.popen("mktemp -d")
  scenario.resource_path = (p:read("a") or ""):gsub("%s+$", "")
  p:close()

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

-- the files must physically arrive, and the registration must point AT them
check(run("files land in REAPER's Scripts folder", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  local dir = scenario.resource_path .. "/Scripts/steelblue/"
  local want = {
    "Live BPM Analyzer.lua", "MIDI notes to project markers.lua",
    "Rename selected markers.lua", "CopyMarkers.lua",
    "steelblue_ui.lua", "steelblue_markers.lua",
  }
  for _, f in ipairs(want) do
    local h = io.open(dir .. f, "rb")
    if not h then return false, "missing after copy: " .. f end
    local size = #h:read("a")
    h:close()
    if size == 0 then return false, "copied empty: " .. f end
  end
  -- and the actions must reference the copies, not the disk image
  for _, e in ipairs(log) do
    if e.kind == "register" and not e.path:find("/Scripts/steelblue/", 1, true) then
      return false, "registered from outside the install dir: " .. e.path
    end
  end
  return true, "6 files copied, actions point at the copies"
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

-- declined the offer -> the summary must still warn, not stay silent
check(run("declining ReaImGui still warns in the summary", {
  imgui = false, js = true, no_bundled = true, answers = { 1, 2, 7 },
}, function(log)
  local offered = dialogs_matching(log, "ReaImGui is not installed")
  local warned = dialogs_matching(log, "ReaImGui is missing")
  if not offered then return false, "never offered to install it" end
  if not warned then return false, "summary stayed quiet about it" end
  return true, "offered, and warned again at the end"
end))

-- the point is not "it is missing" but what that costs you
check(run("missing js_ReaScriptAPI explains the consequence", {
  imgui = true, js = false, no_bundled = true, answers = { 1, 2, 7 },
}, function(log)
  local text = dialogs_matching(log, "js_ReaScriptAPI is not installed")
  if not text then return false, "never mentioned" end
  if not text:find("Rename selected markers") then return false, "did not say which plugin is affected" end
  if not text:find("timeline order") then return false, "did not say what actually goes wrong" end
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

-- --- bundled extensions ----------------------------------------------------

local function extensions_written(scen)
  local dir = scen.resource_path .. "/UserPlugins/"
  local p = io.popen(string.format("ls %q 2>/dev/null", dir))
  local out = p:read("a") or ""
  p:close()
  return out
end

-- Apple Silicon: the arm64 builds, and only those
check(run("Apple Silicon gets the arm64 builds", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7 },
}, function()
  local got = extensions_written(scenario)
  if not got:find("reaper_imgui%-arm64%.dylib") then return false, "no arm64 ReaImGui" end
  if not got:find("reaper_js_ReaScriptAPI64ARM%.dylib") then return false, "no arm64 js_ReaScriptAPI" end
  if got:find("x86_64") then return false, "wrote an Intel build to an Apple Silicon machine!" end
  return true, "arm64 only, as it should be"
end))

-- Intel: the x86_64 builds, and only those
check(run("Intel Mac gets the x86_64 builds", {
  imgui = false, js = false, os = "OSX64", answers = { 1, 1, 1, 7 },
}, function()
  local got = extensions_written(scenario)
  if not got:find("reaper_imgui%-x86_64%.dylib") then return false, "no Intel ReaImGui" end
  if not got:find("reaper_js_ReaScriptAPI64%.dylib") then return false, "no Intel js_ReaScriptAPI" end
  if got:find("arm64") then return false, "wrote an Apple Silicon build to an Intel machine!" end
  return true, "x86_64 only, as it should be"
end))

-- the promise that matters: never touch an extension that is already there
check(run("never overwrites an installed extension", {
  imgui = true, js = true, os = "macOS-arm64", answers = { 1, 7 },
}, function()
  local got = extensions_written(scenario)
  if got:find("dylib") then return false, "wrote an extension even though both were present!" end
  return true, "nothing written, as promised"
end))

-- an older ReaImGui must be called out, not silently tolerated
check(run("an older ReaImGui is called out by version", {
  imgui = true, js = true, imgui_version = "0.9.3", answers = { 1, 7 },
}, function(log)
  local text = dialogs_matching(log, "Your ReaImGui is version")
  if not text then return false, "said nothing about the old version" end
  if not text:find("0%.9%.3") then return false, "did not name the version found" end
  if not text:find("not overwrite") then return false, "did not explain why it leaves it alone" end
  return true, "names 0.9.3 and explains it will not touch it"
end))

check(run("a current ReaImGui is not complained about", {
  imgui = true, js = true, imgui_version = "0.10.0.5", answers = { 1, 7 },
}, function(log)
  return dialogs_matching(log, "Your ReaImGui is version") == nil, "stays quiet"
end))

-- freshly placed extension: must demand a restart, not report failure
check(run("after placing an extension it demands a restart", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7 },
}, function(log)
  local text = dialogs_matching(log, "RESTART REAPER NOW")
  if not text then return false, "never asked for a restart" end
  if text:find("ReaImGui is missing") then return false, "reported it as missing right after installing it" end
  return true, "asks for a restart instead of crying wolf"
end))

-- no bundle for this platform -> fall back to browse-for-file
check(run("unknown platform falls back to browse", {
  imgui = false, js = false, os = "Win64", answers = { 1, 2, 2, 7 },
}, function(log)
  return dialogs_matching(log, "If you have already downloaded") ~= nil, "offers the file picker"
end))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit((fails == 0 and #unknown == 0) and 0 or 1)
