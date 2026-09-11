-- MIDI notes to project markers
-- Creates project markers at MIDI note start positions in selected MIDI items.
-- The user can choose all MIDI items in the project or only selected MIDI items.
-- Looped MIDI items are followed across the visible item length.
--
-- The panel, and everything behind it, is steelblue_midi.lua -- the same
-- module the workspace draws in its "MIDI notes to markers" tab. This file is
-- the window around it: it opens the context, hands the panel a frame to draw
-- into, and lets the queued run out again once the frame is closed. The run
-- is a one-shot: after it the window closes, as it always did.

local SCRIPT_TITLE = "MIDI notes to project markers"

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

local MARKERS = load_module("steelblue_markers.lua")
local MA = load_module("steelblue_matools.lua")
if not MARKERS or not MA then
  return
end

local MIDI = load_module("steelblue_midi.lua")
if not MIDI then
  return
end

local panel = MIDI.create({ MARKERS = MARKERS, MA = MA, title = SCRIPT_TITLE })

-- ------------------------------------------------------------------- window

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

  local function loop()
    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 460)

    local close_window = false
    if visible then
      close_window = panel.frame(ctx, SB, {
        show_close = true,
      })

      SB.footer(ctx, panel.status())
    end

    SB.end_window(ctx, visible, font)

    -- outside the frame: the run, with its boxes. One run per window: once it
    -- has happened the window is done.
    local ran = panel.after_frame()

    if open and not close_window and not ran then
      reaper.defer(loop)
    else
      BOOT.destroy_context(ctx)
    end
  end

  reaper.defer(loop)
end

-- Test hook: lets the grouping, naming and lane logic run outside REAPER. The
-- panel owns it now; this file only passes it on, so tests/midi_lanes_test.lua
-- reaches exactly the same names it always did.
local TEST_HOOK = rawget(_G, "MIDI_TEST")
if TEST_HOOK then
  for key, value in pairs(panel.test_hook()) do
    TEST_HOOK[key] = value
  end
  return
end

-- ReaImGui is optional here: without it the window becomes the plain dialogs
-- of the fallback, which is a downgrade worth hearing about once.
BOOT.check_dependencies({
  title = SCRIPT_TITLE,
  imgui = "optional",
  imgui_cost = "the window is a plain dialog.",
})

if BOOT.has_imgui() then
  local SB = load_module("steelblue_ui.lua")
  if SB then
    run_gui(SB)
  end
else
  panel.run_fallback()
end
