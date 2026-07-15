-- CopyMarkers.lua
-- Copies the markers selected in REAPER's Region/Marker Manager to a new
-- absolute target position, preserving spacing, names, and colors.
--
-- The selection is read live: the window can stay open while markers are
-- (de)selected and the edit cursor is moved.

local SCRIPT_TITLE = "Copy Markers"

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

local function load_module(name)
  local chunk = loadfile(folder .. name)
  if not chunk then
    reaper.ShowMessageBox(
      name .. " is missing next to this script.\n\n" ..
      "Please copy the whole steelblue package into the same folder.",
      SCRIPT_TITLE,
      0
    )
    return nil
  end

  return chunk()
end

local MARKERS = load_module("steelblue_markers.lua")
if not MARKERS then
  return
end

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function destroy_imgui_context(ctx)
  if ctx and reaper.APIExists and reaper.APIExists("ImGui_DestroyContext") then
    reaper.ImGui_DestroyContext(ctx)
  end
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

-- Spacing is preserved relative to the earliest selected marker, so the copy
-- must run in timeline order regardless of the order they were clicked in.
local function copy_markers(entries, target_pos)
  local markers = MARKERS.sorted_by_position(entries)
  local source_start = markers[1].pos

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, marker in ipairs(markers) do
    local new_pos = target_pos + (marker.pos - source_start)
    reaper.AddProjectMarker2(0, false, new_pos, 0, marker.name, -1, marker.color)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Copy project markers", -1)

  return #markers
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

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)
  local cursor_pos = reaper.GetCursorPosition()
  local measure_input = reaper.format_timestr_pos(cursor_pos, "", 2)
  local timecode_input = reaper.format_timestr_pos(cursor_pos, "", 5)
  -- The SELECTION section above already tells the user to pick markers; the
  -- footer is for what HAPPENED, so it starts neutral instead of repeating the
  -- hint and contradicting a live "3 markers selected" right above it.
  local status = "Ready."
  local status_kind = nil

  local function refresh_from_cursor()
    local current = reaper.GetCursorPosition()
    measure_input = reaper.format_timestr_pos(current, "", 2)
    timecode_input = reaper.format_timestr_pos(current, "", 5)
    status = "Target fields refreshed from the edit cursor."
    status_kind = nil
  end

  local function run_copy(entries, target_pos)
    if #entries == 0 then
      status = "No markers selected."
      status_kind = "warning"
      return
    end

    if not target_pos then
      status = "Invalid target position."
      status_kind = "error"
      return
    end

    local copied = copy_markers(entries, target_pos)
    status = tostring(copied) .. " markers copied."
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

  local function selection()
    local now = reaper.time_precise()
    if now - last_poll >= POLL_INTERVAL then
      last_poll = now
      cached_entries, cached_reason, cached_source = MARKERS.selected()
    end
    return cached_entries, cached_reason, cached_source
  end

  local function loop()
    local current_cursor_pos = reaper.GetCursorPosition()

    local entries, reason, source = selection()
    local has_selection = #entries > 0

    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 430)

    if visible then
      SB.section(ctx, "Selection")

      if has_selection then
        local label = tostring(#entries) .. (#entries == 1 and " marker" or " markers") .. " selected"
        if source == "arrange" then
          label = label .. "  (arrange view)"
        end
        reaper.ImGui_TextColored(ctx, SB.color.blue_text, label)
      else
        reaper.ImGui_TextColored(ctx, SB.color.text_muted, selection_hint(reason))
      end

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Edit cursor")
      SB.label(ctx, "Measure   " .. reaper.format_timestr_pos(current_cursor_pos, "", 2))
      SB.label(ctx, "Timecode  " .. reaper.format_timestr_pos(current_cursor_pos, "", 5))

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Target position")

      reaper.ImGui_PushItemWidth(ctx, 200)
      local _
      _, measure_input = reaper.ImGui_InputText(ctx, "measure.beats", measure_input)
      _, timecode_input = reaper.ImGui_InputText(ctx, "hh:mm:ss:ff", timecode_input)
      reaper.ImGui_PopItemWidth(ctx)

      if SB.primary_button(ctx, "Copy to cursor", 200) then
        pending = function() run_copy(entries, reaper.GetCursorPosition()) end
      end

      reaper.ImGui_SameLine(ctx)

      if SB.button(ctx, "Refresh from cursor", 200) then
        refresh_from_cursor()
      end

      if SB.button(ctx, "Copy to measure.beats", 200) then
        local target = parse_target_position(measure_input)
        pending = function() run_copy(entries, target) end
      end

      reaper.ImGui_SameLine(ctx)

      if SB.button(ctx, "Copy to hh:mm:ss:ff", 200) then
        local target = parse_target_position(timecode_input)
        pending = function() run_copy(entries, target) end
      end

      SB.footer(ctx, status, status_kind)
    end

    SB.end_window(ctx, visible, font)

    -- outside the frame: safe to touch the project
    if pending then
      local action = pending
      pending = nil
      action()
    end

    if open then
      reaper.defer(loop)
    else
      destroy_imgui_context(ctx)
    end
  end

  reaper.defer(loop)
end

if reaper.APIExists and reaper.APIExists("ImGui_CreateContext") then
  local SB = load_module("steelblue_ui.lua")
  if SB then
    run_gui(SB)
  end
else
  run_fallback()
end
