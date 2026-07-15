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

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""
local SEP = package.config:sub(1, 1)

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

-- A file fetched with a browser carries com.apple.quarantine, and REAPER will
-- refuse to load a quarantined extension. Copying via the shell lets us strip
-- it in the same breath.
local function install_extension(what)
  local ok = say(
    what .. " is not installed.\n\n" ..
    "If you have already downloaded it, I can put it in the right folder for you.\n\n" ..
    "OK = pick the downloaded file\nCancel = skip",
    MB_OKCANCEL
  )
  if ok ~= ID_OK then
    return false
  end

  local picked, path = reaper.GetUserFileNameForRead("", "Select the downloaded " .. what .. " file", "")
  if not picked then
    return false
  end

  local target = user_plugins_dir() .. file_name_of(path)
  reaper.RecursiveCreateDirectory(user_plugins_dir(), 0)

  -- verify the architecture before copying, so nobody spends an evening
  -- wondering why REAPER silently ignores a perfectly good file
  local arch = reaper.ExecProcess('/usr/bin/lipo -archs "' .. path .. '"', 5000)
  if arch and arch ~= "" then
    local archs = arch:match("\n(.*)$") or ""
    archs = archs:gsub("%s+$", "")
    if archs ~= "" and not archs:find("arm64") and not archs:find("x86_64") then
      say("That file does not look like a REAPER extension for this machine.\n\nlipo reports: " .. archs, MB_OK)
      return false
    end
  end

  local copied = reaper.ExecProcess('/bin/cp "' .. path .. '" "' .. target .. '"', 10000)
  if not copied then
    say("Could not copy the file to:\n" .. target, MB_OK)
    return false
  end

  reaper.ExecProcess('/usr/bin/xattr -d com.apple.quarantine "' .. target .. '"', 5000)

  say(
    file_name_of(path) .. " was copied to:\n" .. user_plugins_dir() .. "\n\n" ..
    "REAPER only loads extensions at startup — you have to restart REAPER before it takes effect.",
    MB_OK
  )
  return true
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

local function summary(registered, target)
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

  if not has_reaimgui() then
    lines[#lines + 1] = "! ReaImGui is still missing — restart REAPER if you just installed it."
  end
  if not has_js_api() then
    lines[#lines + 1] = "! JS_ReaScriptAPI is still missing — Rename selected markers will number cues in the wrong order without it."
  end
  if has_reaimgui() and has_js_api() then
    lines[#lines + 1] = "Both required extensions are present. You are ready to go."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "How-to guides: the Tutorials folder next to this script."
  lines[#lines + 1] = "Something to practise on: the Demo Project folder."

  say(table.concat(lines, "\n"), MB_OK)
end

-- ---------------------------------------------------------------- main

local function main()
  local missing = missing_files()
  if #missing > 0 then
    say(
      "These files are missing next to the installer:\n\n   " ..
      table.concat(missing, "\n   ") ..
      "\n\nCopy the whole package folder, not individual files, and run the installer from inside it.",
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

  if not has_reaimgui() then
    say(
      "ReaImGui is required by all four plugins and is not installed.\n\n" ..
      "It does not ship with REAPER. The easiest route is ReaPack (reapack.com), " ..
      "or download reaper_imgui for your system and let me place it.",
      MB_OK
    )
    install_extension("ReaImGui")
  end

  if not has_js_api() then
    say(
      "JS_ReaScriptAPI is not installed.\n\n" ..
      "Only 'Rename selected markers' needs it — to read the order of your selection in the " ..
      "Region/Marker Manager. Without it, cue numbering silently follows plain timeline order instead.",
      MB_OK
    )
    install_extension("JS_ReaScriptAPI")
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
  summary(registered, target)
end

main()
