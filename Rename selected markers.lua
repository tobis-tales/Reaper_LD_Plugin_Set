-- Rename selected markers
-- Renames markers selected in REAPER's Region/Marker Manager.
-- Regions are ignored.
--
-- The panel, and everything behind it, is steelblue_rename.lua -- the same
-- module the workspace draws in its "Rename selected markers" tab. This file is
-- the window around it: it opens the context, hands the panel a frame to draw
-- into, puts the panel's status line in the footer, and lets the queued work
-- out again once the frame is closed.

local SCRIPT_TITLE = "Rename selected markers"

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

-- Reading the selection and building MA-Tools syntax are both jobs several
-- plugins share; this script used to carry its own copy of each.
local MARKERS = load_module("steelblue_markers.lua")
if not MARKERS then
  return
end

local MA = load_module("steelblue_matools.lua")
if not MA then
  return
end

local RENAME = load_module("steelblue_rename.lua")
if not RENAME then
  return
end

local panel = RENAME.create({ MARKERS = MARKERS, MA = MA, title = SCRIPT_TITLE })

-- ------------------------------------------------------------------- window

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

  local function loop()
    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 620)

    local close_window = false
    if visible then
      close_window = panel.frame(ctx, SB, {
        show_selection = true,
        show_reference = true,
        show_close = true,
      })

      SB.footer(ctx, panel.status())
    end

    SB.end_window(ctx, visible, font)

    -- outside the frame: safe to touch the project
    panel.after_frame()

    if open and not close_window then
      reaper.defer(loop)
    else
      BOOT.destroy_context(ctx)
    end
  end

  reaper.defer(loop)
end

-- Test hook: lets the naming and colour logic run outside REAPER. The panel
-- owns it now; this file only passes it on, so tests/rename_test.lua reaches
-- exactly the same thirteen functions it always did.
local TEST_HOOK = rawget(_G, "RENAME_TEST")
if TEST_HOOK then
  for key, value in pairs(panel.test_hook()) do
    TEST_HOOK[key] = value
  end
  return
end

-- Both extensions are optional here, so the answer is ignored -- the point is
-- that the user hears about it once instead of wondering why the cue numbers
-- come out in the wrong order.
BOOT.check_dependencies({
  title = SCRIPT_TITLE,
  imgui = "optional",
  imgui_cost = "the window is a plain dialog.",
  js = "optional",
  js_cost = "cues are numbered by timeline position, not by the order you selected the markers in.",
})

if BOOT.has_imgui() then
  local SB = load_module("steelblue_ui.lua")
  if SB then
    run_gui(SB)
  end
else
  panel.run_fallback()
end
