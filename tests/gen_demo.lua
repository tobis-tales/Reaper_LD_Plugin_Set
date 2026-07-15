-- Build a demo REAPER project for the tutorial screenshots:
-- synthetic drum loop (no client material), a MIDI item, named markers.

local DIR = "/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/Demo Project"
os.execute(string.format("mkdir -p %q", DIR))

local SR = 44100
local BPM = 128
local BARS = 8
local BEAT = 60 / BPM
local LENGTH = BARS * 4 * BEAT

------------------------------------------------------------------ audio

local n = math.floor(LENGTH * SR)
local buf = {}
for i = 1, n do buf[i] = 0 end

local function add(t0, freq, decay, amp, noise)
  local start = math.floor(t0 * SR) + 1
  for j = 0, math.floor(decay * 6 * SR) do
    local i = start + j
    if i >= 1 and i <= n then
      local t = j / SR
      local env = math.exp(-t / decay)
      local s
      if noise then
        s = (math.random() - 0.5) * 2
      else
        s = math.sin(2 * math.pi * freq * t)
      end
      buf[i] = buf[i] + amp * env * s
    end
  end
end

math.randomseed(7)

local sixteenth = BEAT / 4
local step = 0
while step * sixteenth < LENGTH do
  local sub = step % 4
  local beat = math.floor(step / 4)
  local bar = math.floor(beat / 4)

  if sub == 0 then
    add(step * sixteenth, 55, 0.09, 0.85)          -- kick, four on the floor
  end
  if sub == 0 and (beat % 4 == 1 or beat % 4 == 3) then
    add(step * sixteenth, 190, 0.06, 0.45)         -- snare
    add(step * sixteenth, 1200, 0.09, 0.10, true)
  end
  add(step * sixteenth, 0, 0.006, sub == 0 and 0.14 or 0.07, true)  -- hats
  if sub % 2 == 0 and bar % 4 ~= 3 then
    add(step * sixteenth, 110, 0.10, 0.28)         -- bass
  end

  step = step + 1
end

-- normalise
local peak = 0
for i = 1, n do peak = math.max(peak, math.abs(buf[i])) end
for i = 1, n do buf[i] = buf[i] / peak * 0.89 end

local wav = assert(io.open(DIR .. "/steelblue_demo_beat.wav", "wb"))
local data_bytes = n * 2
wav:write("RIFF")
wav:write(string.pack("<I4", 36 + data_bytes))
wav:write("WAVEfmt ")
wav:write(string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, SR, SR * 2, 2, 16))
wav:write("data")
wav:write(string.pack("<I4", data_bytes))
for i = 1, n do
  wav:write(string.pack("<i2", math.floor(buf[i] * 32767)))
end
wav:close()
print(string.format("wrote steelblue_demo_beat.wav  (%.1f s, %d BPM)", LENGTH, BPM))

------------------------------------------------------------------ MIDI

-- one note per beat, 960 ticks per quarter note
local PPQ = 960
local pitches = { 0x3c, 0x40, 0x43, 0x48, 0x43, 0x40, 0x3c, 0x37 }
local names = { "C4", "E4", "G4", "C5", "G4", "E4", "C4", "G3" }
local midi_events = {}
for _, p in ipairs(pitches) do
  midi_events[#midi_events + 1] = string.format("      E %d 90 %02x 60", 0, p)
  midi_events[#midi_events + 1] = string.format("      E %d 80 %02x 00", PPQ // 2, p)
  midi_events[#midi_events + 1] = string.format("      E %d 90 %02x 60", PPQ // 2, p)
  midi_events[#midi_events + 1] = string.format("      E %d 80 %02x 00", 0, p)
end
-- drop the accidental duplicate pass: keep it simple, one note per beat
midi_events = {}
for index, p in ipairs(pitches) do
  local delta = (index == 1) and 0 or (PPQ // 2)
  midi_events[#midi_events + 1] = string.format("      E %d 90 %02x 60", delta, p)
  midi_events[#midi_events + 1] = string.format("      E %d 80 %02x 00", PPQ // 2, p)
end
midi_events[#midi_events + 1] = "      E 0 b0 7b 00"

local midi_len = #pitches * BEAT

------------------------------------------------------------------ markers

local markers = {
  { pos = 0 * 4 * BEAT, name = "intro" },
  { pos = 2 * 4 * BEAT, name = "verse" },
  { pos = 4 * 4 * BEAT, name = "buildup" },
  { pos = 6 * 4 * BEAT, name = "drop" },
  { pos = 7 * 4 * BEAT, name = "break" },
}

local function guid()
  local hex = "0123456789ABCDEF"
  local out = {}
  for i = 1, 32 do
    local r = math.random(1, 16)
    out[#out + 1] = hex:sub(r, r)
    if i == 8 or i == 12 or i == 16 or i == 20 then out[#out + 1] = "-" end
  end
  return "{" .. table.concat(out) .. "}"
end

local marker_lines = {}
for index, m in ipairs(markers) do
  marker_lines[#marker_lines + 1] = string.format(
    '  MARKER %d %.14f "%s" 0 0 1 B %s 0',
    index, m.pos, m.name, guid()
  )
end

------------------------------------------------------------------ project

local rpp = string.format([[
<REAPER_PROJECT 0.1 "7.75/OSX64" %d
  RIPPLE 0
  GROUPOVERRIDE 0 0 0
  AUTOXFADE 1
  SAMPLERATE %d 0 0
  <RECORD_CFG
  >
  TEMPO %d 4 4
  PLAYRATE 1 0 0.25 4
  SELECTION 0 0
  ZOOM 12 0 0
  VZOOMEX 6 0
  CURSOR 0
%s
  <TRACK
    NAME "BEAT"
    TRACKHEIGHT 78 0
    <ITEM
      POSITION 0
      LENGTH %.6f
      NAME "steelblue_demo_beat"
      IID 1
      <SOURCE WAVE
        FILE "steelblue_demo_beat.wav"
      >
    >
  >
  <TRACK
    NAME "CUE MIDI"
    TRACKHEIGHT 78 0
    <ITEM
      POSITION 0
      LENGTH %.6f
      NAME "cue notes"
      IID 2
      <SOURCE MIDI
        HASDATA 1 %d QN
%s
      >
    >
  >
>
]],
  os.time(), SR, BPM,
  table.concat(marker_lines, "\n"),
  LENGTH,
  midi_len,
  PPQ,
  table.concat(midi_events, "\n")
)

local f = assert(io.open(DIR .. "/steelblue_demo.RPP", "wb"))
f:write(rpp)
f:close()

print("wrote steelblue_demo.RPP")
print(string.format("  %d markers: %s", #markers, (function()
  local t = {}
  for _, m in ipairs(markers) do t[#t + 1] = m.name end
  return table.concat(t, ", ")
end)()))
print(string.format("  MIDI item: %d notes (%s)", #pitches, table.concat(names, " ")))
print("  folder: " .. DIR)
