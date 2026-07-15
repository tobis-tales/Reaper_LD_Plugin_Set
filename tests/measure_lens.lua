-- Measure the lens boundary on EVERY row, then least-squares fit a circle to
-- all of it. Three sample points were not enough: a circle can pass through
-- three points and still miss the shape everywhere else.

local W, H = 2303, 546
local f = assert(io.open("/tmp/logo_cmyk.raw", "rb"))
local data = f:read("a")
f:close()

local function px(x, y)
  local i = ((y * W) + x) * 3 + 1
  return data:byte(i), data:byte(i + 1), data:byte(i + 2)
end

local BLOCK_X1 = 476   -- measured earlier
local MARK_W, MARK_H = 618, 545

-- for each row: leftmost non-grey pixel inside the block = the lens boundary
local pts = {}
for y = 0, MARK_H - 1 do
  local boundary = nil
  for x = 0, BLOCK_X1 do
    local r, g, b = px(x, y)
    local grey = math.abs(r - 102) < 45 and math.abs(g - 102) < 45 and math.abs(b - 102) < 45
    if not grey then
      -- ignore the pupil: it is drawn on top of the lens
      local dx, dy = x - 477, y - 272
      if (dx * dx + dy * dy) > (145 * 145) then
        boundary = x
        break
      end
    end
  end
  if boundary then
    pts[#pts + 1] = { x = boundary, y = y }
  end
end

print(string.format("lens boundary found on %d of %d rows", #pts, MARK_H))
print(string.format("rows %d .. %d", pts[1].y, pts[#pts].y))

print("\nboundary (x as fraction of mark width) every 20 rows:")
for i = 1, #pts, 20 do
  local p = pts[i]
  print(string.format("  y %.3f  ->  x %.3f", p.y / MARK_H, p.x / MARK_W))
end

-- least squares circle fit over the UPPER half only (lower is its mirror)
local upper = {}
for _, p in ipairs(pts) do
  if p.y <= MARK_H / 2 then upper[#upper + 1] = p end
end

-- solve for D,E,F in x^2+y^2+Dx+Ey+F=0 via normal equations
local n = #upper
local Sxx, Sxy, Syy, Sx, Sy = 0, 0, 0, 0, 0
local Sx3, Sxy2, Sx2y, Sy3, Sx2, Sy2 = 0, 0, 0, 0, 0, 0
for _, p in ipairs(upper) do
  local x, y = p.x, p.y
  Sx = Sx + x; Sy = Sy + y
  Sxx = Sxx + x * x; Syy = Syy + y * y; Sxy = Sxy + x * y
  Sx3 = Sx3 + x * x * x; Sy3 = Sy3 + y * y * y
  Sxy2 = Sxy2 + x * y * y; Sx2y = Sx2y + x * x * y
  Sx2 = Sx2 + x * x; Sy2 = Sy2 + y * y
end

-- 3x3 system
local A = {
  { Sxx, Sxy, Sx },
  { Sxy, Syy, Sy },
  { Sx,  Sy,  n  },
}
local B = {
  -(Sx3 + Sxy2),
  -(Sx2y + Sy3),
  -(Sx2 + Sy2),
}

local function solve3(a, b)
  for i = 1, 3 do
    local piv = i
    for r = i + 1, 3 do
      if math.abs(a[r][i]) > math.abs(a[piv][i]) then piv = r end
    end
    a[i], a[piv] = a[piv], a[i]
    b[i], b[piv] = b[piv], b[i]
    for r = i + 1, 3 do
      local m = a[r][i] / a[i][i]
      for c = i, 3 do a[r][c] = a[r][c] - m * a[i][c] end
      b[r] = b[r] - m * b[i]
    end
  end
  local x = {}
  for i = 3, 1, -1 do
    local s = b[i]
    for c = i + 1, 3 do s = s - a[i][c] * x[c] end
    x[i] = s / a[i][i]
  end
  return x
end

local sol = solve3(A, B)
local D, E, F = sol[1], sol[2], sol[3]
local cx, cy = -D / 2, -E / 2
local r = math.sqrt(cx * cx + cy * cy - F)

print(string.format("\nleast-squares circle over %d upper-half points:", n))
print(string.format("  centre (%.1f, %.1f) px   radius %.1f px", cx, cy, r))

local max_err, sum_err = 0, 0
for _, p in ipairs(upper) do
  local d = math.abs(math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2) - r)
  max_err = math.max(max_err, d)
  sum_err = sum_err + d
end
print(string.format("  fit error: mean %.2f px, max %.2f px", sum_err / n, max_err))

print(string.format("\nin units of mark HEIGHT (%d px):", MARK_H))
print(string.format("  LENS_CX = %.5f", cx / MARK_H))
print(string.format("  LENS_CY = %.5f", cy / MARK_H))
print(string.format("  LENS_R  = %.5f", r / MARK_H))

local function ang(x, y) return math.atan(y - cy, x - cx) end
print(string.format("  angle at block edge (x=%d, y=%.0f): %.5f", BLOCK_X1, pts[1].y, ang(BLOCK_X1, pts[1].y)))
print(string.format("  angle at tip        (x=%d, y=%d): %.5f", upper[#upper].x, upper[#upper].y,
  ang(upper[#upper].x, upper[#upper].y)))
print(string.format("  tip x = %.4f of width, first lens row y = %.4f of height",
  upper[#upper].x / MARK_W, pts[1].y / MARK_H))
