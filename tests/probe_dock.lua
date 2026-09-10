-- probe_dock.lua
-- Answers what cannot be answered outside REAPER: does an empty ReaImGui
-- window dock into REAPER's bottom docker, next to the Mixer, and does it
-- stay there? No plugin, no shared module is touched by this script.
--
-- HOW TO RUN
--   1. Actions > Show action list > "Load ReaScript..." > pick this file,
--      from the repo folder (so the run tracks the DOCK value below).
--   2. A window "steelblue dock probe" opens. Look at the bottom docker.
--   3. If it is not there, close the window, change DOCK below in a text
--      editor (-1, -2, -3, ...), save, run the script again.
--   4. Once it sits where you expect: click "Print to console", copy the
--      REAPER console text, hand it back.
--
-- Raw ImGui only -- no steelblue_ui, no shared module -- so the result does
-- not depend on our theme (AlwaysAutoResize is deliberately left off: it is
-- unclear whether it fights with docking, and a docked window should fill the
-- docker rather than shrink to its content).
--
-- FACTS (verified against the shipped ReaImGui 0.10 dylib, 2026-09-11):
--   ImGui_SetNextWindowDockID(ctx, dock_id, condInOptional) -- negative
--   dock_id = a REAPER docker (-1 ... -16); which negative number is the
--   bottom docker (the one holding the Mixer) is UNKNOWN -- that is what this
--   probe is for. ImGui_IsWindowDocked(ctx), ImGui_GetWindowDockID(ctx).
--   Docking must be turned on for the context via
--   ImGui_SetConfigVar(ctx, ImGui_ConfigVar_Flags(), ImGui_ConfigFlags_DockingEnable()).
--
-- ImGui_DestroyContext does not exist in this dylib (checked the same way as
-- AGENTS.md notes for the four plugins), so its use here is guarded.

-- Tobi: change this to try a different REAPER docker (-1 ... -16), then
-- re-run the script.
local DOCK = -1

local function say(key, value)
  reaper.ShowConsoleMsg(tostring(key) .. " = " .. tostring(value) .. "\n")
end

local ctx = reaper.ImGui_CreateContext("steelblue dock probe")

-- Turn docking on for this context once, at start -- SetNextWindowDockID has
-- no effect otherwise.
do
  local flags = reaper.ImGui_GetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags())
  reaper.ImGui_SetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags(),
    flags | reaper.ImGui_ConfigFlags_DockingEnable())
end

local TABS = { "Rename", "Copy", "MIDI", "BPM" }

local frame = 0
local pending_undock = false

local function loop()
  frame = frame + 1

  -- ImGui_Cond_FirstUseEver only takes effect the very first time this window
  -- is ever shown (no saved dock/size yet), which is what "the probe picks a
  -- default docker on first run, but a manual drag/undock afterwards sticks"
  -- needs. The "Undock" button below needs an immediate effect instead, so it
  -- asks for ImGui_Cond_Always() on the one frame after it is pressed --
  -- ASSUMPTION(probe): FirstUseEver alone would not move an already-placed
  -- window.
  if pending_undock then
    reaper.ImGui_SetNextWindowDockID(ctx, 0, reaper.ImGui_Cond_Always())
    pending_undock = false
  else
    reaper.ImGui_SetNextWindowDockID(ctx, DOCK, reaper.ImGui_Cond_FirstUseEver())
  end

  -- No AlwaysAutoResize on purpose -- see header comment.
  local visible, open = reaper.ImGui_Begin(ctx, "steelblue dock probe", true)

  if visible then
    local docked = reaper.ImGui_IsWindowDocked(ctx)
    local dock_id = reaper.ImGui_GetWindowDockID(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

    reaper.ImGui_Text(ctx, string.format(
      "docked=%s  dock_id=%s  size=%.0fx%.0f  avail=%.0fx%.0f  frame=%d",
      tostring(docked), tostring(dock_id), win_w, win_h, avail_w, avail_h, frame))

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_BeginTabBar(ctx, "probe_tabs") then
      for _, tab in ipairs(TABS) do
        if reaper.ImGui_BeginTabItem(ctx, tab) then
          reaper.ImGui_Text(ctx, tab .. " tab (dummy)")
          reaper.ImGui_EndTabItem(ctx)
        end
      end
      reaper.ImGui_EndTabBar(ctx)
    end

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_Button(ctx, "Print to console") then
      say("DOCK_SETTING", DOCK)
      say("IS_WINDOW_DOCKED", docked)
      say("GET_WINDOW_DOCK_ID", dock_id)
      say("WINDOW_SIZE", string.format("%.1f x %.1f", win_w, win_h))
      say("CONTENT_REGION_AVAIL", string.format("%.1f x %.1f", avail_w, avail_h))
      say("FRAME", frame)
      say("APP_VERSION", reaper.GetAppVersion())
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Undock") then
      pending_undock = true
    end

    -- End belongs only in the visible branch (AGENTS.md: a collapsed window
    -- submits nothing) -- there is no style stack here to balance every frame.
    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(loop)
  else
    if reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end

reaper.defer(loop)
