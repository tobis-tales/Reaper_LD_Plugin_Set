-- Exercise steelblue_install.lua without REAPER.
--
-- Two checks:
--   1. every reaper.* name the installer calls really exists in the REAPER
--      binary (a typo here would only surface on a stranger's machine, halfway
--      through their install)
--   2. the flow does the right things: registers every plugin, asks about
--      shortcuts, reports honestly about missing extensions

local PKG = ((arg[0]:match("(.*/)") or "./").."../")..""
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
  -- `--` matters: the ImGui pattern starts with "-API_", and without it grep
  -- reads that as a flag and fails with "Invalid argument" -- which counts as
  -- zero hits, so every ImGui_* name got reported as a typo it was not.
  local p = io.popen(string.format("strings %q | grep -cx -- %q", bin, pattern))
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

-- What the startup block must name the workspace action: with the leading
-- underscore NamedCommandLookup wants. REAPER's ReverseNamedCommandLookup hands
-- the id back WITHOUT it, so that is what the fake returns -- the installer has
-- to put it back, and this pair of constants is what proves it does.
local WORKSPACE_COMMAND_ID = "_RS1234abcd"
local WORKSPACE_REVERSE_ID = "RS1234abcd"

local STARTUP_BEGIN = "// steelblue LD Tools: autostart (managed by steelblue_install.lua) -- begin"
local STARTUP_END = "// steelblue LD Tools: autostart -- end"

-- The markers and the exact block v2g wrote into __startup.lua. Spelled out
-- here rather than asked of the installer: the installer does not write this
-- shape any more, and a cleanup test that builds its own input from the code it
-- is testing proves nothing.
local LEGACY_BEGIN = "-- steelblue LD Tools: autostart (managed by steelblue_install.lua) -- begin"
local LEGACY_END = "-- steelblue LD Tools: autostart -- end"

local LEGACY_BLOCK = table.concat({
  LEGACY_BEGIN,
  "do",
  '  if reaper.GetExtState("steelblue_workspace", "autostart") == "1" then',
  '    local cmd = reaper.NamedCommandLookup("' .. WORKSPACE_COMMAND_ID .. '")',
  "    if cmd ~= 0 then reaper.Main_OnCommand(cmd, 0) end",
  "  end",
  "end",
  LEGACY_END,
}, "\n")

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
  -- Look at the real filesystem. A fake that answers "sure, it's there" to
  -- everything is how a test tells you the installer copes with a missing file
  -- while it has never actually seen one.
  r.file_exists = function(path)
    if scenario.missing_file and path:find(scenario.missing_file, 1, true) then return false end
    if scenario.no_bundled and path:find("/extensions/", 1, true) then return false end
    local h = io.open(path, "rb")
    if h then
      h:close()
      return true
    end
    return false
  end
  r.SectionFromUniqueID = function() return "MAIN" end
  -- The command ID AddRemoveReaScript hands out is a session number; the "_RS…"
  -- string a startup script can name comes back from ReverseNamedCommandLookup.
  -- Keep the mapping here, so a scenario can also take that call away and see
  -- what the installer does without it.
  local ids = {}
  r.AddRemoveReaScript = function(add, sec, fn, commit)
    log[#log + 1] = { kind = "register", file = fn:match("([^/]+)$"), path = fn, commit = commit }
    local cmd = 40000 + #log
    ids[cmd] = fn:find("steelblue_workspace.lua", 1, true) and WORKSPACE_REVERSE_ID
      or ("RSother" .. cmd)
    return cmd
  end
  if not scenario.no_reverse_lookup then
    r.ReverseNamedCommandLookup = function(cmd)
      log[#log + 1] = { kind = "reverse_lookup", cmd = cmd }
      return ids[cmd]
    end
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
  r.Main_OnCommand = function(cmd) log[#log + 1] = { kind = "command", cmd = cmd } end
  -- A real directory listing, like everything else here: a fake that hands back
  -- the payload it was told about could never show a leftover it did not
  -- expect. REAPER re-reads the folder when the index is 0 and returns nil past
  -- the last entry -- both matter to the caller, so both are reproduced.
  local listings = {}
  r.EnumerateFiles = function(path, index)
    if index == 0 then
      local names = {}
      local p = io.popen(string.format("ls -1 %q 2>/dev/null", path))
      for line in p:lines() do names[#names + 1] = line end
      p:close()
      listings[path] = names
    end
    return (listings[path] or {})[index + 1]
  end
  return r
end

-- os.remove really deletes; the log is only so a scenario can also say which
-- files were NOT touched, which the surviving file alone cannot prove.
local real_remove = os.remove

local function watch_removals()
  os.remove = function(path)
    log[#log + 1] = { kind = "remove", path = path, file = path:match("([^/]+)$") }
    return real_remove(path)
  end
end

local function removed_files(log)
  local names = {}
  for _, e in ipairs(log) do
    if e.kind == "remove" then names[#names + 1] = e.file end
  end
  return names
end

local function run(name, setup, check)
  scenario = setup
  -- fresh throwaway REAPER resource path per scenario
  local p = io.popen("mktemp -d")
  scenario.resource_path = (p:read("a") or ""):gsub("%s+$", "")
  p:close()

  -- Files already sitting in the install folder when the installer starts --
  -- an older release's leftovers, or something the user put there.
  if setup.already_there then
    local dir = scenario.resource_path .. "/Scripts/steelblue/"
    os.execute(string.format("mkdir -p %q", dir))
    for _, file in ipairs(setup.already_there) do
      local h = io.open(dir .. file, "wb")
      h:write("-- left over from an earlier install\n")
      h:close()
    end
  end

  -- Someone else's startup script, already in place before we ever run.
  if setup.startup_before then
    local dir = scenario.resource_path .. "/Scripts/"
    os.execute(string.format("mkdir -p %q", dir))
    local h = io.open(dir .. "__startup.eel", "wb")
    h:write(setup.startup_before)
    h:close()
  end

  -- What v2g left on this machine: a block in the Lua startup file REAPER never
  -- runs.
  if setup.legacy_before then
    local dir = scenario.resource_path .. "/Scripts/"
    os.execute(string.format("mkdir -p %q", dir))
    local h = io.open(dir .. "__startup.lua", "wb")
    h:write(setup.legacy_before)
    h:close()
  end

  answers = setup.answers or {}
  answer_at = 0
  log = {}
  reaper = fake()
  watch_removals()

  local ok, err = pcall(dofile, PKG .. "steelblue_install.lua")
  os.remove = real_remove
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

-- The startup file as it stands on disk right now, or nil if there is none.
local function read_startup(name)
  local h = io.open(scenario.resource_path .. "/Scripts/" .. name, "rb")
  if not h then
    return nil
  end
  local data = h:read("a")
  h:close()
  return data
end

local function startup_text() return read_startup("__startup.eel") end
local function legacy_text() return read_startup("__startup.lua") end

local function occurrences(haystack, needle)
  local n, at = 0, 1
  while true do
    local from, to = haystack:find(needle, at, true)
    if not from then return n end
    n = n + 1
    at = to + 1
  end
end

-- Run the installer once more into the same fake REAPER, the way a second
-- install over an existing one does.
local function run_again()
  answers = { 1, 7 }
  answer_at = 0
  local ok, err = pcall(dofile, PKG .. "steelblue_install.lua")
  return ok, err
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
-- Five since v2a: the workspace is an action like the other four.
check(run("happy path: 5 registered, 5 shortcut dialogs", {
  imgui = true, js = true, answers = { 1, 6, 1, 1, 1, 1, 1 },
}, function(log)
  local reg, dlg = count(log, "register"), count(log, "shortcut_dialog")
  if reg ~= 5 then return false, "registered " .. reg .. ", expected 5" end
  if dlg ~= 5 then return false, "opened " .. dlg .. " shortcut dialogs, expected 5" end
  return true, "5 registered, 5 dialogs"
end))

-- the files must physically arrive, and the registration must point AT them
check(run("files land in REAPER's Scripts folder", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  local dir = scenario.resource_path .. "/Scripts/steelblue/"
  local want = {
    "Live BPM Analyzer.lua", "MIDI notes to project markers.lua",
    "Rename selected markers.lua", "CopyMarkers.lua",
    "steelblue_workspace.lua",
    "steelblue_ui.lua", "steelblue_markers.lua",
    "steelblue_boot.lua", "steelblue_matools.lua",
    "steelblue_rename.lua", "steelblue_midi.lua", "steelblue_copy.lua",
    "steelblue_bpm.lua",
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
  return true, "13 files copied, actions point at the copies"
end))

-- 2026-09-11: an old steelblue_workspace.lua was still lying next to the new
-- modules, REAPER launched it, and the only symptom was "attempt to call a nil
-- value (field 'begin_dock_window')". The installer owns that folder, so it
-- clears out what it no longer ships.
check(run("stale .lua files in the install folder are removed and named", {
  imgui = true, js = true, answers = { 1, 7 },
  already_there = { "old_thing.lua", "notes.txt", "steelblue_ui.lua" },
}, function(log)
  local dir = scenario.resource_path .. "/Scripts/steelblue/"
  local gone = removed_files(log)

  if #gone ~= 1 or gone[1] ~= "old_thing.lua" then
    return false, "os.remove called for: " .. (#gone == 0 and "nothing" or table.concat(gone, ", "))
  end

  -- and it really is gone, while the two files that stay really stayed
  if io.open(dir .. "old_thing.lua", "rb") then return false, "old_thing.lua is still there" end
  for _, keep in ipairs({ "notes.txt", "steelblue_ui.lua" }) do
    local h = io.open(dir .. keep, "rb")
    if not h then return false, "deleted " .. keep .. ", which it must not touch" end
    h:close()
  end

  -- a file vanishing without a word is exactly the kind of surprise that
  -- cost the evening this whole thing is about
  local said = nil
  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:find("Removed (no longer part of the set):", 1, true) then
      said = e.text
    end
  end
  if not said then return false, "the summary never mentioned the removal" end
  if not said:find("old_thing.lua", 1, true) then return false, "the summary did not name the file" end

  return true, "old_thing.lua removed and listed; notes.txt and the payload untouched"
end))

check(run("nothing is removed when the folder is clean", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  local gone = removed_files(log)
  if #gone > 0 then return false, "removed " .. table.concat(gone, ", ") end

  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:find("Removed (no longer part of the set):", 1, true) then
      return false, "the summary has an empty Removed block"
    end
  end

  return true, "nothing deleted, no Removed block in the summary"
end))

-- --- the startup script ----------------------------------------------------

-- Tobi, 2026-09-16: "steelblue workspace bleibt nach Restart von REAPER nicht
-- aktiv." REAPER restores its own windows and never a ReaScript one, so the
-- installer leaves a marked block in <resource>/Scripts/__startup.eel that runs
-- the workspace action again -- but only if the workspace said it was open.
--
-- .eel, not .lua: v2g wrote the Lua file on the strength of a blog post and
-- nothing ran. REAPER 7.80's binary contains "%s/__startup.eel" and no Lua
-- twin.

check(run("a) no __startup.eel yet: one is written with both markers", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  local text = startup_text()
  if not text then return false, "no __startup.eel was written" end
  if not text:find(STARTUP_BEGIN, 1, true) then return false, "no begin marker" end
  if not text:find(STARTUP_END, 1, true) then return false, "no end marker" end
  if not text:find(WORKSPACE_COMMAND_ID, 1, true) then
    return false, "the block names no command id: " .. text
  end
  -- the workspace's id, not some other plugin's
  if text:find("RSother", 1, true) then return false, "named the wrong action" end
  if not dialogs_matching(log, "Reopens the workspace at startup") then
    return false, "the summary never mentioned the autostart"
  end
  return true, "written, both markers, " .. WORKSPACE_COMMAND_ID
end))

-- Somebody else's startup script is the normal case, not the exception: this
-- file is where every REAPER user parks their own launch code.
local FOREIGN = 'ShowConsoleMsg("hello from my own startup\\n");\nsomebody_else = 1;\n'

check(run("b) a foreign __startup.eel keeps its bytes, block goes behind", {
  imgui = true, js = true, answers = { 1, 7 }, startup_before = FOREIGN,
}, function()
  local text = startup_text()
  if not text then return false, "the file disappeared" end
  if text:sub(1, #FOREIGN) ~= FOREIGN then
    return false, "the foreign lines were changed: " .. string.format("%q", text:sub(1, #FOREIGN))
  end
  if occurrences(text, STARTUP_BEGIN) ~= 1 then
    return false, occurrences(text, STARTUP_BEGIN) .. " begin markers, expected 1"
  end
  if text:find(STARTUP_BEGIN, 1, true) < #FOREIGN then
    return false, "our block was put in front of the foreign lines"
  end
  return true, "two foreign lines byte-identical, one block behind them"
end))

check(run("c) a second install replaces the block instead of stacking it", {
  imgui = true, js = true, answers = { 1, 7 }, startup_before = FOREIGN,
}, function()
  local ok, err = run_again()
  if not ok then return false, "the second run failed: " .. tostring(err) end

  local text = startup_text()
  if not text then return false, "the file disappeared" end
  if text:sub(1, #FOREIGN) ~= FOREIGN then
    return false, "the second run changed the foreign lines"
  end
  local begins, ends = occurrences(text, STARTUP_BEGIN), occurrences(text, STARTUP_END)
  if begins ~= 1 or ends ~= 1 then
    return false, begins .. " begin / " .. ends .. " end markers after two runs, expected 1 / 1"
  end
  return true, "still exactly one block, foreign lines untouched"
end))

check(run("d) no ReverseNamedCommandLookup: no file, and the summary says so", {
  imgui = true, js = true, answers = { 1, 7 }, no_reverse_lookup = true,
}, function(log)
  if startup_text() then return false, "wrote a startup file with no command id to put in it" end
  if not dialogs_matching(log, "Autostart not set up") then
    return false, "the summary claimed nothing was wrong"
  end
  if dialogs_matching(log, "Reopens the workspace at startup") then
    return false, "the summary promised an autostart it did not set up"
  end
  return true, "nothing written, summary says 'Autostart not set up (no command id)'"
end))

-- A startup script that does not compile takes every other startup script down
-- with it. v2g could prove that by running the block through `load()`; EEL2 has
-- no interpreter here, so this reads the block instead. Four things, each of
-- which has been wrong in a hand-written EEL block before:
--   * the three API calls are spelled the way the EEL2 column of the ReaScript
--     reference spells them, and the names really exist in the REAPER binary;
--   * no line starts with "--" (that is a Lua comment; in EEL2 it is a minus
--     sign followed by a minus sign, i.e. a syntax error);
--   * the parentheses balance -- the `cond ? ( ... );` block is the one place
--     that is easy to leave open;
--   * every statement ends in ";". A line may end in "(" instead, which opens
--     such a block; the last code line may not.
check(run("e) the block is EEL2, not Lua, and guards on autostart", {
  imgui = true, js = true, answers = { 1, 7 },
}, function()
  local text = startup_text()
  if not text then return false, "no __startup.eel was written" end

  local begin_at = text:find(STARTUP_BEGIN, 1, true)
  local _, end_at = text:find(STARTUP_END, 1, true)
  if not (begin_at and end_at) then return false, "no block to look at" end
  local block = text:sub(begin_at, end_at)

  -- The three calls, literally, in the EEL2 spelling. GetExtState takes its
  -- output buffer FIRST in EEL2 -- that is the whole reason this block cannot
  -- be a transliteration of the Lua one.
  local wanted = {
    'GetExtState(#steelblue_autostart, "steelblue_workspace", "autostart")',
    'NamedCommandLookup("' .. WORKSPACE_COMMAND_ID .. '")',
    "Main_OnCommand(steelblue_cmd, 0)",
  }
  for _, call in ipairs(wanted) do
    if not block:find(call, 1, true) then
      return false, "the block never calls " .. call
    end
  end

  -- A name that is not in the binary is a typo nobody would see until REAPER
  -- silently skipped the startup file on a stranger's machine.
  for _, name in ipairs({ "GetExtState", "NamedCommandLookup", "Main_OnCommand" }) do
    local p = io.popen(string.format("strings %q | grep -cx -- %q", REAPER_BIN, name))
    local hits = tonumber(p:read("a")) or 0
    p:close()
    if hits == 0 then return false, name .. " is not in the REAPER binary" end
  end

  local depth, last_code = 0, nil
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed:sub(1, 2) == "--" then
      return false, "a Lua comment in an EEL file: " .. trimmed
    end
    if trimmed ~= "" and trimmed:sub(1, 2) ~= "//" then
      last_code = trimmed
      local tail = trimmed:sub(-1)
      if tail ~= ";" and tail ~= "(" then
        return false, "statement does not end in ';': " .. trimmed
      end
      for c in trimmed:gmatch("[()]") do
        depth = depth + (c == "(" and 1 or -1)
        if depth < 0 then return false, "a ')' with nothing open: " .. trimmed end
      end
    end
  end

  if depth ~= 0 then return false, depth .. " parenthesis/es left open" end
  if not last_code or last_code:sub(-1) ~= ";" then
    return false, "the block's last statement does not end in ';'"
  end

  -- The action must sit inside the strcmp guard, not next to it: an unguarded
  -- Main_OnCommand would reopen the workspace Tobi closed on purpose.
  local guard_at = block:find('strcmp(#steelblue_autostart, "1") == 0 ?', 1, true)
  local action_at = block:find("Main_OnCommand", 1, true)
  if not guard_at or not action_at or action_at < guard_at then
    return false, "Main_OnCommand is not behind the autostart guard"
  end

  return true, "EEL2 spelling, balanced, guarded on autostart"
end))

-- --- the file v2g wrote, and REAPER never ran -------------------------------

local LEGACY_FOREIGN = 'reaper.ShowConsoleMsg("my own startup\\n")\nlocal x = 1\n'

check(run("f) the old Lua block goes, the foreign lines stay byte for byte", {
  imgui = true, js = true, answers = { 1, 7 },
  legacy_before = LEGACY_FOREIGN .. "\n" .. LEGACY_BLOCK .. "\n",
}, function()
  local text = legacy_text()
  if not text then return false, "__startup.lua was deleted although it had foreign lines in it" end
  if text:find(LEGACY_BEGIN, 1, true) or text:find(LEGACY_END, 1, true) then
    return false, "our old block is still in __startup.lua"
  end
  if text ~= LEGACY_FOREIGN then
    return false, "the foreign lines came back changed: " .. string.format("%q", text)
  end
  return true, "block removed, foreign lines byte-identical"
end))

check(run("g) __startup.lua with nothing but our block is deleted", {
  imgui = true, js = true, answers = { 1, 7 },
  legacy_before = LEGACY_BLOCK .. "\n",
}, function(log)
  if legacy_text() then
    return false, "an empty __startup.lua was left behind: " .. string.format("%q", legacy_text())
  end
  local gone = removed_files(log)
  local named = false
  for _, name in ipairs(gone) do
    if name == "__startup.lua" then named = true end
  end
  if not named then
    return false, "the file is gone but os.remove was never called for it"
  end
  return true, "file removed"
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
  local text = dialogs_matching(log, "cannot find the plugins")
  if not text then return false, "aborted without saying why" end
  if not text:find("CopyMarkers%.lua") then return false, "did not name the missing file" end
  return true, "stopped and named the missing file"
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

-- A just-placed extension is not loaded yet, so APIExists still says no. The
-- summary must not report that as "missing" — it just installed the thing.
check(run("does not call a just-installed extension missing", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7, 1, 7 },
}, function(log)
  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:find("Installed:") then
      if e.text:find("ReaImGui is missing") then
        return false, "reported ReaImGui as missing right after installing it"
      end
      if e.text:find("js_ReaScriptAPI is missing") then
        return false, "reported js_ReaScriptAPI as missing right after installing it"
      end
      return true, "summary stays quiet, the quit window explains"
    end
  end
  return false, "no summary at all"
end))

-- 64-bit Windows: the x64 builds, and only those
check(run("Windows 64-bit gets the x64 builds", {
  imgui = false, js = false, os = "Win64", answers = { 1, 1, 1, 7 },
}, function()
  local got = extensions_written(scenario)
  if not got:find("reaper_imgui%-x64%.dll") then return false, "no x64 ReaImGui" end
  if not got:find("reaper_js_ReaScriptAPI64%.dll") then return false, "no x64 js_ReaScriptAPI" end
  if got:find("x86%.dll") or got:find("API32") then return false, "wrote a 32-bit build to a 64-bit machine!" end
  if got:find("dylib") then return false, "wrote a macOS build to a Windows machine!" end
  return true, "x64 only, as it should be"
end))

-- 32-bit Windows: the x86 builds, and only those
check(run("Windows 32-bit gets the x86 builds", {
  imgui = false, js = false, os = "Win32", answers = { 1, 1, 1, 7 },
}, function()
  local got = extensions_written(scenario)
  if not got:find("reaper_imgui%-x86%.dll") then return false, "no x86 ReaImGui" end
  if not got:find("reaper_js_ReaScriptAPI32%.dll") then return false, "no x86 js_ReaScriptAPI" end
  if got:find("x64%.dll") or got:find("API64") then return false, "wrote a 64-bit build to a 32-bit machine!" end
  return true, "x86 only, as it should be"
end))

-- Quarantine is a macOS idea and /usr/bin/xattr is a macOS path. Calling it on
-- Windows would stall for the ExecProcess timeout and achieve nothing.
check(run("Windows never shells out to xattr or lipo", {
  imgui = false, js = false, os = "Win64", answers = { 1, 1, 1, 7 },
}, function(log)
  for _, e in ipairs(log) do
    if e.kind == "exec" then
      return false, "ran a macOS-only tool on Windows: " .. tostring(e.cmd)
    end
  end
  return true, "no shelling out at all"
end))

-- ...but macOS still must, or REAPER silently ignores the quarantined file.
check(run("macOS still clears the quarantine flag", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7 },
}, function(log)
  for _, e in ipairs(log) do
    if e.kind == "exec" and tostring(e.cmd):find("xattr", 1, true) then
      return true, "xattr -d com.apple.quarantine ran"
    end
  end
  return false, "never cleared the quarantine flag!"
end))

-- no bundle for this platform -> fall back to browse-for-file. Linux, because
-- we genuinely ship no build for it: this scenario used to say "Win64", which
-- stopped being true the moment the Windows DLLs were bundled.
check(run("unsupported platform falls back to browse", {
  imgui = false, js = false, os = "Linux64", answers = { 1, 2, 2, 7 },
}, function(log)
  return dialogs_matching(log, "If you have already downloaded") ~= nil, "offers the file picker"
end))

-- --- the restart offer ------------------------------------------------------

local QUIT_REAPER = 40004

-- Quitting someone's REAPER uninvited would be unforgivable, so the important
-- tests here are the ones where it must NOT happen.
check(run("nothing installed -> never offers to quit", {
  imgui = true, js = true, answers = { 1, 7 },
}, function(log)
  if count(log, "command") > 0 then return false, "issued a command with nothing to quit for!" end
  return dialogs_matching(log, "Quit REAPER now") == nil, "no offer, no quit"
end))

check(run("saying No to the quit does not quit", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7, 1, 7 },
}, function(log)
  if not dialogs_matching(log, "Quit REAPER now") then return false, "never offered" end
  for _, e in ipairs(log) do
    if e.kind == "command" then return false, "quit REAPER anyway!" end
  end
  return true, "offered, and took No for an answer"
end))

check(run("saying Yes quits via the Main-section Quit action", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7, 1, 6 },
}, function(log)
  local quit = nil
  for _, e in ipairs(log) do
    if e.kind == "command" then quit = e.cmd end
  end
  return quit == QUIT_REAPER,
    quit == QUIT_REAPER and "Quit REAPER (40004), nothing else"
    or ("issued command " .. tostring(quit) .. ", expected " .. QUIT_REAPER)
end))

-- it must never promise a restart it cannot deliver
check(run("never promises a restart", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7, 1, 7 },
}, function(log)
  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:lower():find("restart") then
      return false, "still says 'restart' somewhere: " .. e.text:sub(1, 40)
    end
  end
  return true, "says quit, does quit"
end))

-- the summary and the quit dialog must not both explain the same thing
check(run("the restart hint is not said twice", {
  imgui = false, js = false, os = "macOS-arm64", answers = { 1, 1, 1, 7, 1, 7 },
}, function(log)
  local n = 0
  for _, e in ipairs(log) do
    if e.kind == "dialog" and e.text:find("only loads those when it starts") then n = n + 1 end
  end
  return n == 1, n .. " window(s) explain the startup thing — exactly one should"
end))

-- --- where the installer sits ----------------------------------------------

-- On the disk image it lives at the top, with the payload one folder down.
-- Build that layout for real and run the installer from it.
local function run_from_layout(name, build, check)
  local p = io.popen("mktemp -d")
  local root = (p:read("a") or ""):gsub("%s+$", "")
  p:close()
  build(root)

  local q = io.popen("mktemp -d")
  scenario = { imgui = true, js = true, resource_path = (q:read("a") or ""):gsub("%s+$", "") }
  q:close()

  answers = { 1, 7 }
  answer_at = 0
  log = {}
  reaper = fake()

  local ok, err = pcall(dofile, root .. "/steelblue_install.lua")
  if not ok then
    print(string.format("  FAIL  %-42s error: %s", name, err))
    return false
  end

  local passed, detail = check(log)
  print(string.format("  %s  %-42s %s", passed and "PASS" or "FAIL", name, detail or ""))
  return passed
end

print("")

check(run_from_layout("disk-image layout: installer on top", function(root)
  os.execute(string.format('mkdir -p %q', root .. "/steelblue Plugin Set"))
  os.execute(string.format('cp %q %q', PKG .. "steelblue_install.lua", root .. "/"))
  os.execute(string.format('cp %q/*.lua %q/ 2>/dev/null', PKG:sub(1, -2), root .. "/steelblue Plugin Set"))
  os.execute(string.format('cp -R %q %q/ 2>/dev/null', PKG .. "extensions", root .. "/steelblue Plugin Set"))
end, function(log)
  if count(log, "register") ~= 5 then
    return false, "found nothing: registered " .. count(log, "register")
  end
  return true, "found the payload one folder down"
end))

check(run_from_layout("copied-folder layout: all in one place", function(root)
  os.execute(string.format('cp %q/*.lua %q/ 2>/dev/null', PKG:sub(1, -2), root))
  os.execute(string.format('cp -R %q %q/ 2>/dev/null', PKG .. "extensions", root))
end, function(log)
  return count(log, "register") == 5, "found the payload next to itself"
end))

check(run_from_layout("installer dragged out on its own", function(root)
  os.execute(string.format('cp %q %q/', PKG .. "steelblue_install.lua", root))
end, function(log)
  if count(log, "register") > 0 then return false, "registered something out of thin air!" end
  local text = dialogs_matching(log, "cannot find the plugins")
  if not text then return false, "failed without saying why" end
  if not text:find("Looked in") then return false, "did not say where it looked" end
  return true, "explains what is missing and where it looked"
end))

-- Both halves must be reported, or the summary contradicts the exit code: this
-- printed "ALL PASS" and exited 1 for an unknown API, which reads as a broken
-- test rather than the real finding it was.
if fails > 0 then
  print("\nFAILURES: " .. fails)
end
if #unknown > 0 then
  print(string.format("\n%d API name(s) not found in the REAPER binary -- see above", #unknown))
end
if fails == 0 and #unknown == 0 then
  print("\nALL PASS")
end

os.exit((fails == 0 and #unknown == 0) and 0 or 1)
