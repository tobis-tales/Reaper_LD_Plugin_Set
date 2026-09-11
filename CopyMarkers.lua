-- CopyMarkers.lua
-- Copies the markers selected in REAPER's Region/Marker Manager to a new
-- absolute target position, preserving spacing, names, and colors.
--
-- The selection is read live: the window can stay open while markers are
-- (de)selected and the edit cursor is moved.
--
-- The panel, and everything behind it, is steelblue_copy.lua -- the same
-- module the workspace draws in its "Copy Markers" tab. This file is the
-- window around it: it opens the context, hands the panel a frame to draw
-- into, puts the panel's status line in the footer, and lets the queued work
-- out again once the frame is closed.

local SCRIPT_TITLE = "Copy Markers"

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
if not MARKERS then
  return
end

local COPY = load_module("steelblue_copy.lua")
if not COPY then
  return
end

local panel = COPY.create({ MARKERS = MARKERS, title = SCRIPT_TITLE })

-- ------------------------------------------------------------------- window

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

  local function loop()
    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 430)

    if visible then
      panel.frame(ctx, SB, {
        show_selection = true,
      })

      SB.footer(ctx, panel.status())
    end

    SB.end_window(ctx, visible, font)

    -- outside the frame: safe to touch the project
    panel.after_frame()

    if open then
      reaper.defer(loop)
    else
      BOOT.destroy_context(ctx)
    end
  end

  reaper.defer(loop)
end

-- Both extensions are optional here, so the answer is ignored -- the point is
-- that the user hears about it once instead of wondering why the window looks
-- different or the selection comes from the arrange view.
BOOT.check_dependencies({
  title = SCRIPT_TITLE,
  imgui = "optional",
  imgui_cost = "the window is a plain dialog.",
  js = "optional",
  js_cost = "the selection is read from the arrange view instead of the Region/Marker Manager.",
})

if BOOT.has_imgui() then
  local SB = load_module("steelblue_ui.lua")
  if SB then
    run_gui(SB)
  end
else
  panel.run_fallback()
end
