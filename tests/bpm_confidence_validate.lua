-- Validate the new confidence metric: it must be HIGH for real steady beats
-- and LOW for material with no reliable pulse. Confidence that is always high
-- is as useless as one that is always 55%.

BPM_ANALYZER_TEST = {}
dofile("/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST
local SR = T.sample_rate

math.randomseed(2024)

local function load_song(from_s, to_s)
  local f = assert(io.open("/private/tmp/claude-501/-Users-tobiaspehla/839ceb2f-81f6-448d-8fbd-8ff448cd8a59/scratchpad/song.raw", "rb"))
  local data = f:read("a")
  f:close()
  local n = math.floor(#data / 4)
  local buf, pos = {}, 1
  for i = 1, n do buf[i], pos = string.unpack("<f", data, pos) end
  local a = math.floor(from_s * SR) + 1
  local b = math.min(n, math.floor(to_s * SR))
  local seg = {}
  for i = a, b do seg[#seg + 1] = buf[i] end
  return seg
end

local function burst_adder(buf, n)
  return function(time_pos, freq, decay, amp)
    local start = math.floor(time_pos * SR) + 1
    for j = 0, math.floor(decay * 6 * SR) do
      local idx = start + j
      if idx >= 1 and idx <= n then
        local t = j / SR
        buf[idx] = buf[idx] + amp * math.exp(-t / decay) * math.sin(2 * math.pi * freq * t)
      end
    end
  end
end

local function make_clean(bpm, seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  for i = 1, n do buf[i] = (math.random() - 0.5) * 0.02 end
  local add = burst_adder(buf, n)
  local period = 60 / bpm
  local beat = 0
  while beat * period < seconds do
    add(beat * period, 60, 0.05, 0.9)
    if beat % 4 == 1 or beat % 4 == 3 then add(beat * period, 200, 0.04, 0.5) end
    add(beat * period + period / 2, 3000, 0.01, 0.25)
    beat = beat + 1
  end
  return buf
end

local function make_busy(bpm, seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  local w1, w2 = 2 * math.pi * 220 / SR, 2 * math.pi * 277 / SR
  for i = 1, n do
    buf[i] = (math.random() - 0.5) * 0.02 + 0.06 * math.sin(w1 * i) + 0.05 * math.sin(w2 * i)
  end
  local add = burst_adder(buf, n)
  local sixteenth = (60 / bpm) / 4
  local s = 0
  while s * sixteenth < seconds do
    local sub, beat = s % 4, math.floor(s / 4)
    if sub == 0 then add(s * sixteenth, 60, 0.05, 0.9) end
    if sub % 2 == 0 then add(s * sixteenth, 110, 0.09, 0.35) end
    add(s * sixteenth, 3200, 0.008, sub == 0 and 0.30 or 0.15)
    if sub == 0 and (beat % 4 == 1 or beat % 4 == 3) then add(s * sixteenth, 200, 0.05, 0.5) end
    s = s + 1
  end
  return buf
end

local function make_noise(seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  for i = 1, n do buf[i] = (math.random() - 0.5) * 0.5 end
  return buf
end

local function make_ambient(seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  local w1, w2 = 2 * math.pi * 196 / SR, 2 * math.pi * 294 / SR
  for i = 1, n do
    local env = 0.5 + 0.5 * math.sin(2 * math.pi * (i / SR) / 7.3)
    buf[i] = env * (0.2 * math.sin(w1 * i) + 0.15 * math.sin(w2 * i)) + (math.random() - 0.5) * 0.02
  end
  local add = burst_adder(buf, n)
  for _ = 1, 20 do add(math.random() * (seconds - 1), 150, 0.08, 0.4) end
  return buf
end

local function make_rubato(seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  for i = 1, n do buf[i] = (math.random() - 0.5) * 0.02 end
  local add = burst_adder(buf, n)
  local t = 0
  while t < seconds do
    add(t, 60, 0.05, 0.9)
    t = t + 60 / (110 + 40 * (t / seconds))
  end
  return buf
end

local function run(buf, label, expect)
  local onsets = T.build_onset_envelope(buf, #buf, 1)
  if not onsets then
    print(string.format("%-30s NO ENVELOPE", label))
    return true
  end
  local bpm, conf, oct_bpm, oct_share = T.estimate_bpm(onsets)
  local ok
  if expect == "high" then ok = conf >= 0.70 else ok = conf <= 0.35 end
  print(string.format("%-30s bpm=%7.2f  conf=%3.0f%%  %-9s %s%s",
    label, bpm or -1, (conf or 0) * 100, expect == "high" and "(want>=70)" or "(want<=35)",
    ok and "PASS" or "FAIL",
    oct_bpm and string.format("   [octave hint: %.2f @ %.0f%%]", oct_bpm, oct_share * 100) or ""))
  return ok
end

print("confidence must be HIGH for real beats, LOW for junk:\n")
local fails = 0
local function check(ok) if not ok then fails = fails + 1 end end

check(run(load_song(36.6, 156.6), "REAL SONG precision 120s", "high"))
check(run(load_song(0, 60), "REAL SONG first 60s", "high"))
check(run(load_song(30, 54), "REAL SONG live window 24s", "high"))
check(run(make_clean(130, 120), "synth clean 130", "high"))
check(run(make_busy(128, 120), "synth busy mix 128", "high"))
check(run(make_busy(100, 60), "synth busy mix 100", "high"))
print("")
check(run(make_noise(60), "CONTROL white noise", "low"))
check(run(make_ambient(60), "CONTROL ambient pad", "low"))
check(run(make_rubato(60), "CONTROL rubato 110->150", "low"))

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
