-- Live BPM Analyzer
-- Estimates BPM from the selected audio item while REAPER is playing.
-- Precision mode analyzes a long span of the song for sub-0.1 BPM accuracy.
--
-- The analyzer, and everything behind it, is steelblue_bpm.lua -- the same
-- module the workspace draws as the block in its header band. This file is the
-- window around it: it opens the context, drives the live path once per frame,
-- hands the panel a frame to draw into, puts the panel's status line in the
-- footer, lets the queued work out again once the frame is closed, and hands
-- the audio accessor back when the window goes away.

local SCRIPT_TITLE = "Live BPM Analyzer"

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

-- The only loader code left inline: something has to load the loader. The rest
-- was copied word for word into all four plugins and now lives in
-- steelblue_boot.lua.
local boot_chunk = loadfile(folder .. "steelblue_boot.lua")
if not boot_chunk then
  reaper.ShowMessageBox(
    "steelblue_boot.lua is missing next to this script.\n\n" ..
    "Please copy the whole steelblue package into the same folder.",
    SCRIPT_TITLE,
    0
  )
  return
end

local BOOT = boot_chunk()

local function load_module(name)
  return BOOT.load_module(folder, name, SCRIPT_TITLE)
end

local BPM = load_module("steelblue_bpm.lua")
if not BPM then
  return
end

local panel = BPM.create({ title = SCRIPT_TITLE })

-- Test hook: lets the DSP core run outside REAPER for accuracy verification.
-- It is published here, before check_dependencies, exactly as it always was --
-- the five BPM suites set the global and dofile THIS file, and they must not
-- meet a message box about a missing ReaImGui on the way.
local TEST_HOOK = rawget(_G, "BPM_ANALYZER_TEST")
if TEST_HOOK then
  for key, value in pairs(panel.test_hook()) do
    TEST_HOOK[key] = value
  end

  return
end

local ok = BOOT.check_dependencies({ title = SCRIPT_TITLE, imgui = "required" })
if not ok then
  return
end

local SB = load_module("steelblue_ui.lua")
if not SB then
  return
end

-- ------------------------------------------------------------------- window

local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

local function loop()
  -- Before the window, on every frame: one envelope update per 0.75 s,
  -- otherwise one slice of the tempo search.
  panel.tick()

  local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 420)

  if visible then
    panel.frame(ctx, SB, { layout = "window" })

    SB.footer(ctx, panel.status())
  end

  SB.end_window(ctx, visible, font)

  -- outside the frame: safe to touch the project
  panel.after_frame()

  if open then
    reaper.defer(loop)
  else
    panel.release()
    BOOT.destroy_context(ctx)
  end
end

reaper.defer(loop)
