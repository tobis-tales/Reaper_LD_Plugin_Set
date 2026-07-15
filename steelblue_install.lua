-- steelblue_install.lua
-- One-time installer for the steelblue REAPER LD Plugin Set.
--
-- Run once: Actions > Show Action List > New action... > Load ReaScript...
-- pick this file, then run it. It installs the bundled extensions if they are
-- missing, copies the plugins into REAPER's own Scripts folder, registers all
-- four as actions, and walks the user through putting a shortcut on each.
--
-- Deliberately built with plain REAPER dialogs, NOT with steelblue_ui.lua:
-- this script exists for the case where ReaImGui is missing, so it cannot
-- depend on ReaImGui to draw itself.

local TITLE = "steelblue Plugin Set — Installer"

local PLUGINS = {
  { file = "Live BPM Analyzer.lua",             name = "Live BPM Analyzer" },
  { file = "MIDI notes to project markers.lua", name = "MIDI notes to project markers" },
  { file = "Rename selected markers.lua",       name = "Rename selected markers" },
  { file = "CopyMarkers.lua",                   name = "Copy Markers" },
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
      ["Win64"] = "reaper_imgui-x64.dll",
      ["Win32"] = "reaper_imgui-x86.dll",
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
      ["Win64"] = "reaper_js_ReaScriptAPI64.dll",
      ["Win32"] = "reaper_js_ReaScriptAPI32.dll",
    },
    why = "Only 'Rename selected markers' needs it, to read the order of your selection in the Region/Marker Manager. Without it the cue numbering silently follows plain timeline order instead.",
  },
}

-- Which subfolder of extensions/ holds this machine's builds. GetOS() returns
-- "macOS-arm64"/"OSX64" or "Win64"/"Win32"; anything else (Linux) has no
-- bundled build and falls through to the pick-it-yourself path.
local PLATFORMS = {
  ["macOS-arm64"] = "macOS", ["OSX64"] = "macOS",
  ["Win64"] = "Windows",     ["Win32"] = "Windows",
}

local function is_windows()
  return (reaper.GetOS() or ""):sub(1, 3) == "Win"
end

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

-- Both extensions ARE shipped with the package (extensions/macOS/), unmodified
-- and under their own licences — see extensions/NOTICE.txt. Only macOS builds:
-- this ships as a disk image. If we have no build for the machine, the user can
-- still point at one they downloaded themselves.
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
  -- Quarantine is a macOS idea and /usr/bin/xattr is a macOS path: on Windows
  -- this would just stall for the timeout and achieve nothing.
  if not is_windows() then
    reaper.ExecProcess('/usr/bin/xattr -d com.apple.quarantine "' .. target .. '"', 5000)
  end
  return true
end

-- The bundled build for this machine, or nil if we do not ship one for it.
local function bundled_path(ext)
  local os_name = reaper.GetOS()
  local file = ext.files[os_name]
  local platform = PLATFORMS[os_name]
  if not file or not platform then
    return nil
  end

  local source = folder .. "extensions" .. SEP .. platform .. SEP .. file
  if not reaper.file_exists(source) then
    return nil
  end

  return source, file
end

-- The architecture a Windows DLL was built for, read out of the PE header.
--
-- The macOS equivalent shells out to `lipo`; Windows ships no such tool, so we
-- read the header ourselves. It is a fixed, ancient layout: "MZ" up front, a
-- little-endian pointer at 0x3C to the "PE\0\0" signature, and the machine word
-- right behind it. Pure Lua, which means the test harness can check it on a real
-- DLL without a Windows machine anywhere in sight.
--
-- Returns "x64", "x86", "arm64", or nil when the file is not a PE we recognise —
-- nil means "do not judge", never "wrong".
local PE_MACHINES = { [0x8664] = "x64", [0x014c] = "x86", [0xAA64] = "arm64" }

local function pe_arch(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end

  local head = f:read(0x40)
  if not head or #head < 0x40 or head:sub(1, 2) ~= "MZ" then
    f:close()
    return nil
  end

  local b1, b2, b3, b4 = head:byte(0x3D, 0x40)
  local pe_offset = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216

  if not f:seek("set", pe_offset) then
    f:close()
    return nil
  end
  local sig = f:read(6)
  f:close()

  if not sig or #sig < 6 or sig:sub(1, 4) ~= "PE\0\0" then
    return nil
  end

  local m1, m2 = sig:byte(5, 6)
  return PE_MACHINES[m1 + m2 * 256]
end

-- Same question on macOS, answered by lipo. Returns the arch list as a string,
-- or nil if lipo told us nothing useful.
local function macho_archs(path)
  local out = reaper.ExecProcess('/usr/bin/lipo -archs "' .. path .. '"', 5000)
  if not out or out == "" then
    return nil
  end
  local archs = (out:match("\n(.*)$") or ""):gsub("%s+$", "")
  return archs ~= "" and archs or nil
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
  -- wondering why REAPER quietly ignores a perfectly good file. Both branches
  -- only object when they positively identified the wrong arch: an unreadable
  -- header means we say nothing and let the copy proceed.
  local wrong, want
  if is_windows() then
    want = reaper.GetOS() == "Win64" and "x64" or "x86"
    local arch = pe_arch(path)
    wrong = (arch and arch ~= want) and arch or nil
  else
    want = reaper.GetOS() == "macOS-arm64" and "arm64" or "x86_64"
    local archs = macho_archs(path)
    wrong = (archs and not archs:find(want)) and archs or nil
  end

  if wrong then
    say(
      "That file is built for '" .. wrong .. "', but this machine needs '" .. want .. "'.\n\n" ..
      "REAPER would ignore it without a word. Nothing was copied.",
      MB_OK
    )
    return false
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
    "I will open that dialog once per plugin; press whatever keys you want, then confirm.\n\n" ..
    "Yes = go through them now\nNo = skip (you can do it any time in the Action List)",
    MB_YESNO
  )
  if wanted ~= ID_YES then
    return
  end

  for _, entry in ipairs(registered) do
    if not shortcut_of(entry) then
      say(
        entry.plugin.name .. "\n\n" ..
        "The shortcut dialog opens next — press the keys you want, then click OK in it.",
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
  -- only at startup, so APIExists still says no. Do not report that as a failure
  -- — and do not explain the restart here either, the quit dialog does that next.
  if restart_needed then
    lines[#lines + 1] = "An extension was installed as well — see the next window."
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

-- ---------------------------------------------------------------- quit

-- It offers to QUIT, not to restart, and that wording is the whole point.
--
-- REAPER has no restart action, only "File: Quit REAPER" (Main 40004 — the same
-- number is something else entirely in other sections, hence Main_OnCommand). A
-- restart was built and tried on 2026-07-15: REAPER quit, and nothing brought it
-- back. The helper script ran fine to its last line and survives an empty PATH,
-- so the relaunch seems to collide with REAPER's own shutdown.
--
-- Quitting, on the other hand, works every time. So offer that: a button that
-- promises a restart and only delivers half of it looks broken, while one that
-- says "quit" and quits is simply doing its job.
local function offer_quit()
  local want = say(
    "Quit REAPER now?\n\n" ..
    "An extension was just installed. REAPER only loads those when it starts, so the " ..
    "plugins will work the moment you open REAPER again — but not before.\n\n" ..
    "Yes = quit now\n" ..
    "No = I will close it myself later\n\n" ..
    "If you have unsaved work, REAPER will ask about it as usual.",
    MB_YESNO
  )
  if want ~= ID_YES then
    return
  end

  reaper.Main_OnCommand(40004, 0)   -- File: Quit REAPER
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
    offer_quit()
  end
end

main()
