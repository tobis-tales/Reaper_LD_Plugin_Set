-- steelblue_boot.lua
-- The start-up code every plugin in the package had its own copy of.
--
-- Usage from a script in the same folder:
--   local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""
--   local boot_chunk = loadfile(folder .. "steelblue_boot.lua")
--   if not boot_chunk then ... end
--   local BOOT = boot_chunk()
--
-- Loading a module, asking whether ReaImGui is there, and tearing an ImGui
-- context down again were copied word for word into all four plugins. They are
-- here once now. The plugins keep the loadfile bootstrap above inline, because
-- something has to load the loader.
--
-- check_dependencies is the new part: the plugins currently degrade in silence
-- when an extension is missing, and Rename renumbers cues wrongly without
-- JS_ReaScriptAPI without saying so. It is deliberately not wired into any
-- plugin yet -- that happens per plugin, with that plugin's own test.

local M = {}

M.VERSION = "1.0"

-- Copied from steelblue_markers.js_available on purpose. This module cannot ask
-- that one: it is what loads the modules. Keep the two lists in step.
local JS_FUNCTIONS = {
  "JS_Localize",
  "JS_Window_ArrayFind",
  "JS_Window_HandleFromAddress",
  "JS_Window_FindChildByID",
  "JS_ListView_ListAllSelItems",
  "JS_ListView_GetItemText",
  "new_array",
}

-- Loads a module file next to the script. A missing file gives a sentence
-- instead of a Lua traceback -- the package ships as a folder, and the one
-- thing users do wrong is copy a single .lua out of it.
function M.load_module(folder, name, title)
  local chunk = loadfile((folder or "") .. name)
  if not chunk then
    reaper.ShowMessageBox(
      name .. " is missing next to this script.\n\n" ..
      "Please copy the whole steelblue package into the same folder.",
      title,
      0
    )
    return nil
  end

  return chunk()
end

function M.has_imgui()
  return reaper.APIExists and reaper.APIExists("ImGui_CreateContext")
end

local function has_js()
  for _, name in ipairs(JS_FUNCTIONS) do
    if not reaper[name] then
      return false
    end
  end

  return true
end

function M.create_context(title)
  return reaper.ImGui_CreateContext(title)
end

-- Guarded because not every ReaImGui build exposes ImGui_DestroyContext.
function M.destroy_context(ctx)
  if ctx and reaper.APIExists and reaper.APIExists("ImGui_DestroyContext") then
    reaper.ImGui_DestroyContext(ctx)
  end
end

-- Tells the user once, at start-up, which extension is missing and what it
-- costs them -- instead of the plugin quietly doing something else.
--
--   spec.title       window title, also used in the first line
--   spec.imgui       "required" | "optional" | nil (do not check)
--   spec.js          same, for JS_ReaScriptAPI
--   spec.imgui_cost  what an optional ReaImGui costs, e.g. "the window is a
--                    plain dialog." -- completes "without it "
--   spec.js_cost     same for JS_ReaScriptAPI
--
-- Returns ok, missing. ok is false only when something *required* is missing;
-- an optional part produces the same message box but lets the plugin run.
-- missing is a list of { name = ..., level = ... }.
function M.check_dependencies(spec)
  spec = spec or {}

  local missing = {}
  local lines = {}

  if spec.imgui and not M.has_imgui() then
    missing[#missing + 1] = { name = "ReaImGui", level = spec.imgui }
    if spec.imgui == "required" then
      lines[#lines + 1] = "ReaImGui (required): without it this plugin cannot open its window.\n"
    else
      lines[#lines + 1] = "ReaImGui (optional): without it " .. tostring(spec.imgui_cost) .. "\n"
    end
  end

  if spec.js and not has_js() then
    missing[#missing + 1] = { name = "JS_ReaScriptAPI", level = spec.js }
    if spec.js == "required" then
      lines[#lines + 1] = "JS_ReaScriptAPI (required): without it this plugin cannot run.\n"
    else
      lines[#lines + 1] = "JS_ReaScriptAPI (optional): without it " .. tostring(spec.js_cost) .. "\n"
    end
  end

  if #missing == 0 then
    return true, missing
  end

  -- one box, however much is missing: two dialogs in a row read as a crash
  reaper.ShowMessageBox(
    tostring(spec.title) .. " is missing a REAPER extension.\n\n" ..
    table.concat(lines) ..
    "\nRun steelblue_install.lua from the package to install what is missing, then restart REAPER.",
    spec.title,
    0
  )

  local ok = true
  for _, entry in ipairs(missing) do
    if entry.level == "required" then
      ok = false
    end
  end

  return ok, missing
end

return M
