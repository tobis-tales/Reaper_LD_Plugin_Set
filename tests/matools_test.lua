-- Exercise steelblue_matools.lua: the MA-Tools marker syntax, both directions.
--
-- The load-bearing property is the round trip -- format(parse(s)) == s -- so
-- most of this file is names that go through both halves and must come back
-- unchanged. No fake reaper needed: the module has no dependencies.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local MA = dofile(folder .. "steelblue_matools.lua")

local fails = 0

local function run(name, fn)
  local ok, detail = fn()
  if not ok then
    fails = fails + 1
  end
  print(string.format("%-46s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
end

local function describe(parts)
  return string.format("cue=%s number=%s command=%s sequence=%s",
    tostring(parts.cue), tostring(parts.number), tostring(parts.command), tostring(parts.sequence))
end

print("steelblue_matools.lua behaviour:\n")

-- ------------------------------------------------------------ round trips

local function roundtrip(text, note)
  run("roundtrip " .. string.format("%-26s", string.format("%q", text)), function()
    local parts = MA.parse(text)
    if not parts then
      return false, "parse returned nil"
    end

    local back = MA.format(parts)
    if back ~= text then
      return false, "came back as " .. string.format("%q", back)
    end

    return true, note or describe(parts)
  end)
end

roundtrip("BeatFx(1)[Top]^BeatFx^", "all four parts")
roundtrip("BeatFx(1)^BeatFx^", "no command")
roundtrip("BeatFx(1)[Top]", "no sequence")
roundtrip("(1)", "number only")
roundtrip("Sweep(1.5)[GO]^Sweep^", "decimal cue number")
roundtrip("Kick (12)(1)[GO]^Kick^", "brackets inside the cue name")
roundtrip("Kick[GO]", "command only")
roundtrip("Kick^Kick^", "sequence only")
roundtrip("(1)[Top]", "unnamed marker, as Rename previews it")

-- ------------------------------------------------------------ parse detail

run("parse keeps track brackets in the cue name", function()
  local parts = MA.parse("Kick (12)(1)[GO]^Kick^")
  if not parts then return false, "nil" end
  if parts.cue ~= "Kick (12)" then return false, "cue=" .. tostring(parts.cue) end
  if parts.number ~= 1 then return false, "number=" .. tostring(parts.number) end
  if parts.command ~= "GO" then return false, "command=" .. tostring(parts.command) end
  if parts.sequence ~= "Kick" then return false, "sequence=" .. tostring(parts.sequence) end
  return true, describe(parts)
end)

run("parse returns the number as a number", function()
  local parts = MA.parse("BeatFx(1)[Top]^BeatFx^")
  return type(parts.number) == "number" and parts.number == 1, "type=" .. type(parts.number)
end)

run("parse leaves missing parts nil", function()
  local parts = MA.parse("Kick[GO]")
  if parts.cue ~= "Kick" then return false, "cue=" .. tostring(parts.cue) end
  return parts.number == nil and parts.sequence == nil, describe(parts)
end)

-- -------------------------------------------------------- names, not syntax

local function no_syntax(text, note)
  run("no syntax " .. string.format("%-26s", string.format("%q", text)), function()
    local parts = MA.parse(text)
    return parts == nil, parts and ("parsed as " .. describe(parts)) or note
  end)
end

no_syntax("Kick", "a plain name")
no_syntax("", "empty string")
no_syntax("abc]^^", "garbage: empty sequence is not syntax")
no_syntax("^^", "empty sequence alone")
no_syntax("Kick[]", "empty command is not syntax")
no_syntax("Kick (a)", "brackets without a number stay in the name")

run("parse(nil) is nil, not an error", function()
  return MA.parse(nil) == nil, "no crash on a nil marker name"
end)

-- ------------------------------------------------------------------ format

run("format{} is the empty string", function()
  local text = MA.format({})
  return text == "", string.format("%q", text)
end)

run("format(nil) is the empty string", function()
  local text = MA.format()
  return text == "", string.format("%q", text)
end)

run("format drops empty parts with their brackets", function()
  local text = MA.format({ cue = "Kick", number = "", command = "", sequence = "" })
  return text == "Kick", string.format("%q", text)
end)

run("format drops an empty cue but keeps the rest", function()
  local text = MA.format({ cue = "", number = 2, command = "Top" })
  return text == "(2)[Top]", string.format("%q", text)
end)

-- tostring(1.0) is "1.0" in Lua 5.3+, which would drift a cue number every
-- time it passed through a float (ImGui sliders, arithmetic, JSON).
run("format writes 1.0 as (1), not (1.0)", function()
  local text = MA.format({ cue = "A", number = 1.0 })
  return text == "A(1)", string.format("%q", text)
end)

run("format takes the number as a string too", function()
  local text = MA.format({ cue = "A", number = "1" })
  return text == "A(1)", string.format("%q", text)
end)

run("format keeps a real decimal", function()
  local text = MA.format({ cue = "A", number = 1.5 })
  return text == "A(1.5)", string.format("%q", text)
end)

-- ------------------------------------------------------------- track names

local function basename(input, want)
  run(string.format("track_basename %-18s -> %s", string.format("%q", input), string.format("%q", want)), function()
    local got = MA.track_basename(input)
    return got == want, string.format("%q", tostring(got))
  end)
end

basename("Kick (12)", "Kick")
basename("Kick", "Kick")
basename("  Kick  (12) ", "Kick")
basename("(12)", "")

local function sequence_number(input, want)
  run(string.format("track_sequence_number %-12s -> %s", string.format("%q", input), tostring(want)), function()
    local got = MA.track_sequence_number(input)
    return got == want, tostring(got)
  end)
end

sequence_number("Kick (12)", 12)
sequence_number("Kick", nil)
sequence_number("Kick (a)", nil)
sequence_number("Kick (1) (13)", 13)

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
