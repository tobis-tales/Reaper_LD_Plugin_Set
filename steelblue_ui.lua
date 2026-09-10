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


-- ------------------------------------------------- the docked workspace (v2)
--
-- Everything below serves steelblue_workspace.lua, the one window that will
-- hold the plugins as tabs. The four single-script plugins keep using
-- begin_window/header above, unchanged.

-- Width of a string in the CURRENT font, or nil when the build cannot say.
-- Used only to place drawn decoration, never to size a window.
local function text_width(ctx, text)
  if not reaper.ImGui_CalcTextSize then
    return nil
  end

  local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx, text)
  if ok and type(w) == "number" then
    return w
  end

  return nil
end

-- Like begin_window, but for a window that lives in one of REAPER's dockers.
--
-- Three differences, all of them consequences of the docker owning the size:
--   * no AlwaysAutoResize and no size constraints -- a docked window fills the
--     docker, and asking it to hug its content fights that;
--   * no header -- the workspace draws its own, richer band with header_bar;
--   * opts.dock_now asks for the docker BEFORE Begin.
--
-- The dock request uses Cond_Always on purpose. Probe 2026-09-11 (REAPER 7.79,
-- tests/probe_dock.lua) showed the placement is not persistent: after a REAPER
-- restart the window comes back floating even though Cond_FirstUseEver was set
-- on every start. So the caller asks again on the first frame of every run --
-- and remembers it when the user pulls the window out on purpose, because
-- Cond_Always would otherwise drag it straight back.
--
-- end_window is the same function as for every other window.
function SB.begin_dock_window(ctx, title, opts)
  opts = opts or {}

  SB.attach_font(ctx)
  SB.push_theme(ctx)

  if opts.dock_now and reaper.ImGui_SetNextWindowDockID and reaper.ImGui_Cond_Always then
    reaper.ImGui_SetNextWindowDockID(ctx, opts.dock_id or -1, reaper.ImGui_Cond_Always())
  end

  local visible, open = reaper.ImGui_Begin(ctx, title, true, 0)

  local font_pushed = false
  if visible then
    font_pushed = SB.push_font(ctx, SB.size.body)
  end

  return visible, open, font_pushed
end

-- The workspace's brand band: mark, wordmark, and two callbacks that may hang
-- real items into it -- the BPM block on the left, the selection read-out on
-- the right.
--
-- Mark and wordmark are DRAWN, not submitted, exactly as in SB.header:
-- decoration must never drive layout. The callbacks are different -- they are
-- allowed to submit items, and right-aligning inside them is fine here because
-- a docked window has a width the docker decides, not one its content decides.
--
-- The band reserves its height once, with a Dummy of width 1, after the cursor
-- has been put back where it started. It reaches `height` below the cursor and
-- up into the window padding above it, so on screen it is that bit taller --
-- same construction as SB.header.
function SB.header_bar(ctx, opts)
  opts = opts or {}

  local height = opts.height or 40
  local pad = SB.WINDOW_PADDING
  local rule = 2

  local lx, ly = reaper.ImGui_GetCursorPos(ctx)
  lx, ly = lx or 0, ly or 0

  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width = reaper.ImGui_GetContentRegionAvail(ctx) or 0
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  local band_top = y - pad
  local band_bottom = y + height - rule
  local band_mid = (band_top + band_bottom) / 2

  local mark_h = 22
  local mark_w = mark_h * MARK_RATIO
  local gap = 10

  if dl then
    reaper.ImGui_DrawList_AddRectFilled(dl, x - pad, band_top, x + width + pad, y + height, C.header_bg)
    reaper.ImGui_DrawList_AddRectFilled(dl, x - pad, band_bottom, x + width + pad, y + height, C.blue)

    SB.logo_mark(ctx, x, band_mid - (mark_h / 2), mark_h)

    local sub = 9
    local text_h = SB.size.body + sub
    local text_top = band_mid - (text_h / 2)
    SB.draw_text(ctx, dl, x + mark_w + gap, text_top, C.text, "steelblue", SB.size.body)
    SB.draw_text(ctx, dl, x + mark_w + gap, text_top + SB.size.body, C.text_muted, "LD TOOLS", sub)
  end

  -- Centre one row of ordinary items on the band instead of nudging them by
  -- hand, so nothing drifts if the band or the font size changes.
  local frame_h = 23
  if reaper.ImGui_GetFrameHeight then
    local ok, h = pcall(reaper.ImGui_GetFrameHeight, ctx)
    if ok and type(h) == "number" and h > 0 then
      frame_h = h
    end
  end
  local row_y = ly + math.max(0, ((height - rule) - frame_h) / 2)

  if opts.left then
    local wordmark = text_width(ctx, "steelblue") or 60
    reaper.ImGui_SetCursorPos(ctx, lx + mark_w + gap + wordmark + 24, row_y)
    opts.left(ctx)
  end

  if opts.right then
    reaper.ImGui_SetCursorPos(ctx, lx, row_y)
    opts.right(ctx)
  end

  reaper.ImGui_SetCursorPos(ctx, lx, ly)
  reaper.ImGui_Dummy(ctx, 1, height)
end

-- Which tab id the tab bar reported last frame, per context. See `force` below.
local tab_reported = setmetatable({}, { __mode = "k" })

local TAB_PAD = 8       -- matches StyleVar_FramePadding.x in THEME_VARS
local TAB_UNDERLINE = 2

-- The tab strip. tabs = { { id = "rename", label = "...", hint = "Cmd+..." } }
-- Returns the id of the tab that is now active -- the clicked one, or the id
-- that went in.
--
-- Two things are drawn rather than submitted, for the usual reason:
--   * the shortcut hint. A tab item takes ONE label string, so it cannot carry
--     two colours; the hint gets its width reserved with trailing blanks and is
--     then painted into that gap in the muted colour. Blanks, so there is
--     nothing to paint over -- the tab's own background keeps working, hovered
--     and selected alike.
--   * the blue underline. Dear ImGui 1.92 marks the selected tab with an
--     OVERline (Col_TabSelectedOverline, on the top edge); the mockup has a
--     line underneath, so that one is switched off and ours is drawn.
function SB.tab_bar(ctx, tabs, active_id)
  local new_active = active_id

  if not reaper.ImGui_BeginTabBar or not tabs or #tabs == 0 then
    return new_active
  end

  -- The caller can move the active tab behind ImGui's back: restored from
  -- ExtState on the first frame, or asked for by another script. ImGui owns
  -- the selection the rest of the time, so force it only when the two have
  -- actually drifted apart -- forcing every frame would nail the strip to one
  -- tab and swallow every click.
  local force = tab_reported[ctx] ~= active_id

  local colors = {
    { "Tab", C.window_bg },
    { "TabHovered", C.header_bg },
    { "TabSelected", C.window_bg },
    { "TabSelectedOverline", C.window_bg },
  }

  local pushed_colors = 0
  for _, entry in ipairs(colors) do
    local id = col_id(entry[1])
    if id then
      reaper.ImGui_PushStyleColor(ctx, id, entry[2])
      pushed_colors = pushed_colors + 1
    end
  end

  local overline_var = var_id("TabBarOverlineSize")
  if overline_var then
    reaper.ImGui_PushStyleVar(ctx, overline_var, 0)
  end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local space_w = text_width(ctx, " ")
  local hint_scale = SB.size.small / SB.size.body

  if reaper.ImGui_BeginTabBar(ctx, "steelblue_workspace_tabs") then
    for _, tab in ipairs(tabs) do
      local label = tab.label
      local hint = tab.hint
      local hint_w = nil

      if hint and hint ~= "" then
        local measured = text_width(ctx, hint)
        if measured and space_w and space_w > 0 then
          hint_w = measured * hint_scale
          label = label .. "  " .. string.rep(" ", math.ceil(measured / space_w))
        else
          -- No text measurement on this build: show the hint plainly rather
          -- than losing it into a gap that cannot be placed.
          label = label .. "  " .. hint
          hint = nil
        end
      end

      local is_active = tab.id == active_id
      local text_col = col_id("Text")
      if text_col then
        reaper.ImGui_PushStyleColor(ctx, text_col, is_active and C.text or C.text_dim)
      end

      local flags = 0
      if force and is_active and reaper.ImGui_TabItemFlags_SetSelected then
        flags = reaper.ImGui_TabItemFlags_SetSelected()
      end

      local selected = reaper.ImGui_BeginTabItem(ctx, label, nil, flags)

      -- Read the rect straight away: anything submitted inside the tab item
      -- would become "the last item" instead.
      local x1, y1, x2, y2
      if reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax then
        x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
        x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
      end

      if selected then
        new_active = tab.id
        reaper.ImGui_EndTabItem(ctx)
      end

      if text_col then
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      if dl and x1 and y1 and x2 and y2 then
        if hint and hint_w then
          SB.draw_text(ctx, dl, x2 - TAB_PAD - hint_w,
            (y1 + y2 - SB.size.small) / 2, C.text_muted, hint, SB.size.small)
        end

        if selected then
          reaper.ImGui_DrawList_AddRectFilled(dl, x1, y2 - TAB_UNDERLINE, x2, y2, C.blue)
        end
      end
    end

    -- Only a strip that actually ran has reported anything. Recording the id
    -- when BeginTabBar said no would clear `force` without a single tab having
    -- been drawn -- and the restored tab would never be applied.
    tab_reported[ctx] = new_active
    reaper.ImGui_EndTabBar(ctx)
  end

  if overline_var then
    reaper.ImGui_PopStyleVar(ctx, 1)
  end
  if pushed_colors > 0 then
    reaper.ImGui_PopStyleColor(ctx, pushed_colors)
  end

  return new_active
end

return SB
