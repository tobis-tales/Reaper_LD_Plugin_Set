-- Measure the real geometry of the logo's picture mark, so it can be redrawn
-- in correct proportion instead of squashed into a square.

local W, H = 2303, 546

local f = assert(io.open("/tmp/logo_cmyk.raw", "rb"))
local data = f:read("a")
f:close()

local function px(x, y)
  local i = ((y * W) + x) * 3 + 1
  return data:byte(i), data:byte(i + 1), data:byte(i + 2)
end

local function is_grey(r, g, b)
  return math.abs(r - 102) < 30 and math.abs(g - 102) < 30 and math.abs(b - 102) < 30
end

local function is_blue(r, g, b)
  return b > r + 30 and b > 100 and g > r
end

-- the mark lives in the left part, before the wordmark starts
local SCAN_MAX = 640

local grey = { x0 = math.huge, x1 = -1, y0 = math.huge, y1 = -1 }
local blue = { x0 = math.huge, x1 = -1, y0 = math.huge, y1 = -1 }

for y = 0, H - 1 do
  for x = 0, SCAN_MAX do
    local r, g, b = px(x, y)
    if is_grey(r, g, b) then
      grey.x0 = math.min(grey.x0, x); grey.x1 = math.max(grey.x1, x)
      grey.y0 = math.min(grey.y0, y); grey.y1 = math.max(grey.y1, y)
    elseif is_blue(r, g, b) then
      blue.x0 = math.min(blue.x0, x); blue.x1 = math.max(blue.x1, x)
      blue.y0 = math.min(blue.y0, y); blue.y1 = math.max(blue.y1, y)
    end
  end
end

local gw, gh = grey.x1 - grey.x0 + 1, grey.y1 - grey.y0 + 1
local bw, bh = blue.x1 - blue.x0 + 1, blue.y1 - blue.y0 + 1

print("=== grey block ===")
print(string.format("  x %d..%d  y %d..%d   -> %d x %d px   ratio w/h = %.3f",
  grey.x0, grey.x1, grey.y0, grey.y1, gw, gh, gw / gh))

print("=== blue circle ===")
print(string.format("  x %d..%d  y %d..%d   -> %d x %d px   center (%.1f, %.1f)  r = %.1f",
  blue.x0, blue.x1, blue.y0, blue.y1, bw, bh,
  (blue.x0 + blue.x1) / 2, (blue.y0 + blue.y1) / 2, (bw + bh) / 4))

-- whole mark = union
local mx0 = math.min(grey.x0, blue.x0)
local mx1 = math.max(grey.x1, blue.x1)
local my0 = math.min(grey.y0, blue.y0)
local my1 = math.max(grey.y1, blue.y1)
local mw, mh = mx1 - mx0 + 1, my1 - my0 + 1

print("=== whole mark (block + circle) ===")
print(string.format("  %d x %d px   ratio w/h = %.3f", mw, mh, mw / mh))

print("\n=== relative to the mark box (this is what the drawing code needs) ===")
print(string.format("  block:  x %.3f..%.3f   y %.3f..%.3f  of mark w/h",
  (grey.x0 - mx0) / mw, (grey.x1 - mx0) / mw, (grey.y0 - my0) / mh, (grey.y1 - my0) / mh))
print(string.format("  circle: center x %.3f  y %.3f   radius %.3f (of mark WIDTH)",
  ((blue.x0 + blue.x1) / 2 - mx0) / mw, ((blue.y0 + blue.y1) / 2 - my0) / mh,
  ((bw + bh) / 4) / mw))

-- the lens: for a few rows, where does the white opening start inside the block?
print("\n=== lens opening (white inside the block), per row ===")
for _, frac in ipairs({ 0.02, 0.15, 0.3, 0.5, 0.7, 0.85, 0.98 }) do
  local y = math.floor(my0 + frac * (mh - 1))
  local first_white = nil
  for x = grey.x0, grey.x1 do
    local r, g, b = px(x, y)
    if r > 200 and g > 200 and b > 200 then first_white = x break end
  end
  if first_white then
    print(string.format("  y %.0f%%: white starts at x %.3f of mark width", frac * 100,
      (first_white - mx0) / mw))
  else
    print(string.format("  y %.0f%%: no opening (solid block)", frac * 100))
  end
end
