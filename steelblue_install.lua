-- steelblue_install.lua
-- One-time installer for the steelblue REAPER LD Plugin Set.
--
-- Run once: Actions > Show Action List > New action... > Load ReaScript...
-- pick this file, then run it. It registers the four plugins as actions and
-- offers to put a keyboard shortcut on each.
--
-- Deliberately built with plain REAPER dialogs, NOT with steelblue_ui.lua:
-- this script exists for the case where ReaImGui is missing, so it cannot
-- depend on ReaImGui to draw itself.

local TITLE = "steelblue Plugin Set — Installer"

local PLUGINS = {
  { file = "Live BPM Analyzer.lua",             name = "Live BPM Analyzer",             suggested = "Cmd+Shift+B" },
  { file = "MIDI notes to project markers.lua", name = "MIDI notes to project markers", suggested = "Cmd+Shift+H" },
  { file = "Rename selected markers.lua",       name = "Rename selected markers",       suggested = "Cmd+Shift+N" },
  { file = "CopyMarkers.lua",                   name = "Copy Markers",                  suggested = "Opt+C" },
}

-- Shipped alongside the plugins; without them the plugins refuse to start.
local MODULES = { "steelblue_ui.lua", "steelblue_markers.lua" }

-- Bundled third-party extensions, per architecture. See extensions/NOTICE.txt:
-- ReaImGui is LGPL-3.0, js_ReaScriptAPI is MIT, both are shipped unmodified and
-- only ever written when nothing is installed — never over someone's own copy.
local EXTENSIONS = {
  {
    name = "ReaImGui",
    api = "ImGui_CreateContext",
    version = "0.10.0.5",
    files = {
      ["macOS-arm64"] = "reaper_imgui-arm64.dylib",
      ["OSX64"] = "reaper_imgui-x86_64.dylib",
    },
    why = "All four plugins draw their windows with it. Without it the Live BPM Analyzer refuses to start and the others fall back to plain system dialogs.",
  },
  {
    name = "js_ReaScriptAPI",
    api = "JS_Window_ArrayFind",
    version = "1.310",
    files = {
      ["macOS-arm64"] = "reaper_js_ReaScriptAPI64ARM.dylib",
      ["OSX64"] = "reaper_js_ReaScriptAPI64.dylib",
    },
    why = "Only 'Rename selected markers' needs it, to read the order of your selection in the Region/Marker Manager. Without it the cue numbering silently follows plain timeline order instead.",
  },
}

-- Our plugins are written against the ReaImGui 0.10 API (ImGui_PushFont takes a
-- size). An older one is worse than none: it is present, so we leave it alone,
-- and the plugins then misbehave in ways nobody would connect to a version.
local REAIMGUI_MIN = "0.10"

local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""
local SEP = package.config:sub(1, 1)

-- Where the plugins actually are. Two layouts have to work:
--   * on the disk image the installer sits at the top, next to the note, and
--     everything else is one folder down — so people see two items, not twenty
--   * inside the copied package folder it sits among its own files
-- Anything else (someone dragging the single .lua out somewhere) has no payload
-- and must be told, not left to fail on the first missing file.
local PAYLOAD_SUBFOLDER = "steelblue Plugin Set"

local folder = (function()
  for _, dir in ipairs({ script_dir, script_dir .. PAYLOAD_SUBFOLDER .. SEP }) do
    local probe = io.open(dir .. "steelblue_ui.lua", "rb")
    if probe then
      probe:close()
      return dir
    end
  end
  return script_dir
end)()

local MB_OK, MB_OKCANCEL, MB_YESNO = 0, 1, 4
local ID_OK, ID_YES = 1, 6

-- The plugins are copied into REAPER's own Scripts folder and registered from
-- there, so the disk image can be thrown away afterwards. Registering them
-- where they happen to sit right now is how you end up with REAPER launching a
-- file off someone's Desktop months later.
local function install_dir()
  return reaper.GetResourcePath() .. SEP .. "Scripts" .. SEP .. "steelblue" .. SEP
end

local function copy_file(from, to)
  local src = io.open(from, "rb")
  if not src then
    return false
  end
  local data = src:read("a")
  src:close()

  local dst = io.open(to, "wb")
  if not dst then
    return false
  end
  dst:write(data)
  dst:close()
  return true
end

local function say(message, buttons)
  return reaper.ShowMessageBox(message, TITLE, buttons or MB_OK)
end

-- ---------------------------------------------------------------- checks

local function missing_files()
  local missing = {}

  for _, plugin in ipairs(PLUGINS) do
    if not reaper.file_exists(folder .. plugin.file) then
      missing[#missing + 1] = plugin.file
    end
  end

  for _, module in ipairs(MODULES) do
    if not reaper.file_exists(folder .. module) then
      missing[#missing + 1] = module
    end
  end

  return missing
end

local function has_reaimgui()
  return reaper.APIExists and reaper.APIExists("ImGui_CreateContext")
end

local function has_js_api()
  return reaper.APIExists and reaper.APIExists("JS_Window_ArrayFind")
end

local function version_at_least(have, want)
  local function parts(v)
    local out = {}
    for n in tostring(v):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
  end

  local a, b = parts(have), parts(want)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then
      return x > y
    end
  end
  return true
end

-- Someone with an OLDER ReaImGui is the awkward case: it is present, so we
-- leave it alone as promised, and the plugins then misbehave in ways nobody
-- would trace back to a version number. So say it plainly.
local function reaimgui_too_old()
  if not has_reaimgui() then
    return false, nil
  end
  if not reaper.APIExists("ImGui_GetVersion") then
    return false, nil
  end

  local ok, _, _, installed = pcall(reaper.ImGui_GetVersion)
  if not ok or not installed or installed == "" then
    return false, nil
  end

  return not version_at_least(installed, REAIMGUI_MIN), installed
end

-- ---------------------------------------------------------------- extensions

-- Extensions are not redistributed with this package: the user downloads the
-- build for their own machine, and the installer only puts it in the right
-- place. That keeps us clear of ReaImGui's LGPL obligations and of shipping an
-- arm64 binary to someone on Intel or Windows.
local function user_plugins_dir()
  local sep = package.config:sub(1, 1)
  return reaper.GetResourcePath() .. sep .. "UserPlugins" .. sep
end

local function file_name_of(path)
  return path:match("([^/\\]+)$") or path
end

local function place(source_path, file_name)
  local target = user_plugins_dir() .. file_name
  reaper.RecursiveCreateDirectory(user_plugins_dir(), 0)

  if not copy_file(source_path, target) then
    say("Could not write to:\n" .. target, MB_OK)
    return false
  end

  -- Anything fetched with a browser carries com.apple.quarantine, and REAPER
  -- silently ignores a quarantined extension. Harmless on our own bundled copy.
  reaper.ExecProcess('/usr/bin/xattr -d com.apple.quarantine "' .. target .. '"', 5000)
  return true
end

-- The bundled build for this machine, or nil if we do not ship one for it.
local function bundled_path(ext)
  local file = ext.files[reaper.GetOS()]
  if not file then
    return nil
  end

  local source = folder .. "extensions" .. SEP .. "macOS" .. SEP .. file
  if not reaper.file_exists(source) then
    return nil
  end

  return source, file
end

-- Fallback: the user points at a file they downloaded themselves.
local function install_from_disk(ext)
  local ok = say(
    ext.name .. " is not installed.\n\n" .. ext.why .. "\n\n" ..
    "This package does not include a build for your system, so you will need it from " ..
    "the author — the easiest route is ReaPack (reapack.com).\n\n" ..
    "If you have already downloaded it, I can put it in the right folder.\n\n" ..
    "OK = pick the file\nCancel = skip",
    MB_OKCANCEL
  )
  if ok ~= ID_OK then
    return false
  end

  local picked, path = reaper.GetUserFileNameForRead("", "Select the downloaded " .. ext.name .. " file", "")
  if not picked then
    return false
  end

  -- Check the architecture before copying, so nobody spends an evening
  -- wondering why REAPER quietly ignores a perfectly good file.
  local arch = reaper.ExecProcess('/usr/bin/lipo -archs "' .. path .. '"', 5000)
  if arch and arch ~= "" then
    local archs = (arch:match("\n(.*)$") or ""):gsub("%s+$", "")
    local want = reaper.GetOS() == "macOS-arm64" and "arm64" or "x86_64"
    if archs ~= "" and not archs:find(want) then
      say(
        "That file is built for '" .. archs .. "', but this machine needs '" .. want .. "'.\n\n" ..
        "REAPER would ignore it without a word. Nothing was copied.",
        MB_OK
      )
      return false
    end
  end

  return place(path, file_name_of(path))
end

-- Returns: ok, placed_something.
-- Whatever happens, the user must always learn that it is missing and what that
-- costs them — never just get asked for a file out of nowhere.
local function ensure_extension(ext)
  if reaper.APIExists and reaper.APIExists(ext.api) then
    return true, false      -- present: leave it strictly alone
  end

  local source, file = bundled_path(ext)
  if not source then
    return install_from_disk(ext), false
  end

  local wanted = say(
    ext.name .. " is not installed.\n\n" .. ext.why .. "\n\n" ..
    "Version " .. ext.version .. " is included with this package — I can install it now.\n\n" ..
    "It is the author's own unmodified build, shipped under its own licence " ..
    "(see extensions/NOTICE.txt). Updates come through ReaPack; this copy will not " ..
    "update itself, and it is never written over a copy you already have.\n\n" ..
    "OK = install it\nCancel = I will get it myself",
    MB_OKCANCEL
  )
  if wanted ~= ID_OK then
    return false, false
  end

  if place(source, file) then
    return true, true       -- placed: REAPER must restart before it loads
  end

  return false, false
end

-- ---------------------------------------------------------------- install

-- Returns the folder the plugins were put in, or nil.
local function copy_into_reaper()
  local target = install_dir()

  -- already running from inside the install folder? then there is nothing to do
  if folder:lower() == target:lower() then
    return target
  end

  reaper.RecursiveCreateDirectory(target, 0)

  local failed = {}
  for _, name in ipairs({ PLUGINS[1].file, PLUGINS[2].file, PLUGINS[3].file, PLUGINS[4].file,
                          MODULES[1], MODULES[2] }) do
    if not copy_file(folder .. name, target .. name) then
      failed[#failed + 1] = name
    end
  end

  if #failed > 0 then
    say(
      "Could not copy these into REAPER's Scripts folder:\n\n   " ..
      table.concat(failed, "\n   ") ..
      "\n\nTarget was:\n" .. target,
      MB_OK
    )
    return nil
  end

  return target
end

local function register_plugins(target)
  local section = reaper.SectionFromUniqueID(0)   -- 0 = Main
  local registered = {}

  for index, plugin in ipairs(PLUGINS) do
    local last = index == #PLUGINS
    local cmd = reaper.AddRemoveReaScript(true, 0, target .. plugin.file, last)
    if cmd and cmd ~= 0 then
      registered[#registered + 1] = { plugin = plugin, cmd = cmd, section = section }
    end
  end

  return registered
end

local function shortcut_of(entry)
  if reaper.CountActionShortcuts(entry.section, entry.cmd) < 1 then
    return nil
  end

  local ok, desc = reaper.GetActionShortcutDesc(entry.section, entry.cmd, 0, "", 256)
  if ok and desc ~= "" then
    return desc
  end

  return nil
end

-- REAPER has no API to *set* a shortcut, only to open its own dialog for one.
-- So the user presses the keys; we just walk them through it and read back the
-- result.
local function assign_shortcuts(registered)
  local wanted = say(
    "Assign keyboard shortcuts now?\n\n" ..
    "REAPER cannot be given a shortcut by a script — it has to be typed into its own dialog.\n" ..
    "I will open that dialog once per plugin; press the keys you want, then confirm.\n\n" ..
    "steelblue uses:\n" ..
    "   Cmd+Shift+B    Live BPM Analyzer\n" ..
    "   Cmd+Shift+H    MIDI notes to project markers\n" ..
    "   Cmd+Shift+N    Rename selected markers\n" ..
    "   Opt+C          Copy Markers\n\n" ..
    "Yes = assign them now\nNo = skip (you can do it later in the Action List)",
    MB_YESNO
  )
  if wanted ~= ID_YES then
    return
  end

  for _, entry in ipairs(registered) do
    if not shortcut_of(entry) then
      say(
        entry.plugin.name .. "\n\nSuggested: " .. entry.plugin.suggested ..
        "\n\nThe shortcut dialog opens next — press the keys you want, then click OK in it.",
        MB_OK
      )
      reaper.DoActionShortcutDialog(0, entry.section, entry.cmd, -1)
    end
  end
end

-- ---------------------------------------------------------------- report

local function summary(registered, target, restart_needed)
  local lines = { "Installed:", "" }

  for _, entry in ipairs(registered) do
    local key = shortcut_of(entry) or "no shortcut yet"
    lines[#lines + 1] = string.format("   %-36s %s", entry.plugin.name, key)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Copied to:"
  lines[#lines + 1] = "   " .. target
  lines[#lines + 1] = ""
  lines[#lines + 1] = "The disk image is no longer needed — you can eject and delete it."
  lines[#lines + 1] = "The plugins are in the Action List under their file names."
  lines[#lines + 1] = ""

  -- An extension placed a minute ago is not loaded yet: REAPER reads UserPlugins
  -- only at startup, so APIExists still says no. Do not report that as a failure.
  if restart_needed then
    lines[#lines + 1] = ">> RESTART REAPER NOW. <<"
    lines[#lines + 1] = "An extension was just installed, and REAPER only loads those when it starts."
    lines[#lines + 1] = "The plugins will not work until you have restarted."
  elseif has_reaimgui() and has_js_api() then
    lines[#lines + 1] = "Both extensions are present. You are ready to go."
  else
    if not has_reaimgui() then
      lines[#lines + 1] = "! ReaImGui is missing — all four plugins need it. Get it via ReaPack (reapack.com)."
    end
    if not has_js_api() then
      lines[#lines + 1] = "! js_ReaScriptAPI is missing — Rename selected markers will number cues in plain timeline order without it."
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "How-to guides: the Tutorials folder next to this script."
  lines[#lines + 1] = "Something to practise on: the Demo Project folder."

  say(table.concat(lines, "\n"), MB_OK)
end

-- ---------------------------------------------------------------- restart

-- REAPER has no "restart" action — only "File: Quit REAPER" (Main 40004; the
-- same number means something else entirely in other sections, which is why
-- this goes through Main_OnCommand).
--
-- So: leave a small script behind that waits for REAPER to disappear and then
-- starts it again. It gives up after a minute and only relaunches if REAPER
-- really quit — otherwise cancelling the quit dialog would leave a watcher
-- lurking that reopens REAPER the next time you close it that evening.
local function offer_restart()
  if reaper.GetOS() ~= "macOS-arm64" and reaper.GetOS() ~= "OSX64" then
    return
  end

  local want = say(
    "Restart REAPER now?\n\n" ..
    "An extension was just installed, and REAPER only loads those when it starts. " ..
    "Until then the plugins will not work.\n\n" ..
    "Yes = quit and start REAPER again\n" ..
    "No = I will restart it myself\n\n" ..
    "If you have unsaved work, REAPER will ask about it as usual.",
    MB_YESNO
  )
  if want ~= ID_YES then
    return
  end

  local helper = "/tmp/steelblue_restart.sh"
  local f = io.open(helper, "w")
  if not f then
    say("Could not prepare the restart. Please quit and start REAPER yourself.", MB_OK)
    return
  end

  f:write([[#!/bin/sh
n=0
while [ $n -lt 60 ]; do
  pgrep -x REAPER >/dev/null 2>&1 || break
  sleep 1
  n=$((n + 1))
done
pgrep -x REAPER >/dev/null 2>&1 || open -a REAPER
rm -f "$0"
]])
  f:close()

  reaper.ExecProcess('/bin/sh "' .. helper .. '"', -1)   -- -1 = do not wait
  reaper.Main_OnCommand(40004, 0)                        -- File: Quit REAPER
end

-- ---------------------------------------------------------------- main

local function main()
  local missing = missing_files()
  if #missing > 0 then
    say(
      "The installer cannot find the plugins.\n\nMissing:\n\n   " ..
      table.concat(missing, "\n   ") ..
      "\n\nLooked in:\n   " .. folder ..
      "\n\nRun the installer from the disk image, or from the copied package folder — " ..
      "not on its own. It needs the other files to be with it.",
      MB_OK
    )
    return
  end

  local go = say(
    "This installs the steelblue REAPER LD Plugin Set:\n\n" ..
    "   Live BPM Analyzer\n" ..
    "   MIDI notes to project markers\n" ..
    "   Rename selected markers\n" ..
    "   Copy Markers\n\n" ..
    "The plugins are copied into REAPER's own Scripts folder, registered as actions, " ..
    "and you get the chance to put a shortcut on each.\n\n" ..
    "Afterwards you can delete the disk image — REAPER will not need it again.\n\n" ..
    "OK = install\nCancel = stop here",
    MB_OKCANCEL
  )
  if go ~= ID_OK then
    return
  end

  local old, installed_version = reaimgui_too_old()
  if old then
    say(
      "Your ReaImGui is version " .. tostring(installed_version) .. ".\n\n" ..
      "These plugins need " .. REAIMGUI_MIN .. " or newer, and will look wrong on an older one.\n\n" ..
      "I will not overwrite an extension you already have. Please update ReaImGui — through " ..
      "ReaPack (Extensions > ReaPack > Synchronize Packages), or from codeberg.org/cfillion/reaimgui.",
      MB_OK
    )
  end

  local restart_needed = false
  for _, ext in ipairs(EXTENSIONS) do
    local _, placed = ensure_extension(ext)
    restart_needed = restart_needed or placed
  end

  local target = copy_into_reaper()
  if not target then
    return
  end

  local registered = register_plugins(target)
  if #registered == 0 then
    say("Could not register the plugins as actions. Nothing was changed.", MB_OK)
    return
  end

  assign_shortcuts(registered)
  summary(registered, target, restart_needed)

  if restart_needed then
    offer_restart()
  end
end

main()
