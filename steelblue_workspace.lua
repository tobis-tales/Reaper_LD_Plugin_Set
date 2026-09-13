-- steelblue_workspace.lua
-- One window for the whole LD plugin set, living in REAPER's bottom docker
-- next to the Mixer: a brand band with the live BPM read-out and what is
-- selected in the Region/Marker Manager, a row of tabs, and a status line.
--
-- Each tab draws the same panel module its own script draws --
-- steelblue_rename.lua, steelblue_midi.lua, steelblue_copy.lua -- laid out wide
-- instead of stacked. The BPM analyzer follows in the next step. The four
-- single-script plugins keep working exactly as they do today; nothing here
-- replaces them.

local SCRIPT_TITLE = "steelblue LD Tools"

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

-- The only loader code left inline: something has to load the loader.
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

local MA = load_module("steelblue_matools.lua")
if not MA then
  return
end

local RENAME = load_module("steelblue_rename.lua")
if not RENAME then
  return
end

local MIDI = load_module("steelblue_midi.lua")
if not MIDI then
  return
end

local COPY = load_module("steelblue_copy.lua")
if not COPY then
  return
end

-- One panel each for the whole run, so a half-typed cue name or a pinned
-- target survives a trip to another tab. The plugin's own title, not the
-- workspace's: it is what the fallback dialogs and the message boxes say, and
-- they belong to the plugin.
local panel_rename = RENAME.create({
  MARKERS = MARKERS,
  MA = MA,
  title = "Rename selected markers",
})

local panel_midi = MIDI.create({
  MARKERS = MARKERS,
  MA = MA,
  title = "MIDI notes to project markers",
})

local panel_copy = COPY.create({
  MARKERS = MARKERS,
  title = "Copy Markers",
})

-- The panel behind each tab id, so the footer and after_frame can ask by id.
local PANELS = {
  rename = panel_rename,
  midi = panel_midi,
  copy = panel_copy,
}

-- ---------------------------------------------------------------- persistence

local EXT_SECTION = "steelblue_workspace"
local EXT_ACTIVE_TAB = "active_tab"
local EXT_OPEN_TAB = "open_tab"

-- The 2.0 previews let the user pull the window out and remembered that here.
-- The window is always docked now, so the entry means nothing -- but it is
-- written with persist, so it would sit in reaper-extstate.ini forever.
local EXT_STALE_UNDOCKED = "undocked"

local function ext_get(key)
  if not reaper.GetExtState then
    return ""
  end

  local value = reaper.GetExtState(EXT_SECTION, key)
  if type(value) ~= "string" then
    return ""
  end

  return value
end

local function ext_set(key, value, persist)
  if reaper.SetExtState then
    reaper.SetExtState(EXT_SECTION, key, value, persist and true or false)
  end
end

local function ext_delete(key, persist)
  if reaper.DeleteExtState then
    reaper.DeleteExtState(EXT_SECTION, key, persist and true or false)
  end
end

-- ---------------------------------------------------------------- tabs

-- No shortcut hints on the tabs. The installer only SUGGESTS keys -- REAPER
-- has no API to set one, and none to read back what a user bound to some other
-- script either (GetActionShortcutDesc needs a command ID, and the workspace
-- does not know the single scripts' IDs). A printed key that is not the one
-- the user actually has is worse than no key at all.
local TABS = {
  { id = "rename", label = "Rename selected markers",
    plugin = "Rename selected markers" },
  { id = "midi",   label = "MIDI notes to markers",
    plugin = "MIDI notes to project markers" },
  { id = "copy",   label = "Copy Markers",
    plugin = "Copy Markers" },
}

local function tab_by_id(id)
  for _, tab in ipairs(TABS) do
    if tab.id == id then
      return tab
    end
  end

  return nil
end

local state = {
  active_tab = TABS[1].id,
}

local function set_active_tab(id)
  if not tab_by_id(id) or id == state.active_tab then
    return false
  end

  state.active_tab = id
  ext_set(EXT_ACTIVE_TAB, id, true)
  return true
end

local function load_state()
  local tab = ext_get(EXT_ACTIVE_TAB)
  state.active_tab = tab_by_id(tab) and tab or TABS[1].id

  -- Nothing reads this any more; clear it so an old preview's choice cannot
  -- come back if the flag is ever given a meaning again.
  if ext_get(EXT_STALE_UNDOCKED) ~= "" then
    ext_delete(EXT_STALE_UNDOCKED, true)
  end
end

-- Another script can ask for a tab by writing its id here; the workspace takes
-- it over once and clears it, so the same request cannot re-open the tab on
-- every frame afterwards. This is how the four actions will open "their" tab.
local function read_open_tab_request()
  local value = ext_get(EXT_OPEN_TAB)
  if value == "" then
    return nil
  end

  ext_delete(EXT_OPEN_TAB)

  if not tab_by_id(value) then
    return nil
  end

  return value
end

-- ---------------------------------------------------------------- docking

-- REAPER's bottom docker, the one that holds the Mixer. Verified on macOS
-- 7.79 with tests/probe_dock.lua; the Windows number is unverified.
local DOCK_ID = -1

-- Should this frame ask REAPER for a docker slot?
--
--   first_frame  true only on the very first frame of this script run
--
-- The docker placement is not persistent (probe 2026-09-11: a restarted REAPER
-- brings the window back floating even though Cond_FirstUseEver was set on
-- every start), so every run asks again on its first frame.
--
-- Only the first frame, never again: Cond_Always on every frame would pin the
-- window down and make it undraggable. Tobi's decision 2026-09-11 -- the
-- workspace lives in the docker, pulling it out is not a feature.
local function dock_decision(first_frame)
  return first_frame and true or false
end

-- ---------------------------------------------------------------- selection

local function selection_text(count, source)
  if count == 0 then
    return "Region/Marker Manager: nothing selected"
  end

  local order = source == "manager" and "click order" or "arrange view"
  return "Region/Marker Manager: " .. tostring(count) .. " selected \u{00B7} " .. order
end

-- ---------------------------------------------------------------- window

local function enable_docking(ctx)
  if not (reaper.ImGui_SetConfigVar and reaper.ImGui_ConfigVar_Flags
    and reaper.ImGui_ConfigFlags_DockingEnable) then
    return
  end

  local flags = reaper.ImGui_GetConfigVar and reaper.ImGui_GetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags())
  if type(flags) ~= "number" then
    flags = 0
  end

  reaper.ImGui_SetConfigVar(ctx, reaper.ImGui_ConfigVar_Flags(),
    flags | reaper.ImGui_ConfigFlags_DockingEnable())
end

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)
  enable_docking(ctx)

  local first_frame = true

  -- Reading the Region/Marker Manager means asking JS_ReaScriptAPI to
  -- enumerate windows and walk a list view -- far too heavy for 60 fps. Same
  -- 150 ms poll the other plugins use. The one answer feeds the header band
  -- AND the open panel: the panels take it through opts.entries and do not
  -- poll a second time.
  local POLL_INTERVAL = 0.15
  local last_poll = -1
  local cached_entries, cached_reason, cached_source = {}, nil, nil

  local function selection()
    local now = reaper.time_precise()
    if now - last_poll >= POLL_INTERVAL then
      last_poll = now
      cached_entries, cached_reason, cached_source = MARKERS.selected()
    end

    return cached_entries, cached_reason, cached_source
  end

  -- The BPM block is a placeholder in this step: the numbers and all three
  -- controls arrive when the analyzer moves in. Disabled, so nobody clicks a
  -- button that does nothing.
  local function header_left(ctx_)
    reaper.ImGui_AlignTextToFramePadding(ctx_)
    reaper.ImGui_TextColored(ctx_, SB.color.text_muted, "LIVE BPM")
    reaper.ImGui_SameLine(ctx_)
    reaper.ImGui_TextColored(ctx_, SB.color.text, "--.--")
    reaper.ImGui_SameLine(ctx_)
    reaper.ImGui_TextColored(ctx_, SB.color.text_muted, "BPM")
    reaper.ImGui_SameLine(ctx_)

    reaper.ImGui_BeginDisabled(ctx_, true)
    -- "##" hides the label: the switch has no text of its own in the design.
    reaper.ImGui_Checkbox(ctx_, "##live_bpm", false)
    reaper.ImGui_SameLine(ctx_)
    SB.button(ctx_, "Precision analyze", 0, 0)
    reaper.ImGui_SameLine(ctx_)
    SB.button(ctx_, "\u{203A}\u{203A}\u{203A}", 0, 0)
    reaper.ImGui_EndDisabled(ctx_)
  end

  -- Right-aligning is allowed here and nowhere else in this package: the
  -- docker decides the width, so placing an item by "available minus my own
  -- width" cannot feed back into the window size the way it does in an
  -- auto-resizing window.
  local function header_right(ctx_, text)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx_)
    local cursor_x = reaper.ImGui_GetCursorPosX(ctx_)

    local text_w = 240
    if reaper.ImGui_CalcTextSize then
      local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx_, text)
      if ok and type(w) == "number" then
        text_w = w
      end
    end

    if type(avail) == "number" and type(cursor_x) == "number" then
      reaper.ImGui_SetCursorPosX(ctx_, cursor_x + math.max(0, avail - text_w))
    end

    reaper.ImGui_AlignTextToFramePadding(ctx_)
    reaper.ImGui_TextColored(ctx_, SB.color.text_dim, text)
  end

  -- What one footer row costs from the cursor it is called on: SB.footer
  -- reserves 2 + 26 px with an ItemSpacing.y of 7 between them, and the spacer
  -- pushing it down costs another 7. Getting this wrong by a few pixels is
  -- what a scrollbar is made of. The strip DRAWS 12 px further than it
  -- reserves, which is exactly the window's bottom padding.
  local FOOTER_HEIGHT = 2 + 7 + 26 + 7

  -- Below this the reference lines are dropped and only the fields stay. Tobi's
  -- docker goes from about 290 px to about 850; the fields alone fit at the
  -- bottom of that range, the legend needs the room a taller docker gives.
  local REFERENCE_MIN_HEIGHT = 450

  local function loop()
    local requested = read_open_tab_request()
    if requested then
      set_active_tab(requested)
    end

    local dock_now = dock_decision(first_frame)

    local entries, reason, source = selection()

    local visible, open, font = SB.begin_dock_window(ctx, SCRIPT_TITLE, {
      dock_now = dock_now,
      dock_id = DOCK_ID,
    })

    if visible then
      local info = selection_text(#entries, source)
      SB.header_bar(ctx, {
        left = header_left,
        right = function(c) header_right(c, info) end,
      })

      set_active_tab(SB.tab_bar(ctx, TABS, state.active_tab))

      -- Every panel gets the one selection the workspace already read, and
      -- none of them draws its own "N markers selected" block: the header band
      -- says that. No Close/Cancel button either -- it would close the whole
      -- workspace, and the tab is not a window.
      local tab = tab_by_id(state.active_tab) or TABS[1]
      local _, window_h = reaper.ImGui_GetWindowSize(ctx)
      PANELS[tab.id].frame(ctx, SB, {
        wide = true,
        show_selection = false,
        show_reference = type(window_h) == "number" and window_h >= REFERENCE_MIN_HEIGHT,
        entries = entries,
        reason = reason,
        source = source,
      })

      -- Push the status line to the bottom edge: the docker owns the height,
      -- so "after the content" is nowhere near the bottom here.
      local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
      if type(avail_h) == "number" and avail_h > FOOTER_HEIGHT then
        reaper.ImGui_Dummy(ctx, 1, avail_h - FOOTER_HEIGHT)
      end

      -- Every tab writes into the one status line at the bottom, so the panel
      -- that is open says what happened and the others stay quiet.
      SB.footer(ctx, PANELS[tab.id].status())
    end

    SB.end_window(ctx, visible, font)

    -- outside the frame: safe to touch the project. Every panel, not only the
    -- open one -- a click lands in the panel that was drawn this frame, and
    -- that is the one whose queue holds it.
    for _, panel in pairs(PANELS) do
      panel.after_frame()
    end

    first_frame = false

    if open then
      reaper.defer(loop)
    else
      BOOT.destroy_context(ctx)
    end
  end

  reaper.defer(loop)
end

-- ---------------------------------------------------------------- start

load_state()

local TEST_HOOK = rawget(_G, "WORKSPACE_TEST")
if TEST_HOOK then
  TEST_HOOK.state = state
  TEST_HOOK.TABS = TABS
  TEST_HOOK.DOCK_ID = DOCK_ID
  TEST_HOOK.load_state = load_state
  TEST_HOOK.set_active_tab = set_active_tab
  TEST_HOOK.read_open_tab_request = read_open_tab_request
  TEST_HOOK.dock_decision = dock_decision
  TEST_HOOK.selection_text = selection_text
  return
end

-- ReaImGui is not optional here: the workspace IS the window. The four single
-- scripts keep their plain-dialog fallbacks, so nobody loses a feature.
local ok = BOOT.check_dependencies({
  title = SCRIPT_TITLE,
  imgui = "required",
  js = "optional",
  js_cost = "the selection is read from the arrange view instead of the Region/Marker Manager.",
})

if not ok then
  return
end

local SB = load_module("steelblue_ui.lua")
if SB then
  run_gui(SB)
end
