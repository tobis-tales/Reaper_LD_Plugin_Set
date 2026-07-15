-- Rasterise the mark using the SAME constants the Lua module uses, then compare
-- it against the real logo pixel by pixel. Verifies the shape, not just that
-- the numbers were typed in correctly.

local MARK_RATIO = 1.134
local MARK_BLOCK_W = 0.770
local LENS_CX, LENS_CY, LENS_R = 1.07017, 1.10299, 1.04167
local MARK_PUPIL_X = 0.772
local MARK_PUPIL_Y = 0.499
local MARK_PUPIL_R = 0.227

-- render at the real mark's size so it can be diffed against the source
local H = 545
local W = math.floor(H * MARK_RATIO + 0.5)

-- lens boundary from the fitted circle: x where the arc crosses this row
local function lens_x_at(y_rel)
  if y_rel > 0.5 then y_rel = 1 - y_rel end
  local cx, cy, r = LENS_CX, LENS_CY, LENS_R
  local dy = y_rel - cy
  local under = r * r - dy * dy
  if under < 0 then return 1.0 end
  return (cx - math.sqrt(under)) / MARK_RATIO   -- back to units of WIDTH
end

-- classify our drawing
local function ours(x, y)
  local xr, yr = x / W, y / H
  local in_block = xr <= MARK_BLOCK_W

  local dx = (xr - MARK_PUPIL_X)
  local dy = (yr - MARK_PUPIL_Y) * (H / W)  -- circle is round in pixel space
  local in_pupil = (dx * dx + dy * dy) <= (MARK_PUPIL_R * MARK_PUPIL_R)

  if in_pupil then return "blue" end

  if in_block then
    local lx = lens_x_at(yr)
    if xr >= lx then return "bg" end
    return "grey"
  end

  return "bg"
end

-- the real logo
local f = assert(io.open("/tmp/logo_cmyk.raw", "rb"))
local data = f:read("a")
f:close()
local SRC_W = 2303

local function theirs(x, y)
  local i = ((y * SRC_W) + x) * 3 + 1
  local r, g, b = data:byte(i), data:byte(i + 1), data:byte(i + 2)
  if b > r + 30 and b > 100 and g > r then return "blue" end
  if math.abs(r - 102) < 40 and math.abs(g - 102) < 40 and math.abs(b - 102) < 40 then return "grey" end
  if r > 200 and g > 200 and b > 200 then return "bg" end
  return "edge"   -- antialiased pixel, don't judge
end

local match, differ, skipped = 0, 0, 0
local diff_map = {}

for y = 0, H - 1 do
  for x = 0, W - 1 do
    local t = theirs(x, y)
    if t == "edge" then
      skipped = skipped + 1
    else
      local o = ours(x, y)
      if o == t then
        match = match + 1
      else
        differ = differ + 1
        diff_map[#diff_map + 1] = { x = x, y = y, ours = o, theirs = t }
      end
    end
  end
end

local total = match + differ
print(string.format("compared %d solid pixels (%d antialiased edge pixels skipped)", total, skipped))
print(string.format("  match:  %d (%.2f%%)", match, match / total * 100))
print(string.format("  differ: %d (%.2f%%)", differ, differ / total * 100))

-- where are the differences?
if differ > 0 then
  local kinds = {}
  for _, d in ipairs(diff_map) do
    local k = d.theirs .. " -> drawn as " .. d.ours
    kinds[k] = (kinds[k] or 0) + 1
  end
  print("\nmismatch breakdown:")
  for k, v in pairs(kinds) do
    print(string.format("  %-28s %6d px (%.2f%% of total)", k, v, v / total * 100))
  end
end

-- ASCII preview, ours vs theirs
print("\nours (left) vs real logo (right):")
for row = 0, 20 do
  local y = math.floor(row / 20 * (H - 1))
  local a, b = "", ""
  for col = 0, 34 do
    local x = math.floor(col / 34 * (W - 1))
    local o = ours(x, y)
    a = a .. (o == "grey" and "#" or o == "blue" and "O" or ".")
    local t = theirs(x, y)
    b = b .. (t == "grey" and "#" or t == "blue" and "O" or t == "bg" and "." or "+")
  end
  print("  " .. a .. "   " .. b)
end

os.exit(differ / total < 0.02 and 0 or 1)
