-- steelblue_rename.lua
-- "Rename selected markers" without a window around it.
--
-- Usage:
--   local RENAME = BOOT.load_module(folder, "steelblue_rename.lua", TITLE)
--   local panel = RENAME.create({ MARKERS = MARKERS, MA = MA, title = TITLE })
--   ...
--   local visible, open, font = SB.begin_window(ctx, TITLE, 620)
--   if visible then
--     panel.frame(ctx, SB, { show_selection = true, show_reference = true })
--     SB.footer(ctx, panel.status())
--   end
--   SB.end_window(ctx, visible, font)
--   panel.after_frame()
--
-- Two hosts draw this same panel: the single script "Rename selected
-- markers.lua" in its own auto-sized window, and steelblue_workspace.lua in the
-- tab of the same name. That is the whole reason the file exists -- the logic
-- and the fields must not be copied into a second place, because a copy is a
-- thing that rots (AGENTS.md, 2026-07-15).
--
-- What belongs here: the state, the naming rules, the prefill, the colour, the
-- selection poll, the pending queue, the plain-dialog fallback.
-- What does NOT belong here: the window and the footer. The panel submits
-- items into a frame someone else opened, and hands its status line back with
-- status() so the host can put it wherever its own layout wants it.

local M = {}

M.VERSION = "1.1"

-- The colour of the last run, remembered across REAPER sessions.
local EXT_SECTION = "steelblue_rename"
local EXT_LAST_COLOUR = "last_color"

local DEFAULTS = {
  cue_name = "MarkerName",
  use_cue_number = true,
  cue_number = "1",
  create_multiple_cues = false,
  multiple_cue_count = 1,
  command_name = "Top",
  sequence_name = "MarkerName",
  set_colour = true,
  colour_mode = "random",
}

-- The commands offered in the Command list. The state keeps the TEXT, not the
-- index, so the test hook, MA.format, prefill_from and the fallback dialog
-- work exactly as before.
local COMMANDS = { "Go", "Top", "Flash" }

-- Items for ImGui_Combo (each one null-terminated) and the 0-based index of
-- the current command. A command outside the three -- prefilled from a marker
-- that says "On", say -- is shown as a fourth entry for as long as it is
-- active; choosing one of the three drops it.
local function command_choices(current)
  local items = {}
  local index

  for i, name in ipairs(COMMANDS) do
    items[i] = name
    if name == current then
      index = i - 1
    end
  end

  if index == nil then
    items[#items + 1] = current
    index = #items - 1
  end

  return table.concat(items, "\0") .. "\0", index, items
end

math.randomseed(math.floor((reaper.time_precise and reaper.time_precise() or os.time()) * 1000000) % 2147483647)

-- ------------------------------------------------------------- little things

local function imgui_text_wrapped(ctx, text)
  if reaper.APIExists and reaper.APIExists("ImGui_TextWrapped") then
    reaper.ImGui_TextWrapped(ctx, text)
  else
    reaper.ImGui_Text(ctx, text)
  end
end

-- A marker colour as ImGui wants it. ColorFromNative is guarded because it is
-- the one call whose three return values a stripped-down environment can turn
-- into one.
local function imgui_colour(native)
  local red, green, blue = reaper.ColorFromNative(native & 0xFFFFFF)
  red, green, blue = red or 0, green or 0, blue or 0

  return (red << 24) | (green << 16) | (blue << 8) | 0xFF
end

local function can_disable()
  return reaper.APIExists and reaper.APIExists("ImGui_BeginDisabled")
    and reaper.APIExists("ImGui_EndDisabled")
end

-- The same palette the MIDI plugin uses: mid-range channels stay readable on
-- REAPER's dark ruler. Always through ColorToNative -- the byte order is
-- platform dependent -- and | 0x1000000, the bit that says "this marker has a
-- colour of its own".
local function random_marker_colour()
  local red = math.random(70, 235)
  local green = math.random(70, 235)
  local blue = math.random(70, 235)

  return reaper.ColorToNative(red, green, blue) | 0x1000000
end

-- An empty field leaves its element out, so "" stays "" here -- the old version
-- read it as "use the marker's name", which only made sense while a checkbox
-- next to the field decided whether the element appeared at all.
local function resolve_marker_name_placeholder(text, source_marker_name)
  if text == "MarkerName" then
    return source_marker_name or ""
  end

  return (text:gsub("MarkerName", function()
    return source_marker_name or ""
  end))
end

local function format_cue_number(number)
  if math.floor(number) == number then
    return tostring(math.floor(number))
  end

  return tostring(number)
end

-- The legend under the fields. One line per syntax element, aligned by the
-- blanks in the strings themselves, which is why they are drawn as plain
-- labels and not as a table.
local REFERENCE_LINES = {
  "MarkerName    the first selected marker's name, or its cue name if it already has MA syntax",
  "Cue name      name of the cue",
  "(CueNumber)   cue number, for triggering the same cue repeatedly",
  "Multiple      increments the cue number in timeline order",
  "[Cmd]         TC trigger command, e.g. Top, On, Off. Default is Top",
  "^Sequence^    name of the sequence, only needed once",
  "Empty field   leaves that element out",
  "Example       BeatFx(1)[Top]^BeatFx^",
}

-- Below this the two-column legend would overlap itself, so it falls back to
-- one column. The docked workspace is far wider; a floating window is not.
local TWO_COLUMN_MIN_WIDTH = 1200

-- ------------------------------------------------------------------- panel

-- env = { MARKERS = steelblue_markers, MA = steelblue_matools, title = string }
--
-- Every panel gets its own state, so two of them in one REAPER session would
-- not share fields. In practice one script draws one panel; the isolation is
-- there because module-level state is the kind of thing that only bites later.
function M.create(env)
  env = env or {}

  local MARKERS = env.MARKERS
  local MA = env.MA
  local SCRIPT_TITLE = env.title or "Rename selected markers"

  local state = {}

  local function copy_defaults()
    for key, value in pairs(DEFAULTS) do
      state[key] = value
    end
  end

  copy_defaults()

  -- Whether the fields have already been filled in from a selected marker. Once
  -- per window run: after that the fields belong to the user.
  local prefilled = false

  local status_message = ""
  local status_kind = nil

  local function set_status(text, kind)
    status_message = text
    status_kind = kind
  end

  local function last_status()
    return status_message, status_kind
  end

  local function get_state()
    local copy = {}
    for key, value in pairs(state) do
      copy[key] = value
    end
    return copy
  end

  local function set_state(values)
    for key, value in pairs(values or {}) do
      state[key] = value
    end
  end

  -- Back to the values the window opens with -- not to what the selected marker
  -- happens to say. Someone who asks for the defaults wants the defaults, so the
  -- prefill counts as done and does not undo this a moment later.
  local function reset_to_defaults()
    copy_defaults()
    prefilled = true
    set_status("Defaults restored.")
  end

  -- ----------------------------------------------------------- marker names

  -- What the MarkerName placeholder stands for, given the template marker's
  -- name. A marker that already carries MA syntax contributes only its cue
  -- name, so running the script twice cannot wrap "Kick(1)[Top]^Kick^" into
  -- itself again.
  local function base_name(marker_name)
    local parts = MA.parse(marker_name)
    return parts and (parts.cue or "") or marker_name
  end

  local function parse_cue_number()
    local number = tonumber(state.cue_number)
    if number then
      return number
    end

    return 1
  end

  -- The wrap is deliberate: six markers with "how many cues" set to five are
  -- numbered 1 2 3 4 5 1.
  local function get_cue_number_for_marker(marker_offset)
    if not state.create_multiple_cues then
      return state.cue_number
    end

    local cue_count = math.max(1, math.floor(tonumber(state.multiple_cue_count) or 1))
    local offset = marker_offset or 0
    local number_offset = offset % cue_count

    return format_cue_number(parse_cue_number() + number_offset)
  end

  local function build_marker_name(template_name, marker_offset)
    local base = base_name(template_name)

    local number = nil
    if state.use_cue_number then
      number = get_cue_number_for_marker(marker_offset)
    end

    return MA.format({
      cue = resolve_marker_name_placeholder(state.cue_name, base),
      number = number,
      command = state.command_name,
      sequence = resolve_marker_name_placeholder(state.sequence_name, base),
    })
  end

  -- The order a run works in. Cue numbers follow the order the user clicked in,
  -- which only the manager knows; the arrange fallback has no click order, so it
  -- goes along the timeline instead -- that is what the missing JS extension
  -- costs. The first entry is also the template (below).
  local function ordered_for_numbering(entries, source)
    if source ~= "manager" then
      return MARKERS.sorted_by_position(entries)
    end

    local ordered = {}
    for index, entry in ipairs(entries) do
      ordered[index] = entry
    end

    table.sort(ordered, function(left, right)
      return (left.selection_order or 0) < (right.selection_order or 0)
    end)

    return ordered
  end

  -- The one marker a whole run is named after: the one clicked first, or the
  -- earliest on the timeline when there is no click order. MarkerName means THIS
  -- marker's name for every marker of the run -- selecting Kick, Snare and Hat
  -- and renaming gives three markers called Kick, which is the point: they belong
  -- to one cue list. The preview, the prefill and the rename all ask this, so
  -- what the preview shows is what the run writes.
  local function template_for(entries, source)
    if not entries or #entries == 0 then
      return nil
    end

    return ordered_for_numbering(entries, source)[1]
  end

  -- Fills the fields from the syntax the template marker already carries, so the
  -- first thing the user sees is what is there rather than the defaults. Happens
  -- once, on the first poll that finds a selection; a marker without syntax
  -- changes nothing but still uses up the one chance, because the alternative is
  -- fields that rewrite themselves while the user is typing in them.
  local function prefill_from(marker_name)
    if prefilled then
      return false
    end

    prefilled = true

    local parts = MA.parse(marker_name)
    if not parts then
      return false
    end

    state.command_name = parts.command or ""

    if parts.number ~= nil then
      -- through MA.format, so the number is written the way the module writes it
      -- everywhere else: "1", never "1.0"
      state.cue_number = MA.format({ number = parts.number }):match("^%((.*)%)$")
    end
    state.use_cue_number = parts.number ~= nil

    if parts.sequence == nil then
      state.sequence_name = ""
    elseif parts.sequence == parts.cue then
      state.sequence_name = "MarkerName"
    else
      state.sequence_name = parts.sequence
    end

    set_status("Fields taken from the selected marker.")
    return true
  end

  local function prefill_from_selection(entries, source)
    local template = template_for(entries, source)
    if not template then
      return false
    end

    return prefill_from(template.name)
  end

  -- ----------------------------------------------------------------- colour

  local random_colour = random_marker_colour()

  local function next_random_colour()
    random_colour = random_marker_colour()
    return random_colour
  end

  local function stored_colour()
    local text = reaper.GetExtState(EXT_SECTION, EXT_LAST_COLOUR)
    return tonumber(text)
  end

  -- The colour this run would use, or nil for "leave the colours alone".
  local function pick_colour()
    if not state.set_colour then
      return nil
    end

    if state.colour_mode == "last" then
      return stored_colour()
    end

    return random_colour
  end

  -- --------------------------------------------------------------- renaming

  local function run_rename(entries, source)
    entries = entries or {}

    if #entries == 0 then
      set_status("No selected markers found.", "warning")
      return 0
    end

    local ordered = ordered_for_numbering(entries, source)
    local template = ordered[1].name

    if build_marker_name(template, 0) == "" then
      set_status("Enter at least a name or one syntax element.", "warning")
      return 0
    end

    local wanted_colour = state.set_colour
    local colour = pick_colour()

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    for index, entry in ipairs(ordered) do
      -- every marker of the run is named after the template, not after itself
      local new_name = build_marker_name(template, index - 1)
      MARKERS.rename(entry, new_name)

      if colour then
        MARKERS.set_color(entry, colour)
      end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateTimeline()
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Rename selected markers", -1)

    if colour then
      reaper.SetExtState(EXT_SECTION, EXT_LAST_COLOUR, tostring(colour), true)
    end

    -- a fresh colour for the next run, so "Random" twice in a row means two
    -- colours
    next_random_colour()

    if wanted_colour and not colour then
      set_status("No colour used yet - pick Random.", "warning")
    elseif colour then
      set_status(tostring(#ordered) .. " markers renamed and coloured.", "success")
    else
      set_status(tostring(#ordered) .. " markers renamed.", "success")
    end

    return #ordered
  end

  -- --------------------------------------------------------------- fallback

  local function run_fallback()
    local entries, _, source = MARKERS.selected()
    if #entries == 0 then
      reaper.ShowMessageBox(
        "No selected markers found.\n\nSelect markers in the Region/Marker Manager and run the script again.",
        SCRIPT_TITLE,
        0
      )
      return
    end

    prefill_from_selection(entries, source)

    -- No colour option here on purpose: GetUserInputs is a row of text boxes, and
    -- a colour is only worth offering next to a swatch that shows it.
    local ok, values = reaper.GetUserInputs(
      SCRIPT_TITLE,
      6,
      "Cue name,Cue number (empty = none),Command,Sequence name,Multiple cues? (y/n),How many cues",
      table.concat({
        state.cue_name,
        state.use_cue_number and state.cue_number or "",
        state.command_name,
        state.sequence_name,
        state.create_multiple_cues and "y" or "n",
        tostring(state.multiple_cue_count),
      }, ",")
    )

    if not ok then
      return
    end

    local name_text, number_text, command_text, sequence_text, multiple_text, count_text =
      values:match("([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)")

    state.cue_name = name_text or ""
    state.cue_number = number_text or ""
    state.use_cue_number = state.cue_number ~= ""
    state.command_name = command_text or ""
    state.sequence_name = sequence_text or ""
    state.create_multiple_cues = (multiple_text or ""):lower():sub(1, 1) == "y"
    state.multiple_cue_count = math.max(1, math.floor(tonumber(count_text) or 1))
    state.set_colour = false

    run_rename(entries, source)

    local text = last_status()
    if text ~= "" then
      reaper.ShowMessageBox(text, SCRIPT_TITLE, 0)
    end
  end

  -- ------------------------------------------------------------------ frame

  -- Work queued by a button and run AFTER the frame is closed, so that
  -- Undo_BeginBlock / PreventUIRefresh / UpdateArrange never run between Begin
  -- and End. The host calls after_frame() to let it out.
  local pending = nil

  -- Reading the selection walks the manager's list view and allocates a
  -- 1024-slot array -- far too heavy for 60 fps. Poll a few times a second and
  -- reuse the answer in between; no one clicks faster.
  local POLL_INTERVAL = 0.15
  local last_poll = -1
  local cached_entries, cached_reason, cached_source = {}, nil, nil

  local function selection()
    local now = reaper.time_precise()
    if now - last_poll >= POLL_INTERVAL then
      last_poll = now
      cached_entries, cached_reason, cached_source = MARKERS.selected()

      if not prefilled and #cached_entries > 0 then
        prefill_from_selection(cached_entries, cached_source)
      end
    end

    return cached_entries, cached_reason, cached_source
  end

  local function draw_selection(ctx, SB, count, source)
    SB.section(ctx, "Selection")

    if count > 0 then
      local label = tostring(count) ..
        (count == 1 and " marker selected" or " markers selected")
      if source == "arrange" then
        label = label .. "  (arrange view)"
      end
      reaper.ImGui_TextColored(ctx, SB.color.blue_text, label)
    else
      reaper.ImGui_TextColored(ctx, SB.color.text_muted, "Select markers in the Region/Marker Manager.")
    end
  end

  local function draw_preview(ctx, SB, preview_name)
    SB.section(ctx, "Preview")

    reaper.ImGui_SetNextItemWidth(ctx, 460)
    if reaper.APIExists and reaper.APIExists("ImGui_InputTextFlags_ReadOnly") then
      reaper.ImGui_InputText(
        ctx,
        "##preview",
        preview_name,
        reaper.ImGui_InputTextFlags_ReadOnly()
      )
    else
      reaper.ImGui_Text(ctx, preview_name)
    end
  end

  -- The numbering row, identical in both layouts: it is already one line today.
  local function draw_number_row(ctx)
    local _

    _, state.use_cue_number = reaper.ImGui_Checkbox(ctx, "Cue number", state.use_cue_number)

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 90)
    _, state.cue_number = reaper.ImGui_InputText(ctx, "##cue_number", state.cue_number)

    reaper.ImGui_SameLine(ctx)
    _, state.create_multiple_cues = reaper.ImGui_Checkbox(
      ctx,
      "Create multiple cues in timeline order",
      state.create_multiple_cues
    )

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 90)
    _, state.multiple_cue_count = reaper.ImGui_InputInt(ctx, "How many cues", state.multiple_cue_count)
    state.multiple_cue_count = math.max(1, math.floor(tonumber(state.multiple_cue_count) or 1))
  end

  -- Checkbox, the two modes, and the swatch of the colour a run would use.
  -- One row in both layouts; only what comes before it differs.
  local function draw_colour_controls(ctx, SB)
    local _

    _, state.set_colour = reaper.ImGui_Checkbox(ctx, "Also set colour", state.set_colour)

    if not state.set_colour then
      return
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Random", state.colour_mode == "random") then
      state.colour_mode = "random"
    end

    local has_stored = stored_colour() ~= nil
    local greyed = not has_stored and can_disable()

    reaper.ImGui_SameLine(ctx)
    if greyed then
      reaper.ImGui_BeginDisabled(ctx, true)
    end
    if reaper.ImGui_RadioButton(ctx, has_stored and "Last used" or "Last used (none yet)",
      state.colour_mode == "last") then
      state.colour_mode = "last"
    end
    if greyed then
      reaper.ImGui_EndDisabled(ctx)
    end

    local swatch = pick_colour()
    if swatch then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_ColorButton(ctx, "##colour", imgui_colour(swatch), 0, 24, 24)
    end
  end

  -- Fields stacked, the way the single window has always had them.
  local function draw_fields_narrow(ctx, SB)
    local _

    SB.section(ctx, "Syntax")

    -- the two name fields together, then the numbering row, then the command:
    -- cue name and sequence name are the pair the user edits as one thought
    reaper.ImGui_SetNextItemWidth(ctx, 360)
    _, state.cue_name = reaper.ImGui_InputText(ctx, "Cue name", state.cue_name)

    reaper.ImGui_SetNextItemWidth(ctx, 360)
    _, state.sequence_name = reaper.ImGui_InputText(ctx, "Sequence name", state.sequence_name)

    draw_number_row(ctx)

    local command_items, command_index, command_list = command_choices(state.command_name)
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    local command_changed, chosen = reaper.ImGui_Combo(ctx, "Command", command_index, command_items)
    if command_changed and command_list[chosen + 1] then
      state.command_name = command_list[chosen + 1]
    end

    SB.label(ctx, "Empty field leaves that element out. MarkerName = the name of the first selected marker.")

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Colour")

    draw_colour_controls(ctx, SB)
  end

  -- Three rows across the full width of the docker: the pair of names, the
  -- numbering, then the command with the colour controls beside it. Same
  -- fields, same widths, fewer rows -- a docked strip is 400 px tall and every
  -- row it does not need is a row the reference lines can have.
  local function draw_fields_wide(ctx, SB)
    local _

    reaper.ImGui_SetNextItemWidth(ctx, 360)
    _, state.cue_name = reaper.ImGui_InputText(ctx, "Cue name", state.cue_name)

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 360)
    _, state.sequence_name = reaper.ImGui_InputText(ctx, "Sequence name", state.sequence_name)

    draw_number_row(ctx)

    local command_items, command_index, command_list = command_choices(state.command_name)
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    local command_changed, chosen = reaper.ImGui_Combo(ctx, "Command", command_index, command_items)
    if command_changed and command_list[chosen + 1] then
      state.command_name = command_list[chosen + 1]
    end

    reaper.ImGui_SameLine(ctx)
    draw_colour_controls(ctx, SB)
  end

  local function draw_reference(ctx, SB, wide)
    SB.section(ctx, "Reference")

    if not wide then
      imgui_text_wrapped(ctx, "One sequence is generated per marker colour. The default colour (red) is the main cue list.")
      for _, line in ipairs(REFERENCE_LINES) do
        SB.label(ctx, line)
      end
      return
    end

    -- Wide: two columns, because eight rows of legend is most of a 450 px
    -- docker and the width is there for free. Below TWO_COLUMN_MIN_WIDTH the
    -- long first line would run into the second column, so it stays single.
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local half = math.ceil(#REFERENCE_LINES / 2)

    if type(avail) ~= "number" or avail < TWO_COLUMN_MIN_WIDTH then
      for _, line in ipairs(REFERENCE_LINES) do
        SB.label(ctx, line)
      end
      return
    end

    local column_x = math.floor(avail / 2)
    local start_x = reaper.ImGui_GetCursorPosX(ctx) or 0

    for index = 1, half do
      SB.label(ctx, REFERENCE_LINES[index])

      local right = REFERENCE_LINES[index + half]
      if right then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetCursorPosX(ctx, start_x + column_x)
        SB.label(ctx, right)
      end
    end
  end

  -- Draws the panel into a frame the host has already opened. Returns true when
  -- the host's own "Close" button was pressed (only drawn when it asks for it).
  --
  --   opts.wide            fields side by side instead of stacked
  --   opts.show_selection  the "N markers selected" block -- the workspace
  --                        already says that in its header band
  --   opts.show_reference  the legend; the workspace hides it when the docker
  --                        is too short for it
  --   opts.show_close      draw a Close button after Reset
  local function frame(ctx, SB, opts)
    opts = opts or {}

    local close_requested = false

    local entries, _, source = selection()
    local selected_count = #entries
    -- the same marker the run will take its name from, so the preview cannot
    -- show one thing and the rename write another
    local template = template_for(entries, source)
    local preview_name = build_marker_name(template and template.name or "MarkerName", 0)

    if opts.show_selection then
      draw_selection(ctx, SB, selected_count, source)
      reaper.ImGui_Separator(ctx)
    end

    if opts.wide then
      draw_fields_wide(ctx, SB)
      draw_preview(ctx, SB, preview_name)
    else
      draw_preview(ctx, SB, preview_name)
      reaper.ImGui_Separator(ctx)
      draw_fields_narrow(ctx, SB)
    end

    if opts.show_reference then
      reaper.ImGui_Separator(ctx)
      draw_reference(ctx, SB, opts.wide)
    end

    reaper.ImGui_Separator(ctx)

    if SB.primary_button(ctx, "Rename selected markers", 260, 30) then
      pending = function() run_rename(entries, source) end
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Reset to defaults", 150, 30) then
      reset_to_defaults()
    end

    if opts.show_close then
      reaper.ImGui_SameLine(ctx)
      if SB.button(ctx, "Close", 110, 30) then
        close_requested = true
      end
    end

    return close_requested
  end

  -- Outside the frame: safe to touch the project. The host calls this after
  -- its end_window, never inside the frame.
  local function after_frame()
    if not pending then
      return
    end

    local action = pending
    pending = nil
    action()
  end

  -- What the host puts in its footer. "Ready." rather than an empty strip, the
  -- way the single window has always shown it.
  local function status()
    return status_message ~= "" and status_message or "Ready.", status_kind
  end

  -- Test hook: lets the naming and colour logic run outside REAPER. Exactly the
  -- thirteen names "Rename selected markers.lua" used to export itself --
  -- tests/rename_test.lua is unchanged and is the proof that the logic below
  -- was moved, not rewritten.
  local function test_hook()
    return {
      DEFAULTS = DEFAULTS,
      COMMANDS = COMMANDS,
      command_choices = command_choices,
      get_state = get_state,
      set_state = set_state,
      reset_to_defaults = reset_to_defaults,
      base_name = base_name,
      build_marker_name = build_marker_name,
      prefill_from = prefill_from,
      prefill_from_selection = prefill_from_selection,
      template_for = template_for,
      pick_colour = pick_colour,
      next_random_colour = next_random_colour,
      run_rename = run_rename,
      last_status = last_status,
    }
  end

  return {
    frame = frame,
    after_frame = after_frame,
    status = status,
    run_fallback = run_fallback,
    test_hook = test_hook,
  }
end

return M
