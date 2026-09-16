-- steelblue_copy.lua
-- "Copy Markers" without a window around it.
--
-- Usage:
--   local COPY = BOOT.load_module(folder, "steelblue_copy.lua", TITLE)
--   local panel = COPY.create({ MARKERS = MARKERS, title = TITLE })
--   ...
--   local visible, open, font = SB.begin_window(ctx, TITLE, 430)
--   if visible then
--     panel.frame(ctx, SB, { show_selection = true })
--     SB.footer(ctx, panel.status())
--   end
--   SB.end_window(ctx, visible, font)
--   panel.after_frame()
--
-- Two hosts draw this same panel: the single script "CopyMarkers.lua" in its
-- own auto-sized window, and steelblue_workspace.lua in the "Copy Markers"
-- tab. The logic must not be copied into a second place, because a copy is a
-- thing that rots (AGENTS.md, 2026-07-15).
--
-- What belongs here: the target fields and their follow rule, the marker list
-- with its tick boxes, the copy, the selection poll, the pending queue, the
-- plain-dialog fallback.
-- What does NOT belong here: the window and the footer. The panel hands its
-- status line back with status() so the host can put it where its own layout
-- wants it.
--
-- Why the tick list exists (Tobi, 2026-09-15): the Region/Marker Manager drops
-- its selection the moment another marker is clicked, so "select, then look at
-- something else, then copy" was impossible. The ticks are the panel's own
-- memory of what to copy; the manager selection only seeds them.

local M = {}

M.VERSION = "1.2"

-- Width of the position column in the marker list, so the names line up under
-- each other instead of after the longest timestamp.
local POSITION_WIDTH = 80

-- How many rows the single window's list shows before it scrolls. That window
-- auto-sizes to its content, so the list must NOT: a child of a FIXED height is
-- the one thing that keeps the window from growing with the project.
local LIST_ROWS = 8

-- Narrow layout. Under the width of the three copy buttons in a row
-- (3 x 200 + 2 x ItemSpacing.x = 616), so the list never gets to decide how
-- wide the auto-sizing window is.
local LIST_WIDTH = 600

-- Wide layout (Tobi, 2026-09-16: "Das Feld mit den Markern muss nicht so breit
-- sein, dafuer kann man links etwas auflockern"). The list is a FIXED 520 px
-- pinned to the right edge of the tab; everything left of it belongs to the
-- controls. 520 carries the tick box, the 80 px position column and a long
-- marker name without the names running into the lane labels.
local LIST_WIDTH_WIDE = 520

-- Between the controls column and the list.
local COLUMN_GAP = 24

-- Below this the list gives width back rather than pushing the buttons (240 px
-- wide) off the left edge. Only reachable in a docker far narrower than
-- anything Tobi uses; without it a 600 px docker would draw the list on top of
-- the controls.
local MIN_LEFT_WIDTH = 280

-- Wide layout: the three copy buttons are stacked, so they can afford to be
-- wider than in the single window, where all three sit in one row.
local BUTTON_WIDTH_WIDE = 240
local BUTTON_WIDTH_NARROW = 200

-- What steelblue_workspace.lua reserves under the panel for its status strip
-- (steelblue_workspace.lua: FOOTER_HEIGHT = 2 + 7 + 26 + 7), plus the one
-- ItemSpacing.y between the columns and that strip. The columns leave exactly
-- this much, so the docked window's content ends where the window does and no
-- scrollbar appears on it -- only inside the children.
local HOST_FOOTER_HEIGHT = 2 + 7 + 26 + 7
local ITEM_SPACING_Y = 7          -- StyleVar_ItemSpacing.y in steelblue_ui.lua
local FRAME_HEIGHT_FALLBACK = 23  -- body font 13 + 2 x FramePadding.y 5

-- BeginChild is not Begin. Dear ImGui wants EndChild after EVERY BeginChild,
-- whatever it returned: the installed dylib documents BeginChild as "Returns
-- false to indicate the window is collapsed or fully clipped" (reaper_imgui
-- 0.10, APIdef_ImGui_BeginChild) and asserts "Missing EndChild()" when the
-- call is skipped. So the pairing sits OUTSIDE the branch, and
-- tests/plugin_render_test.lua counts the pair the way it counts Begin/End.
local function child(ctx, SB, id, width, height, background, draw)
  local tinted = false
  if background and reaper.ImGui_Col_ChildBg then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), background)
    tinted = true
  end

  -- No flags, and that is the considered answer to "the list must not grow a
  -- horizontal scrollbar" (checked against the installed dylib, ReaImGui 0.10 /
  -- Dear ImGui 1.92):
  --   WindowFlags_HorizontalScrollbar  "Allow horizontal scrollbar to appear
  --                                     (off by default)" -- so not passing it
  --                                     IS the switch. Content wider than the
  --                                     child is clipped at its edge instead.
  --   WindowFlags_NoScrollbar          "Disable scrollbars (window can still
  --                                     scroll with mouse or programmatically)"
  --                                     -- that would take the VERTICAL bar
  --                                     away too, and the list needs it.
  --   ChildFlags_*                     nothing there is about scrolling:
  --                                     Borders, FrameStyle, AlwaysUseWindow-
  --                                     Padding, NavFlattened, ResizeX/Y,
  --                                     AutoResizeX/Y, AlwaysAutoResize.
  local child_flags = reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0
  local window_flags = reaper.ImGui_WindowFlags_None and reaper.ImGui_WindowFlags_None() or 0

  if reaper.ImGui_BeginChild(ctx, id, width, height, child_flags, window_flags) then
    draw()
  end
  reaper.ImGui_EndChild(ctx)

  if tinted then
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
end

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

-- A tick belongs to a MARKER, not to a row number: the GUID survives renaming
-- and moving, so the ticks do too. Below REAPER 7.72 there is no GUID to have,
-- and the displayed ID is the best key available.
local function entry_key(entry)
  if entry.guid and entry.guid ~= "" then
    return entry.guid
  end
  return "id:" .. tostring(entry.id)
end

local function parse_target_position(input)
  input = trim(input)
  if input == "" then
    return nil
  end

  if input:match("^%-?%d+:%d+:%d+[:;.]%d+$") then
    return reaper.parse_timestr_pos(input, 5)
  end

  if input:match("^%-?%d+[%.:]%d+([%.:]%d+)?$") then
    return reaper.parse_timestr_pos(input:gsub(":", "."), 2)
  end

  local as_seconds = tonumber(input)
  if as_seconds then
    return as_seconds
  end

  local parsed = reaper.parse_timestr_pos(input, -1)
  if parsed and parsed >= 0 then
    return parsed
  end

  return nil
end

-- ------------------------------------------------------------------- panel

-- env = { MARKERS = steelblue_markers, title = string }
--
-- Every panel gets its own fields, so two of them in one REAPER session would
-- not share a typed target. In practice one script draws one panel.
function M.create(env)
  env = env or {}

  local MARKERS = env.MARKERS
  local SCRIPT_TITLE = env.title or "Copy Markers"

  -- Spacing is preserved relative to the earliest selected marker, so the copy
  -- must run in timeline order regardless of the order they were clicked in.
  -- Each copy keeps the original's ruler lane (marker.lane is nil below 7.72,
  -- which add_marker treats as "no lane requested" -- same result as before).
  local function copy_markers(entries, target_pos)
    local markers = MARKERS.sorted_by_position(entries)
    local source_start = markers[1].pos

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local copied = 0
    for _, marker in ipairs(markers) do
      local new_pos = target_pos + (marker.pos - source_start)
      local entry = MARKERS.add_marker(new_pos, marker.name, marker.color, marker.lane)
      if entry then
        copied = copied + 1
      end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Copy project markers", -1)

    return copied
  end

  local function selection_hint(reason)
    if reason == MARKERS.NO_API then
      return "Cannot read the selection: JS_ReaScriptAPI is missing and REAPER is older than 7.62."
    end

    if reason == MARKERS.MANAGER_CLOSED then
      return "Open the Region/Marker Manager and select the markers to copy."
    end

    return "Select markers in the Region/Marker Manager."
  end

  -- --------------------------------------------------------------- fallback

  local function run_fallback()
    local entries, reason = MARKERS.selected()
    if #entries == 0 then
      reaper.ShowMessageBox(selection_hint(reason), SCRIPT_TITLE, 0)
      return
    end

    local cursor_pos = reaper.GetCursorPosition()
    local cursor_timecode = reaper.format_timestr_pos(cursor_pos, "", 5)

    local ok, input = reaper.GetUserInputs(
      SCRIPT_TITLE,
      1,
      "Target position, empty = edit cursor (" .. cursor_timecode .. "):",
      ""
    )
    if not ok then
      return
    end

    local target_pos = cursor_pos
    if trim(input) ~= "" then
      target_pos = parse_target_position(input)
    end

    if not target_pos then
      reaper.ShowMessageBox("Invalid target position.", SCRIPT_TITLE, 0)
      return
    end

    local copied = copy_markers(entries, target_pos)
    reaper.ShowMessageBox(tostring(copied) .. " markers copied.", SCRIPT_TITLE, 0)
  end

  -- ------------------------------------------------------------------ frame

  -- Empty = follows the edit cursor. Each field gets its own flag, set as soon
  -- as the user types something into it and cleared as soon as they empty it
  -- again -- that is the whole "follow" rule.
  local measure_input = ""
  local timecode_input = ""
  local measure_manual = false
  local timecode_manual = false

  -- The SELECTION section already tells the user to pick markers; the footer
  -- is for what HAPPENED, so it starts neutral instead of repeating the hint
  -- and contradicting a live "3 markers selected" right above it.
  local status_message = "Ready."
  local status_kind = nil

  -- `entries` here is what the user TICKED, never the manager selection
  -- directly. In follow mode the two are the same set, which is why the older
  -- copy suites keep passing unchanged.
  local function run_copy(entries, target_pos)
    if #entries == 0 then
      status_message = "Tick the markers to copy."
      status_kind = "warning"
      return
    end

    if not target_pos then
      status_message = "Invalid target position."
      status_kind = "error"
      return
    end

    local copied = copy_markers(entries, target_pos)
    status_message = tostring(copied) .. " markers copied."
    status_kind = "success"
  end

  -- Work queued by a button, to be run AFTER the ImGui frame is closed, so that
  -- Undo_BeginBlock / PreventUIRefresh / UpdateArrange never run between Begin
  -- and End. Defensive housekeeping, not a fix for a known bug -- keeping REAPER
  -- project mutations out of the frame is simply the safer shape.
  local pending = nil

  -- Reading the selection means asking JS_ReaScriptAPI to enumerate every window
  -- matching "Region/Marker Manager", walk its list view, and allocate a fresh
  -- 1024-slot array -- far too heavy to do on every frame at 60 fps. Poll a few
  -- times a second and reuse the answer in between; no one clicks faster.
  local POLL_INTERVAL = 0.15
  local last_poll = -1
  local cached_entries, cached_reason, cached_source = {}, nil, nil

  -- A host that already polls (the workspace does, for its header band) hands
  -- its answer in through opts.entries, and the panel does not ask a second
  -- time.
  local function selection(opts)
    if opts.entries then
      return opts.entries, opts.reason, opts.source
    end

    local now = reaper.time_precise()
    if now - last_poll >= POLL_INTERVAL then
      last_poll = now
      cached_entries, cached_reason, cached_source = MARKERS.selected()
    end
    return cached_entries, cached_reason, cached_source
  end

  -- ------------------------------------------------------------ marker list

  -- Every marker in the project, in timeline order, one row each. Re-read on
  -- the same 150 ms beat as the selection: markers_by_id() is an enumeration
  -- over the whole project, which is cheap enough a few times a second even
  -- with several hundred markers (measured in tests/copy_pick_test.lua), and
  -- far too expensive at 60 fps.
  local rows = {}
  local row_by_key = {}
  local last_list_poll = -1

  -- Which markers are ticked, keyed by entry_key.
  --
  --   "follow"  the ticks mirror the manager selection on every frame. This is
  --             the start state, and it makes the panel behave exactly as it
  --             did before the list existed.
  --   "manual"  the first click on a tick box switches here, and from then on
  --             the ticks stay put no matter what the manager does. That is
  --             the whole point: clicking another marker in the manager must
  --             not throw away what was already picked.
  local ticked = {}
  local tick_mode = "follow"

  local function read_rows()
    local entries = {}
    for _, entry in pairs(MARKERS.markers_by_id()) do
      entries[#entries + 1] = entry
    end
    entries = MARKERS.sorted_by_position(entries)

    -- Both of these are resolved once per READ, not once per frame per row:
    -- lane_name() re-probes lanes_available() on every call, and formatting a
    -- position is a REAPER round-trip. 600 rows at 60 fps would be 72000 of
    -- them a second for text that only changes when the project does.
    local lane_names = {}
    local new_rows, by_key = {}, {}

    for _, entry in ipairs(entries) do
      local lane_label = nil
      if entry.lane then
        if lane_names[entry.lane] == nil then
          lane_names[entry.lane] = MARKERS.lane_name(entry.lane) or ""
        end
        if lane_names[entry.lane] ~= "" then
          lane_label = lane_names[entry.lane]
        end
      end

      local key = entry_key(entry)
      local row = {
        key = key,
        entry = entry,
        position = reaper.format_timestr_pos(entry.pos, "", 2),
        name = entry.name,
        lane = lane_label,
      }

      new_rows[#new_rows + 1] = row
      by_key[key] = row
    end

    rows, row_by_key = new_rows, by_key

    -- A marker that is no longer in the project cannot be copied, so its tick
    -- goes with it -- otherwise "3 ticked" would count markers nobody can see.
    for key in pairs(ticked) do
      if not row_by_key[key] then
        ticked[key] = nil
      end
    end
  end

  local function refresh_list()
    local now = reaper.time_precise()
    if now - last_list_poll >= POLL_INTERVAL then
      last_list_poll = now
      read_rows()
    end
  end

  -- Ticks := the manager selection. Only markers that actually have a row can
  -- be ticked, so the counter never promises more than the list shows.
  local function follow_selection(entries)
    ticked = {}
    for _, entry in ipairs(entries or {}) do
      local key = entry_key(entry)
      if row_by_key[key] then
        ticked[key] = true
      end
    end
  end

  -- In list order, which is timeline order.
  local function picked_entries()
    local picked = {}
    for _, row in ipairs(rows) do
      if ticked[row.key] then
        picked[#picked + 1] = row.entry
      end
    end
    return picked
  end

  local function draw_selection(ctx, SB, entries, reason, source)
    SB.section(ctx, "Selection")

    if #entries > 0 then
      local label = tostring(#entries) .. (#entries == 1 and " marker" or " markers") .. " selected"
      if source == "arrange" then
        label = label .. "  (arrange view)"
      end
      reaper.ImGui_TextColored(ctx, SB.color.blue_text, label)
    else
      reaper.ImGui_TextColored(ctx, SB.color.text_muted, selection_hint(reason))
    end
  end

  -- The two target fields; side by side in the wide layout, stacked otherwise.
  local function draw_fields(ctx, side_by_side)
    reaper.ImGui_PushItemWidth(ctx, 200)
    local changed
    changed, measure_input = reaper.ImGui_InputText(ctx, "measure.beats", measure_input)
    if changed then
      measure_manual = trim(measure_input) ~= ""
    end
    if side_by_side then
      reaper.ImGui_SameLine(ctx)
    end
    changed, timecode_input = reaper.ImGui_InputText(ctx, "hh:mm:ss:ff", timecode_input)
    if changed then
      timecode_manual = trim(timecode_input) ~= ""
    end
    reaper.ImGui_PopItemWidth(ctx)
  end

  -- One row per marker: tick box, position, name, ruler lane. The tick box
  -- carries an empty "##" label so the text next to it can be laid out in
  -- columns instead of running after a checkbox-shaped label.
  local function draw_rows(ctx, SB)
    for _, row in ipairs(rows) do
      local changed, value = reaper.ImGui_Checkbox(ctx, "##pick_" .. row.key, ticked[row.key] == true)
      if changed then
        -- the first click is the moment the user takes over from the manager
        tick_mode = "manual"
        ticked[row.key] = value and true or nil
      end

      reaper.ImGui_SameLine(ctx)
      local column_x = reaper.ImGui_GetCursorPosX(ctx)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      SB.label(ctx, row.position)

      reaper.ImGui_SameLine(ctx)
      if type(column_x) == "number" then
        reaper.ImGui_SetCursorPosX(ctx, column_x + POSITION_WIDTH)
      end
      SB.label(ctx, row.name)

      if row.lane then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextColored(ctx, SB.color.text_muted, row.lane)
      end
    end
  end

  -- "Use selection" also goes back to follow mode; "Clear selection" cannot, or
  -- the very next frame would hand the ticks straight back from the manager.
  --
  -- The two labels say what they do rather than what they are (Tobi,
  -- 2026-09-16): "None" on its own reads like a filter, and "N ticked" is not a
  -- word anyone uses about a marker. Same wording in both layouts.
  local function draw_pick_controls(ctx, SB, entries)
    if SB.button(ctx, "Use selection", 140) then
      tick_mode = "follow"
      follow_selection(entries)
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Clear selection", 130) then
      tick_mode = "manual"
      ticked = {}
    end

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    SB.label(ctx, tostring(#picked_entries()) .. " selected")
  end

  -- What gets copied is read at CLICK time and handed to the queued work, the
  -- same way the selection used to be.
  local function draw_buttons(ctx, SB, stacked, width)
    width = width or BUTTON_WIDTH_NARROW

    local function next_item()
      if not stacked then
        reaper.ImGui_SameLine(ctx)
      end
    end

    if SB.primary_button(ctx, "Copy to cursor", width) then
      local picked = picked_entries()
      pending = function() run_copy(picked, reaper.GetCursorPosition()) end
    end

    next_item()

    if SB.button(ctx, "Copy to measure.beats", width) then
      local picked = picked_entries()
      local target = parse_target_position(measure_input)
      pending = function() run_copy(picked, target) end
    end

    next_item()

    if SB.button(ctx, "Copy to hh:mm:ss:ff", width) then
      local picked = picked_entries()
      local target = parse_target_position(timecode_input)
      pending = function() run_copy(picked, target) end
    end
  end

  -- Eight rows' worth. Fixed, because the window around it auto-sizes.
  local function narrow_list_height(ctx)
    local frame_h = FRAME_HEIGHT_FALLBACK
    if reaper.ImGui_GetFrameHeight then
      local measured = reaper.ImGui_GetFrameHeight(ctx)
      if type(measured) == "number" and measured > 0 then
        frame_h = measured
      end
    end
    return LIST_ROWS * (frame_h + ITEM_SPACING_Y)
  end

  -- Everything the host has left, minus what it still needs for its footer.
  local function wide_column_height(ctx)
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    if type(avail_h) ~= "number" then
      return 200
    end

    local height = avail_h - HOST_FOOTER_HEIGHT - ITEM_SPACING_Y
    if height < 80 then
      height = 80
    end
    return height
  end

  -- Sections stacked, the way the single window has always had them, with the
  -- marker list between the target fields and the copy buttons.
  local function draw_narrow(ctx, SB, entries, current_cursor_pos)
    SB.section(ctx, "Edit cursor")
    SB.label(ctx, "Measure   " .. reaper.format_timestr_pos(current_cursor_pos, "", 2))
    SB.label(ctx, "Timecode  " .. reaper.format_timestr_pos(current_cursor_pos, "", 5))

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Target position")

    draw_fields(ctx, false)

    SB.label(ctx, "Empty field follows the edit cursor. Type a position to pin it.")

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Markers")

    child(ctx, SB, "copy_pick_list", LIST_WIDTH, narrow_list_height(ctx), SB.color.frame_bg,
      function() draw_rows(ctx, SB) end)

    draw_pick_controls(ctx, SB, entries)

    draw_buttons(ctx, SB, false)
  end

  -- How wide the list is and where it starts, given what the host has left.
  -- Returns nil for the x when the build cannot say, and the caller then falls
  -- back to a plain SameLine.
  local function wide_list_geometry(ctx)
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local start_x = reaper.ImGui_GetCursorPosX(ctx)

    if type(avail_w) ~= "number" or avail_w <= 0 then
      return LIST_WIDTH_WIDE, nil
    end

    local width = LIST_WIDTH_WIDE
    if avail_w < LIST_WIDTH_WIDE + MIN_LEFT_WIDTH + COLUMN_GAP then
      width = math.max(240, avail_w - MIN_LEFT_WIDTH - COLUMN_GAP)
    end

    if type(start_x) ~= "number" then
      return width, nil
    end

    return width, start_x + avail_w - width
  end

  -- Two columns across the docker: the controls on the left, the marker list
  -- pinned to the RIGHT edge at a fixed 520 px. Right-aligning is allowed here
  -- for the same reason steelblue_workspace.lua's header_right is allowed to do
  -- it: the docker decides the width, so "available minus my own width" cannot
  -- feed back into the window size the way it does in an auto-resizing window.
  -- Nothing inside the left column is right-aligned.
  --
  -- The left column is a GROUP, not a child: it has to keep drawing its
  -- buttons whatever happens, and a child that reports itself clipped would
  -- take the whole panel off screen with it. Only the list -- the part that
  -- has to scroll -- is a child.
  --
  -- It carries the same sections as the single window, because a flat stack of
  -- rows with nothing between them was what Tobi called untidy (2026-09-16).
  -- Measure and Timecode share ONE line: the sections and separators cost
  -- about 91 px that the old flat column did not, and at a 400 px docker the
  -- column has roughly 250 px to live in -- see REPORT-v2j for the arithmetic.
  local function draw_wide(ctx, SB, entries, current_cursor_pos)
    local height = wide_column_height(ctx)
    local list_w, list_x = wide_list_geometry(ctx)

    reaper.ImGui_BeginGroup(ctx)

    SB.section(ctx, "Edit cursor")
    SB.label(ctx, "Measure " .. reaper.format_timestr_pos(current_cursor_pos, "", 2)
      .. "  \194\183  Timecode " .. reaper.format_timestr_pos(current_cursor_pos, "", 5))

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Target position")

    draw_fields(ctx, false)

    SB.label(ctx, "Empty field follows the edit cursor. Type a position to pin it.")

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Copy")

    draw_buttons(ctx, SB, true, BUTTON_WIDTH_WIDE)

    -- The tick row belongs to the list, not to the copy buttons; 6 px of air
    -- says so without a second separator.
    reaper.ImGui_Dummy(ctx, 1, 6)

    draw_pick_controls(ctx, SB, entries)

    reaper.ImGui_EndGroup(ctx)

    reaper.ImGui_SameLine(ctx)
    if list_x then
      reaper.ImGui_SetCursorPosX(ctx, list_x)
    end

    child(ctx, SB, "copy_pick_list", list_w, height, SB.color.frame_bg,
      function() draw_rows(ctx, SB) end)
  end

  -- Draws the panel into a frame the host has already opened.
  --
  --   opts.wide            fields and buttons in one row instead of sections
  --   opts.show_selection  the "N markers selected" block -- the workspace
  --                        already says that in its header band
  --   opts.entries         the selection the host has already polled, with
  --   opts.source          its source (and opts.reason); when given, the
  --                        panel does not poll on its own
  local function frame(ctx, SB, opts)
    opts = opts or {}

    local current_cursor_pos = reaper.GetCursorPosition()

    if not measure_manual then
      measure_input = reaper.format_timestr_pos(current_cursor_pos, "", 2)
    end
    if not timecode_manual then
      timecode_input = reaper.format_timestr_pos(current_cursor_pos, "", 5)
    end

    -- the list first: follow mode can only tick markers that have a row
    refresh_list()

    local entries, reason, source = selection(opts)

    if tick_mode == "follow" then
      follow_selection(entries)
    end

    if opts.show_selection then
      draw_selection(ctx, SB, entries, reason, source)
      reaper.ImGui_Separator(ctx)
    end

    if opts.wide then
      draw_wide(ctx, SB, entries, current_cursor_pos)
    else
      draw_narrow(ctx, SB, entries, current_cursor_pos)
    end

    return false
  end

  -- Outside the frame: safe to touch the project. The host calls this after
  -- its end_window, never inside the frame.
  local function after_frame()
    if not pending then
      return false
    end

    local action = pending
    pending = nil
    action()
    return true
  end

  -- What the host puts in its footer.
  local function status()
    return status_message, status_kind
  end

  return {
    frame = frame,
    after_frame = after_frame,
    status = status,
    run_fallback = run_fallback,
  }
end

return M
