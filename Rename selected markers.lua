-- Rename selected markers
-- Renames markers selected in REAPER's Region/Marker Manager.
-- Regions are ignored.

local SCRIPT_TITLE = "Rename selected markers"

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

local cue_name = "MarkerName"
local use_cue_number = true
local cue_number = "1"
local create_multiple_cues = false
local multiple_cue_count = 1
local use_command = true
local command_name = "Top"
local use_sequence_name = true
local sequence_name = "MarkerName"
local sequence_follows_cue_name = true
local status_message = ""

local function destroy_imgui_context(ctx)
  if ctx and reaper.APIExists and reaper.APIExists("ImGui_DestroyContext") then
    reaper.ImGui_DestroyContext(ctx)
  end
end

local function imgui_text_wrapped(ctx, text)
  if reaper.APIExists and reaper.APIExists("ImGui_TextWrapped") then
    reaper.ImGui_TextWrapped(ctx, text)
  else
    reaper.ImGui_Text(ctx, text)
  end
end

local function get_app_version()
  local version = reaper.GetAppVersion and reaper.GetAppVersion() or "0"
  local major_minor = version:match("^(%d+%.%d+)")
  return tonumber(major_minor) or 0
end

local function save_marker_entry(entries, enum_index)
  local ok, is_region, pos, region_end, name, marker_id, color = reaper.EnumProjectMarkers3(0, enum_index)

  if ok >= 1 and not is_region then
    entries[#entries + 1] = {
      enum_index = enum_index,
      id = marker_id,
      pos = pos,
      region_end = region_end,
      name = name,
      color = color,
    }
  end
end

local function collect_selected_markers_from_region_api()
  local entries = {}

  if not (
    reaper.GetNumRegionsOrMarkers and
    reaper.GetRegionOrMarker and
    reaper.GetRegionOrMarkerInfo_Value and
    reaper.EnumProjectMarkers3
  ) then
    return entries
  end

  local count = reaper.GetNumRegionsOrMarkers(0)

  for region_marker_index = 0, count - 1 do
    local region_marker = reaper.GetRegionOrMarker(0, region_marker_index, "")
    if region_marker then
      local is_region = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "B_ISREGION") == 1
      local is_selected = reaper.GetRegionOrMarkerInfo_Value(0, region_marker, "B_UISEL") == 1

      if not is_region and is_selected then
        save_marker_entry(entries, region_marker_index)
      end
    end
  end

  return entries
end

local function collect_markers_by_id()
  local markers_by_id = {}
  local index = 0

  while true do
    local ok, is_region, pos, region_end, name, marker_id, color = reaper.EnumProjectMarkers3(0, index)
    if ok == 0 then
      break
    end

    if not is_region then
      markers_by_id[marker_id] = {
        enum_index = index,
        id = marker_id,
        pos = pos,
        region_end = region_end,
        name = name,
        color = color,
      }
    end

    index = index + 1
  end

  return markers_by_id
end

local function get_marker_manager_window()
  if not (
    reaper.JS_Localize and
    reaper.JS_Window_ArrayFind and
    reaper.JS_Window_HandleFromAddress and
    reaper.JS_Window_FindChildByID and
    reaper.new_array
  ) then
    return nil
  end

  local title = reaper.JS_Localize("Region/Marker Manager", "common")
  local addresses = reaper.new_array({}, 1024)
  reaper.JS_Window_ArrayFind(title, true, addresses)

  for _, address in ipairs(addresses.table()) do
    local hwnd = reaper.JS_Window_HandleFromAddress(address)
    if hwnd and reaper.JS_Window_FindChildByID(hwnd, 1056) then
      return hwnd
    end
  end

  return nil
end

local function collect_selected_markers_from_manager_window()
  local entries = {}

  if not (reaper.JS_Window_FindChildByID and reaper.JS_ListView_ListAllSelItems and reaper.JS_ListView_GetItemText) then
    return entries
  end

  local manager_window = get_marker_manager_window()
  if not manager_window then
    return entries
  end

  local list_view = reaper.JS_Window_FindChildByID(manager_window, 1071)
  if not list_view then
    return entries
  end

  local markers_by_id = collect_markers_by_id()
  local selected_count, selected_indexes = reaper.JS_ListView_ListAllSelItems(list_view)
  if selected_count == 0 then
    return entries
  end

  local selection_order = 0
  for selected_index in string.gmatch(selected_indexes, "[^,]+") do
    local type_and_id = reaper.JS_ListView_GetItemText(list_view, tonumber(selected_index), 1)
    if type_and_id and type_and_id:find("M") then
      local marker_id = tonumber(type_and_id:match("%d+"))
      if marker_id and markers_by_id[marker_id] then
        local entry = markers_by_id[marker_id]
        selection_order = selection_order + 1
        entry.selection_order = selection_order
        entries[#entries + 1] = entry
      end
    end
  end

  return entries
end

local function collect_selected_markers()
  local manager_entries = collect_selected_markers_from_manager_window()
  if #manager_entries > 0 then
    return manager_entries
  end

  if get_app_version() >= 7.62 then
    return collect_selected_markers_from_region_api()
  end

  return {}
end

local function resolve_marker_name_placeholder(text, source_marker_name)
  if text == "" or text == "MarkerName" then
    return source_marker_name or ""
  end

  return (text:gsub("MarkerName", function()
    return source_marker_name or ""
  end))
end

local function parse_cue_number()
  local number = tonumber(cue_number)
  if number then
    return number
  end

  return 1
end

local function format_cue_number(number)
  if math.floor(number) == number then
    return tostring(math.floor(number))
  end

  return tostring(number)
end

local function get_cue_number_for_marker(marker_offset)
  if not create_multiple_cues then
    return cue_number
  end

  local cue_count = math.max(1, math.floor(tonumber(multiple_cue_count) or 1))
  local offset = marker_offset or 0
  local number_offset = offset % cue_count

  return format_cue_number(parse_cue_number() + number_offset)
end

local function build_marker_name(source_marker_name, marker_offset)
  local resolved_cue_name = resolve_marker_name_placeholder(cue_name, source_marker_name)
  local resolved_sequence_name = sequence_follows_cue_name
    and resolved_cue_name
    or resolve_marker_name_placeholder(sequence_name, source_marker_name)
  local marker_cue_number = get_cue_number_for_marker(marker_offset)

  local marker_name = resolved_cue_name

  if use_cue_number and marker_cue_number ~= "" then
    marker_name = marker_name .. "(" .. marker_cue_number .. ")"
  end

  if use_command and command_name ~= "" then
    marker_name = marker_name .. "[" .. command_name .. "]"
  end

  if use_sequence_name and resolved_sequence_name ~= "" then
    marker_name = marker_name .. "^" .. resolved_sequence_name .. "^"
  end

  return marker_name
end

local function rename_selected_markers()
  local selected_markers = collect_selected_markers()
  if #selected_markers == 0 then
    status_message = "No selected markers found."
    return
  end

  local preview_name = build_marker_name(selected_markers[1].name, 0)
  if preview_name == "" then
    status_message = "Enter at least a name or one syntax element."
    return
  end

  table.sort(selected_markers, function(left, right)
    if left.selection_order and right.selection_order then
      return left.selection_order < right.selection_order
    end

    if left.pos == right.pos then
      return left.id < right.id
    end
    return left.pos < right.pos
  end)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for index, marker in ipairs(selected_markers) do
    local new_name = build_marker_name(marker.name, index - 1)
    local clear_name = new_name == "" and 1 or 0
    reaper.SetProjectMarker4(0, marker.id, false, marker.pos, 0, new_name, marker.color, clear_name)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateTimeline()
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Rename selected markers", -1)

  status_message = tostring(#selected_markers) .. " markers renamed."
end

local function run_fallback()
  local selected_markers = collect_selected_markers()
  if #selected_markers == 0 then
    reaper.ShowMessageBox(
      "No selected markers found.\n\nSelect markers in the Region/Marker Manager and run the script again.",
      SCRIPT_TITLE,
      0
    )
    return
  end

  local ok, values = reaper.GetUserInputs(
    SCRIPT_TITLE,
    7,
    "Cuename,CueNumber,Cmd,SequName,SequName nutzen? y/n,Multiple? y/n,How many cues",
    cue_name .. "," .. cue_number .. "," .. command_name .. "," .. sequence_name .. ",y,n,1"
  )

  if not ok then
    return
  end

  local name_text, number_text, command_text, sequence_text, use_sequence_text, multiple_text, count_text =
    values:match("([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)")
  cue_name = name_text or ""
  cue_number = number_text or ""
  command_name = command_text or ""
  sequence_name = sequence_text or cue_name
  use_cue_number = cue_number ~= ""
  use_command = command_name ~= ""
  use_sequence_name = (use_sequence_text or ""):lower():sub(1, 1) == "y"
  create_multiple_cues = (multiple_text or ""):lower():sub(1, 1) == "y"
  multiple_cue_count = math.max(1, math.floor(tonumber(count_text) or 1))
  sequence_follows_cue_name = false

  rename_selected_markers()
  if status_message ~= "" then
    reaper.ShowMessageBox(status_message, SCRIPT_TITLE, 0)
  end
end

local function run_gui(SB)
  local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

  local function loop()
    local close_window = false

    if sequence_follows_cue_name then
      sequence_name = cue_name
    end

    -- read once per frame: this walks the manager's list view
    local selected_markers = collect_selected_markers()
    local selected_count = #selected_markers
    local preview_source_name = selected_markers[1] and selected_markers[1].name or "MarkerName"
    local preview_name = build_marker_name(preview_source_name, 0)

    local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 620)

    if visible then
      SB.section(ctx, "Selection")

      if selected_count > 0 then
        reaper.ImGui_TextColored(ctx, SB.color.blue_text, tostring(selected_count) ..
          (selected_count == 1 and " marker selected" or " markers selected"))
      else
        reaper.ImGui_TextColored(ctx, SB.color.text_muted, "Select markers in the Region/Marker Manager.")
      end

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Preview")

      reaper.ImGui_SetNextItemWidth(ctx, 460)
      if reaper.APIExists and reaper.APIExists("ImGui_InputTextFlags_ReadOnly") then
        local _
        _, preview_name = reaper.ImGui_InputText(
          ctx,
          "##preview",
          preview_name,
          reaper.ImGui_InputTextFlags_ReadOnly()
        )
      else
        reaper.ImGui_Text(ctx, preview_name)
      end

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Syntax")

      reaper.ImGui_SetNextItemWidth(ctx, 360)
      local _
      _, cue_name = reaper.ImGui_InputText(ctx, "Cue name", cue_name)

      _, use_cue_number = reaper.ImGui_Checkbox(ctx, "Cue number", use_cue_number)
      if use_cue_number then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 90)
        _, cue_number = reaper.ImGui_InputText(ctx, "##cue_number", cue_number)

        _, create_multiple_cues = reaper.ImGui_Checkbox(
          ctx,
          "Create multiple cues in timeline order",
          create_multiple_cues
        )

        if create_multiple_cues then
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, 90)
          _, multiple_cue_count = reaper.ImGui_InputInt(ctx, "How many cues", multiple_cue_count)
          multiple_cue_count = math.max(1, math.floor(tonumber(multiple_cue_count) or 1))
        end
      end

      _, use_command = reaper.ImGui_Checkbox(ctx, "Command", use_command)
      if use_command then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 120)
        _, command_name = reaper.ImGui_InputText(ctx, "##command_name", command_name)
      end

      _, use_sequence_name = reaper.ImGui_Checkbox(ctx, "Sequence name", use_sequence_name)
      if use_sequence_name then
        _, sequence_follows_cue_name = reaper.ImGui_Checkbox(ctx, "Sequence name = cue name", sequence_follows_cue_name)

        if not sequence_follows_cue_name then
          reaper.ImGui_SetNextItemWidth(ctx, 360)
          _, sequence_name = reaper.ImGui_InputText(ctx, "Sequence", sequence_name)
        end
      end

      reaper.ImGui_Separator(ctx)
      SB.section(ctx, "Reference")

      imgui_text_wrapped(ctx, "One sequence is generated per marker color. The default color (red) is the main cue list.")
      SB.label(ctx, "MarkerName    placeholder for the marker's existing name")
      SB.label(ctx, "Cue name      name of the cue")
      SB.label(ctx, "^Sequence^    name of the sequence, only needed once")
      SB.label(ctx, "(CueNumber)   cue number, for triggering the same cue repeatedly")
      SB.label(ctx, "Multiple      increments the cue number in timeline order")
      SB.label(ctx, "[Cmd]         TC trigger command, e.g. Top, On, Off. Default is Go")
      SB.label(ctx, "Example       BeatFx(1)[Top]^BeatFx^")

      reaper.ImGui_Separator(ctx)

      if SB.primary_button(ctx, "Rename selected markers", 260, 30) then
        rename_selected_markers()
      end

      reaper.ImGui_SameLine(ctx)

      if SB.button(ctx, "Close", 110, 30) then
        close_window = true
      end

      SB.footer(ctx, status_message ~= "" and status_message or "Ready.")
    end

    SB.end_window(ctx, visible, font)

    if open and not close_window then
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
