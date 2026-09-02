-- steelblue_matools.lua
-- MA-Tools marker syntax: one place that builds it and one place that reads it.
--
-- Usage from a script in the same folder:
--   local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
--   local MA = dofile(folder .. "steelblue_matools.lua")
--
-- The syntax is  Cue(Number)[Command]^Sequence^  -- for example
-- BeatFx(1)[Top]^BeatFx^. Every part is optional; an empty part drops out
-- together with its brackets.
--
-- Two rules this module exists to keep:
--   * format and parse are exact inverses. format(parse(s)) == s for every s
--     that parse accepts, so a marker can survive a read/write round trip.
--   * it has no dependencies -- not on reaper, not on the other modules, and
--     it stays inside Lua 5.3 syntax, because the planned grandMA3 plugin
--     reuses this file verbatim and grandMA3 embeds Lua 5.3.

local M = {}

M.VERSION = "1.0"

-- A cue number written back exactly as it came in. tostring(1.0) is "1.0" in
-- Lua 5.3+, which would turn Cue(1) into Cue(1.0) on every round trip.
local function number_text(value)
  if type(value) ~= "number" then
    return tostring(value)
  end

  local as_integer = math.tointeger(value)
  if as_integer then
    return tostring(as_integer)
  end

  return tostring(value)
end

local function is_empty(value)
  return value == nil or value == ""
end

-- { cue, number, command, sequence } -> "Cue(Number)[Command]^Sequence^"
function M.format(parts)
  parts = parts or {}

  local text = ""

  if not is_empty(parts.cue) then
    text = text .. tostring(parts.cue)
  end

  if not is_empty(parts.number) then
    text = text .. "(" .. number_text(parts.number) .. ")"
  end

  if not is_empty(parts.command) then
    text = text .. "[" .. tostring(parts.command) .. "]"
  end

  if not is_empty(parts.sequence) then
    text = text .. "^" .. tostring(parts.sequence) .. "^"
  end

  return text
end

-- A cue number only counts as one if writing it back reproduces the original
-- text. That rejects "01", "1." and "1.50", which are numbers but would come
-- back as "1", "1" and "1.5" and quietly break the round trip; they stay part
-- of the cue name instead.
local function cue_number(text)
  if not text:match("^%d+%.?%d*$") then
    return nil
  end

  local value = tonumber(text)
  if value == nil or number_text(value) ~= text then
    return nil
  end

  return value
end

-- "Cue(Number)[Command]^Sequence^" -> { cue, number, command, sequence }, or
-- nil when the name carries no syntax at all.
--
-- Anchored from the right, because only the tail is unambiguous: a cue name may
-- itself contain brackets. "Kick (12)(1)[GO]^Kick^" is the case that decides
-- the shape -- the track's sequence number stays in the cue name, the trailing
-- (1) is the cue number.
function M.parse(name)
  if type(name) ~= "string" then
    return nil
  end

  local rest = name
  local found = false
  local sequence, command, number

  -- ^...^ last. An empty pair is not something format can produce, so "abc]^^"
  -- is a name, not syntax.
  local before_sequence, sequence_text = rest:match("^(.-)%^([^%^]*)%^$")
  if before_sequence and sequence_text ~= "" then
    rest = before_sequence
    sequence = sequence_text
    found = true
  end

  local before_command, command_text = rest:match("^(.-)%[([^%[%]]*)%]$")
  if before_command and command_text ~= "" then
    rest = before_command
    command = command_text
    found = true
  end

  local before_number, number_text_found = rest:match("^(.-)%(([^%(%)]*)%)$")
  if before_number then
    local value = cue_number(number_text_found)
    if value then
      rest = before_number
      number = value
      found = true
    end
  end

  if not found then
    return nil
  end

  return {
    cue = rest ~= "" and rest or nil,
    number = number,
    command = command,
    sequence = sequence,
  }
end

-- REAPER track name without its bracketed part: "Kick (12)" -> "Kick".
-- The track keeps its brackets -- the MA3 importer needs the number -- so this
-- is only for deriving the lane and sequence name from it.
function M.track_basename(name)
  if type(name) ~= "string" then
    return nil
  end

  return (name:gsub("%b()", ""):match("^%s*(.-)%s*$"))
end

-- The MA sequence number a track carries in its last brackets:
-- "Kick (12)" -> 12, "Kick" -> nil, "Kick (a)" -> nil.
function M.track_sequence_number(name)
  if type(name) ~= "string" then
    return nil
  end

  local last
  for inside in name:gmatch("%(([^%(%)]*)%)") do
    last = inside
  end

  if not last then
    return nil
  end

  return tonumber(last)
end

return M
