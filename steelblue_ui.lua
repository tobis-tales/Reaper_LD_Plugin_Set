-- steelblue_ui.lua
-- Shared UI theme for the steelblue studios REAPER plugin package.
--
-- Usage from a script in the same folder:
--   local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
--   local SB = dofile(folder .. "steelblue_ui.lua")
--
-- Every plugin in the package draws through this module so they stay visually
-- identical, and so a new plugin inherits the look for free.
--
-- Requires ReaImGui. Written against the 0.10 API (Dear ImGui 1.92, dynamic
-- fonts): ImGui_PushFont takes (ctx, font, size). Font creation is guarded, so
-- an older/newer build degrades to the default font instead of erroring.

local SB = {}

SB.VERSION = "1.0"

-- Brand palette, sampled from steelblue_final_rgb_black.blue.eps.
-- The logo's blue is CSS "steelblue" -- the company name is its own hex value.
-- (The EPS preview dithers the circle across four palette entries; #4682B4 is
-- the area mean, not a single-pixel reading.)
SB.BRAND_BLUE = 0x4682B4
SB.BRAND_GREY = 0x666666

-- ImGui wants 0xRRGGBBAA.
local C = {
  blue         = 0x4682B4FF,
  blue_hover   = 0x5A93C2FF,
  blue_active  = 0x3A6E99FF,
  blue_faint   = 0x1F3D57FF,
  blue_text    = 0x8FC0E8FF,
  grey         = 0x666666FF,

  window_bg    = 0x232326FF,
  header_bg    = 0x2C2C30FF,
  footer_bg    = 0x1E1E20FF,
  frame_bg     = 0x1A1A1CFF,
  frame_hover  = 0x242428FF,
  border       = 0x3C3C40FF,

  text         = 0xE8E8EAFF,
  text_dim     = 0x9A9AA0FF,
  text_muted   = 0x75757CFF,

  button       = 0x2C2C30FF,
  button_hover = 0x3A3A40FF,
  button_active = 0x46464CFF,

  warning      = 0xE0A030FF,
  danger       = 0xD9534FFF,
  success      = 0x5CB85CFF,
}

SB.color = C

SB.size = {
  small = 11,
  body = 13,
  section = 11,
  display = 30,
}

-- Kept in sync with the WindowPadding style var below. The header needs it to
-- know where the window's top edge is, since its band is drawn back into the
-- padding above the cursor.
SB.WINDOW_PADDING = 12

-- ---------------------------------------------------------------- internals

-- Col_/StyleVar_ enums vary between ReaImGui builds; skip anything missing
-- rather than erroring on a style that is merely cosmetic.
local function col_id(name)
  local fn = reaper["ImGui_Col_" .. name]
  return fn and fn() or nil
end

local function var_id(name)
  local fn = reaper["ImGui_StyleVar_" .. name]
  return fn and fn() or nil
end

local pushed = setmetatable({}, { __mode = "k" })

local THEME_COLORS = {
  { "WindowBg", C.window_bg },
  { "ChildBg", C.window_bg },
  { "PopupBg", C.header_bg },
  { "Border", C.border },
  { "Text", C.text },
  { "TextDisabled", C.text_muted },
  { "FrameBg", C.frame_bg },
  { "FrameBgHovered", C.frame_hover },
  { "FrameBgActive", C.frame_hover },
  { "TitleBg", C.header_bg },
  { "TitleBgActive", C.header_bg },
  { "TitleBgCollapsed", C.header_bg },
  { "Button", C.button },
  { "ButtonHovered", C.button_hover },
  { "ButtonActive", C.button_active },
  { "CheckMark", C.blue },
  { "SliderGrab", C.blue },
  { "SliderGrabActive", C.blue_hover },
  { "Header", C.blue_faint },
  { "HeaderHovered", C.blue_faint },
  { "HeaderActive", C.blue_faint },
  { "Separator", C.border },
  { "SeparatorHovered", C.blue },
  { "SeparatorActive", C.blue },
  { "ScrollbarBg", C.footer_bg },
  { "ScrollbarGrab", C.button },
  { "ScrollbarGrabHovered", C.button_hover },
  { "ScrollbarGrabActive", C.button_active },
  { "PlotHistogram", C.blue },
  { "PlotHistogramHovered", C.blue_hover },
  { "ResizeGrip", C.border },
  { "ResizeGripHovered", C.blue },
  { "ResizeGripActive", C.blue_hover },
}

local THEME_VARS = {
  { "WindowRounding", 4 },
  { "WindowBorderSize", 1 },
  { "WindowPadding", { SB.WINDOW_PADDING, SB.WINDOW_PADDING } },
  { "FrameRounding", 3 },
  { "FrameBorderSize", 1 },
  { "FramePadding", { 8, 5 } },
  { "ItemSpacing", { 8, 7 } },
  { "ItemInnerSpacing", { 6, 5 } },
  { "GrabRounding", 3 },
  { "ScrollbarRounding", 3 },
  { "ScrollbarSize", 11 },
  { "ChildRounding", 3 },
  { "PopupRounding", 3 },
}

-- ---------------------------------------------------------------- fonts

-- One font object is enough on the 0.10 API: size is chosen at push time.
function SB.attach_font(ctx)
  if SB.font ~= nil then
    return SB.font
  end

  local ok, font = pcall(reaper.ImGui_CreateFont, "sans-serif")
  if not ok or not font then
    -- older signature wanted a size argument
    ok, font = pcall(reaper.ImGui_CreateFont, "sans-serif", SB.size.body)
  end

  if ok and font then
    local attached = pcall(reaper.ImGui_Attach, ctx, font)
    if attached then
      SB.font = font
      return font
    end
  end

  SB.font = false
  return nil
end

function SB.push_font(ctx, size)
  if not SB.font then
    return false
  end

  local ok = pcall(reaper.ImGui_PushFont, ctx, SB.font, size)
  if not ok then
    ok = pcall(reaper.ImGui_PushFont, ctx, SB.font)
  end

  return ok
end

function SB.pop_font(ctx, pushed_ok)
  if pushed_ok then
    pcall(reaper.ImGui_PopFont, ctx)
  end
end

-- ---------------------------------------------------------------- theme

function SB.push_theme(ctx)
  local colors = 0
  for _, entry in ipairs(THEME_COLORS) do
    local id = col_id(entry[1])
    if id then
      reaper.ImGui_PushStyleColor(ctx, id, entry[2])
      colors = colors + 1
    end
  end

  local vars = 0
  for _, entry in ipairs(THEME_VARS) do
    local id = var_id(entry[1])
    if id then
      local value = entry[2]
      if type(value) == "table" then
        reaper.ImGui_PushStyleVar(ctx, id, value[1], value[2])
      else
        reaper.ImGui_PushStyleVar(ctx, id, value)
      end
      vars = vars + 1
    end
  end

  pushed[ctx] = { colors = colors, vars = vars }
end

function SB.pop_theme(ctx)
  local state = pushed[ctx]
  if not state then
    return
  end

  if state.vars > 0 then
    reaper.ImGui_PopStyleVar(ctx, state.vars)
  end
  if state.colors > 0 then
    reaper.ImGui_PopStyleColor(ctx, state.colors)
  end

  pushed[ctx] = nil
end

-- ---------------------------------------------------------------- logo mark

-- The picture mark: grey block with the eye/lens knocked out towards the right
-- and the steel blue pupil sitting in the opening. Drawn rather than shipped as
-- an image so it stays crisp at any size and needs no asset file.
--
-- Every constant below is MEASURED off steelblue_final_cmyk_grey.blue.eps
-- (see measure_mark.lua), not eyeballed. The first version squeezed the mark
-- into a square and it read as squashed: the real mark is 618 x 545, i.e.
-- WIDER than tall. Pass the height; the width follows from the ratio.
local MARK_RATIO = 1.134       -- width / height of the whole mark
local MARK_BLOCK_W = 0.770     -- grey block ends here (of mark width)
local MARK_PUPIL_X = 0.772
local MARK_PUPIL_Y = 0.499
local MARK_PUPIL_R = 0.227     -- of mark WIDTH

-- The lens outline is a CIRCULAR ARC. These come from a least-squares fit over
-- all 219 measured boundary points of the upper half (mean error 0.94 px on a
-- 545 px tall mark) -- see measure_lens.lua.
--
-- Two earlier attempts got this wrong and are worth not repeating: a quadratic
-- bezier cannot follow an arc at all, and a circle fitted through three sample
-- points went through those three points while missing the shape everywhere
-- else. Both errors showed up as the lens opening too wide near the top.
--
-- The key fact both attempts assumed away: the lens does NOT reach the top of
-- the block. It starts at y = 0.08 of the height; above that the block is
-- solid. Units are mark HEIGHT, mirrored about the centre line.
local LENS_CX = 1.07017
local LENS_CY = 1.10299
local LENS_R = 1.04167
local LENS_A_BLOCK = -1.76082  -- where the arc meets the block's right edge
local LENS_A_TIP = -2.52619    -- the tip, on the centre line

function SB.logo_mark(ctx, x, y, height, knockout)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if not dl then
    return 0
  end

  local h = height
  local w = h * MARK_RATIO
  local block_right = x + (MARK_BLOCK_W * w)

  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, block_right, y + h, C.grey)

  -- The lens is the paper showing through in the original, so on a dark header
  -- it has to be knocked out in the header colour, not painted white.
  -- Two mirrored arcs of the same circle, meeting at the tip.
  reaper.ImGui_DrawList_PathClear(dl)
  reaper.ImGui_DrawList_PathArcTo(
    dl,
    x + (LENS_CX * h), y + (LENS_CY * h), LENS_R * h,
    LENS_A_BLOCK, LENS_A_TIP, 24
  )
  reaper.ImGui_DrawList_PathArcTo(
    dl,
    x + (LENS_CX * h), y + ((1 - LENS_CY) * h), LENS_R * h,
    -LENS_A_TIP, -LENS_A_BLOCK, 24
  )
  reaper.ImGui_DrawList_PathFillConvex(dl, knockout or C.header_bg)

  -- the pupil straddles the block's right edge, exactly as in the logo
  reaper.ImGui_DrawList_AddCircleFilled(
    dl,
    x + (MARK_PUPIL_X * w),
    y + (MARK_PUPIL_Y * h),
    MARK_PUPIL_R * w,
    C.blue,
    32
  )

  return w
end

-- ---------------------------------------------------------------- widgets

-- Draw text without submitting an ImGui item, for anything that must not
-- affect the auto-resizing window's layout.
function SB.draw_text(ctx, dl, x, y, color, text, size)
  if SB.font then
    local ok = pcall(reaper.ImGui_DrawList_AddTextEx, dl, SB.font, size, x, y, color, text)
    if ok then
      return
    end
  end

  pcall(reaper.ImGui_DrawList_AddText, dl, x, y, color, text)
end

-- Brand bar: picture mark plus wordmark, closed off by the steel blue rule that
-- ties the whole package together.
--
-- It deliberately does NOT repeat the plugin name: REAPER's own title bar
-- already shows it, expanded and collapsed alike, so printing it again cost
-- 30 px for a duplicate.
--
-- Everything here is drawn straight onto the draw list rather than submitted as
-- ImGui items. In an auto-resizing window an item aligned to the right edge is
-- a feedback loop: its position comes from the current width, the width is then
-- recomputed from the items, and the window creeps smaller every frame.
-- Decoration must not drive layout -- only the Dummy reserving the band's
-- height talks to the layout, and it claims no width.
function SB.header(ctx, _title)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  local pad = SB.WINDOW_PADDING
  local height = 30
  local rule = 2

  -- The visible band runs from the window's top edge down to the blue rule.
  -- Everything is centred on that midpoint rather than nudged by hand, so the
  -- band, the mark and the wordmark cannot drift apart if any of them changes.
  local band_top = y - pad
  local band_bottom = y + height - rule
  local band_mid = (band_top + band_bottom) / 2

  if dl then
    reaper.ImGui_DrawList_AddRectFilled(dl, x - pad, band_top, x + width + pad, y + height, C.header_bg)
    reaper.ImGui_DrawList_AddRectFilled(dl, x - pad, band_bottom, x + width + pad, y + height, C.blue)

    local mark_h = 20
    local mark_w = SB.logo_mark(ctx, x, band_mid - (mark_h / 2), mark_h) or 22

    local sub = 9
    local text_h = SB.size.body + sub
    local text_top = band_mid - (text_h / 2)
    SB.draw_text(ctx, dl, x + mark_w + 10, text_top, C.text, "steelblue", SB.size.body)
    SB.draw_text(ctx, dl, x + mark_w + 10, text_top + SB.size.body, C.text_muted, "STUDIOS", sub)
  end

  reaper.ImGui_Dummy(ctx, 1, height - 6)
end

function SB.section(ctx, label)
  local f = SB.push_font(ctx, SB.size.section)
  reaper.ImGui_TextColored(ctx, C.text_muted, label:upper())
  SB.pop_font(ctx, f)
end

function SB.label(ctx, text)
  reaper.ImGui_TextColored(ctx, C.text_dim, text)
end

-- One accented action per window; everything else stays quiet.
function SB.primary_button(ctx, label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.blue)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.blue_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.blue_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 26)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return clicked
end

function SB.button(ctx, label, w, h)
  return reaper.ImGui_Button(ctx, label, w or 0, h or 26)
end

-- Big read-out for the one number a window exists to show.
function SB.display_value(ctx, value, unit)
  local f = SB.push_font(ctx, SB.size.display)
  reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, value)
  SB.pop_font(ctx, f)

  if unit then
    reaper.ImGui_SameLine(ctx)
    local fu = SB.push_font(ctx, SB.size.small)
    reaper.ImGui_TextColored(ctx, C.text_muted, unit)
    SB.pop_font(ctx, fu)
  end
end

function SB.meter(ctx, fraction, width)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local w = width or reaper.ImGui_GetContentRegionAvail(ctx)
  local h = 5

  if dl then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, C.frame_bg, 3)
    local filled = math.max(0, math.min(1, fraction)) * w
    if filled > 0 then
      reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + filled, y + h, C.blue, 3)
    end
  end

  reaper.ImGui_Dummy(ctx, w, h)
end

function SB.separator(ctx)
  reaper.ImGui_Separator(ctx)
end

-- Status strip closing off the window, so every plugin says what happened in
-- the same place.
--
-- It no longer pads itself down to the bottom edge: the window now hugs its
-- content, so "after the content" already is the bottom. The strip reserves its
-- height with a Dummy of width 1 -- claiming the full width here would let the
-- footer dictate the window width, and the text is drawn, not submitted, for
-- the same reason.
function SB.footer(ctx, text, kind)
  local color = C.text_muted
  if kind == "warning" then
    color = C.warning
  elseif kind == "error" then
    color = C.danger
  elseif kind == "success" then
    color = C.success
  end

  reaper.ImGui_Dummy(ctx, 1, 2)

  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local height = 26

  if dl then
    reaper.ImGui_DrawList_AddRectFilled(dl, x - 12, y, x + width + 12, y + height + 12, C.footer_bg)
    reaper.ImGui_DrawList_AddLine(dl, x - 12, y, x + width + 12, y, C.border)
    SB.draw_text(ctx, dl, x, y + 7, color, text or "", SB.size.small)
  end

  reaper.ImGui_Dummy(ctx, 1, height)
end

-- Single entry point so every plugin opens its window identically.
--
--   local visible, open, font = SB.begin_window(ctx, TITLE, 420)
--   if visible then ... end
--   SB.end_window(ctx, visible, font)   -- ALWAYS, even when not visible
--
-- ReaImGui differs from the C++ API here: End belongs only in the `visible`
-- branch (a collapsed window submits nothing). The style stack, however, must
-- balance every single frame -- so `visible` is handed back to end_window
-- instead of letting callers wrap the whole thing in `if visible`.
--
-- Windows size themselves to their content (AlwaysAutoResize), which is what
-- makes scrollbars structurally impossible rather than a number we keep
-- guessing: every one of these plugins shows and hides rows at runtime
-- (checkboxes revealing fields, the octave hint appearing), so any fixed height
-- is wrong sooner or later. `min_width` only stops the window from collapsing
-- to the width of its longest label.
function SB.begin_window(ctx, title, min_width)
  SB.attach_font(ctx)
  SB.push_theme(ctx)

  if min_width then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, min_width, 0, 8192, 8192)
  end

  local flags = 0
  if reaper.ImGui_WindowFlags_AlwaysAutoResize then
    flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() or 0
  end

  local visible, open = reaper.ImGui_Begin(ctx, title, true, flags)

  local font_pushed = false
  if visible then
    font_pushed = SB.push_font(ctx, SB.size.body)
    SB.header(ctx, title)
  end

  return visible, open, font_pushed
end

function SB.end_window(ctx, visible, font_pushed)
  if visible then
    SB.pop_font(ctx, font_pushed)
    reaper.ImGui_End(ctx)
  end

  SB.pop_theme(ctx)
end

return SB
