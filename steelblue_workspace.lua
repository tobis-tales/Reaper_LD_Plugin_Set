-- steelblue_workspace.lua
-- One window for the whole LD plugin set, living in REAPER's bottom docker
-- next to the Mixer: a brand band with the live BPM read-out and what is
-- selected in the Region/Marker Manager, a row of tabs, and a status line.
--
-- Each tab draws the same panel module its own script draws --
-- steelblue_rename.lua, steelblue_midi.lua, steelblue_copy.lua -- laid out wide
-- instead of stacked. The BPM analyzer is not a tab: steelblue_bpm.lua draws
-- its compact block in the header band and everything else into the ">>>"
-- popup, and it keeps analyzing whichever tab is open. The four single-script
-- plugins keep working exactly as they do today; nothing here replaces them.

local SCRIPT_TITLE = "steelblue LD Tools"

-- v2o (2026-09-16): the startup block now runs this action on every REAPER
-- start, even while the workspace is already open (Tobi's decision, TT 91/94
-- -- no guard any more, see steelblue_install.lua). set_action_options(1)
-- tells REAPER to terminate an already-running instance of THIS script
-- instead of asking the user or refusing to start a second one; 1 is
-- "terminate", not a count. Must run before the first reaper.defer -- once
-- deferred, this script IS the running instance the setting is about.
if reaper.set_action_options then
  reaper.set_action_options(1)
end

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

local BPM = load_module("steelblue_bpm.lua")
if not BPM then
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

-- Not a tab: this one lives in the header band and runs on every frame.
local panel_bpm = BPM.create({
  title = "Live BPM Analyzer",
})

-- The analyzer's test hook, the one the five BPM suites read. "Live BPM
-- Analyzer.lua" publishes it and then returns -- the suites want the DSP, not a
-- window. The workspace publishes it and keeps going, so tests/bpm_hosts_test
-- can watch the panel that is actually on screen.
local BPM_HOOK = rawget(_G, "BPM_ANALYZER_TEST")
if BPM_HOOK then
  for key, value in pairs(panel_bpm.test_hook()) do
    BPM_HOOK[key] = value
  end
end

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

-- v2i/v2g wrote "1" here while the window was open and "0" when the user
-- closed it, so the __startup.eel block could ask "was it open at quit?"
-- before reopening the workspace. Tobi decided (TT 91/94, 2026-09-16) that the
-- workspace should come back on every REAPER start regardless -- the startup
-- block runs the action unconditionally now, and nothing reads this entry any
-- more. Same situation as EXT_STALE_UNDOCKED above: written with persist, so
-- it would sit in reaper-extstate.ini forever unless load_state cleans it up.
local EXT_AUTOSTART = "autostart"

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

  -- v2o: the startup block no longer reads this either -- the workspace opens
  -- every start now, not just when it was open at quit. Same cleanup as above,
  -- so a flag from an older install does not sit in reaper-extstate.ini forever.
  if ext_get(EXT_AUTOSTART) ~= "" then
    ext_delete(EXT_AUTOSTART, true)
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

  -- The ">>>" popup: open or closed, and where it hangs. `request` is set on
  -- the frame the button was pressed and OpenPopup is called once for it --
  -- calling OpenPopup on every frame would hold the popup open and take the
  -- click-outside close away, which is how a popup is meant to close.
  local popup_open = false
  local popup_request = false
  local popup_anchor_x, popup_anchor_y = nil, nil

  -- How far below the block's top edge the popup hangs: one row plus a gap.
  local POPUP_DROP = 28
  local POPUP_ID = "steelblue_bpm_more"

  -- The analyzer's compact block. steelblue_bpm.lua draws it; the only thing
  -- left here is the popup it cannot own, because a popup is a window and the
  -- panel modules do not open windows.
  local function header_left(ctx_)
    local x, y = reaper.ImGui_GetCursorScreenPos(ctx_)
    if type(x) == "number" and type(y) == "number" then
      popup_anchor_x, popup_anchor_y = x, y
    end

    if panel_bpm.frame(ctx_, SB, { layout = "compact" }) then
      if popup_open then
        popup_open = false
      else
        popup_request = true
      end
    end
  end

  -- Drawn right after the header band, so the popup belongs to the window and
  -- not to whatever the active tab submitted last.
  local function draw_bpm_popup(ctx_)
    if popup_request then
      popup_request = false
      popup_open = true

      -- Placed only on the frame it opens, and only then: a SetNextWindowPos
      -- that no Begin consumes stays armed and lands on the next window that
      -- opens -- which here would be the workspace itself, one frame later.
      if popup_anchor_x and reaper.ImGui_SetNextWindowPos then
        reaper.ImGui_SetNextWindowPos(ctx_, popup_anchor_x, popup_anchor_y + POPUP_DROP)
      end

      reaper.ImGui_OpenPopup(ctx_, POPUP_ID)
    end

    if not popup_open then
      return
    end

    if reaper.ImGui_BeginPopup(ctx_, POPUP_ID) then
      if panel_bpm.popup(ctx_, SB) then
        popup_open = false
        reaper.ImGui_CloseCurrentPopup(ctx_)
      end

      reaper.ImGui_EndPopup(ctx_)
    else
      -- a click outside: ImGui closed it, and the flag has to follow
      popup_open = false
    end
  end

  -- The rename tab's "Legend" popup, built the same way and drawn in the same
  -- place as the one above.
  --
  -- The panel used to open this itself, and in a REAPER docker the popup landed
  -- at the top of the screen instead of under its button (Tobi, 2026-09-16)
  -- while the ">>>" popup in the very same docker sat right. So the popup moves
  -- to where the working one is: opened by the host, submitted right after the
  -- header band, before the tab bar -- not from inside a tab's body.
  --
  -- The click therefore opens the popup one frame later: the tab is drawn AFTER
  -- this, so the request the button leaves behind is collected on the next pass.
  local legend_open = false
  local LEGEND_POPUP_ID = "steelblue_rename_legend"

  local function draw_legend_popup(ctx_)
    local request = panel_rename.take_legend_request()

    if request then
      legend_open = true

      -- Placed only on the frame it opens, and only then -- see draw_bpm_popup.
      -- The panel hands over the popup's corner, already dropped below the
      -- button, so the drop lives in one place and not in two.
      if request.x and reaper.ImGui_SetNextWindowPos then
        reaper.ImGui_SetNextWindowPos(ctx_, request.x, request.y)
      end

      reaper.ImGui_OpenPopup(ctx_, LEGEND_POPUP_ID)
    end

    if not legend_open then
      return
    end

    if reaper.ImGui_BeginPopup(ctx_, LEGEND_POPUP_ID) then
      if panel_rename.legend(ctx_, SB) then
        legend_open = false
        reaper.ImGui_CloseCurrentPopup(ctx_)
      end

      reaper.ImGui_EndPopup(ctx_)
    else
      -- a click outside: ImGui closed it, and the flag has to follow
      legend_open = false
    end
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

  local function loop()
    -- Before the window, on every frame, whatever tab is open: the analyzer is
    -- a live read-out, and it must not stop because someone is renaming markers.
    panel_bpm.tick()

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

      draw_bpm_popup(ctx)
      draw_legend_popup(ctx)

      set_active_tab(SB.tab_bar(ctx, TABS, state.active_tab))

      -- Every panel gets the one selection the workspace already read, and
      -- none of them draws its own "N markers selected" block: the header band
      -- says that. No Close/Cancel button either -- it would close the whole
      -- workspace, and the tab is not a window.
      local tab = tab_by_id(state.active_tab) or TABS[1]
      PANELS[tab.id].frame(ctx, SB, {
        wide = true,
        show_selection = false,
        entries = entries,
        reason = reason,
        source = source,
        -- Only the rename panel knows this one; the others ignore it. Popups
        -- are windows, and in here a window belongs to the host -- see
        -- draw_legend_popup above.
        legend_by_host = true,
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

    panel_bpm.after_frame()

    first_frame = false

    if open then
      reaper.defer(loop)
    else
      -- the audio accessor is a REAPER resource, not a Lua one
      panel_bpm.release()
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
