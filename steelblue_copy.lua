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
-- What belongs here: the target fields and their follow rule, the copy, the
-- selection poll, the pending queue, the plain-dialog fallback.
-- What does NOT belong here: the window and the footer. The panel hands its
-- status line back with status() so the host can put it where its own layout
-- wants it.

local M = {}

M.VERSION = "1.0"

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
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

  local function run_copy(entries, target_pos)
    if #entries == 0 then
      status_message = "No markers selected."
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

  local function draw_buttons(ctx, SB, entries)
    if SB.primary_button(ctx, "Copy to cursor", 200) then
      pending = function() run_copy(entries, reaper.GetCursorPosition()) end
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Copy to measure.beats", 200) then
      local target = parse_target_position(measure_input)
      pending = function() run_copy(entries, target) end
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Copy to hh:mm:ss:ff", 200) then
      local target = parse_target_position(timecode_input)
      pending = function() run_copy(entries, target) end
    end
  end

  -- Sections stacked, the way the single window has always had them.
  local function draw_narrow(ctx, SB, entries, current_cursor_pos)
    SB.section(ctx, "Edit cursor")
    SB.label(ctx, "Measure   " .. reaper.format_timestr_pos(current_cursor_pos, "", 2))
    SB.label(ctx, "Timecode  " .. reaper.format_timestr_pos(current_cursor_pos, "", 5))

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Target position")

    draw_fields(ctx, false)

    SB.label(ctx, "Empty field follows the edit cursor. Type a position to pin it.")

    draw_buttons(ctx, SB, entries)
  end

  -- One flat strip across the docker: the cursor read-out, then the two
  -- fields and the three buttons in ONE row, then the hint.
  local function draw_wide(ctx, SB, entries, current_cursor_pos)
    SB.label(ctx, "Measure   " .. reaper.format_timestr_pos(current_cursor_pos, "", 2))
    reaper.ImGui_SameLine(ctx)
    SB.label(ctx, "Timecode  " .. reaper.format_timestr_pos(current_cursor_pos, "", 5))

    draw_fields(ctx, true)

    reaper.ImGui_SameLine(ctx)
    draw_buttons(ctx, SB, entries)

    SB.label(ctx, "Empty field follows the edit cursor. Type a position to pin it.")
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

    local entries, reason, source = selection(opts)

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
