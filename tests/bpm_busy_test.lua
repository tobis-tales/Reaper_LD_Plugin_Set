-- Realistic "busy mix" test: four-on-floor kick, 8th-note bass, 16th hats,
-- snare with tail, sustained pad, section changes. Quantized (no jitter),
-- like a produced electronic track at exactly known BPM.

BPM_ANALYZER_TEST = {}
dofile("/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST
local SR = T.sample_rate

math.randomseed(4242)

local function make_busy_song(bpm, seconds)
  local n = math.floor(seconds * SR)
  local buf = {}

  -- noise floor + sustained pad (energy floor that masks transients)
  local w1, w2, w3 = 2 * math.pi * 220 / SR, 2 * math.pi * 277 / SR, 2 * math.pi * 330 / SR
  for i = 1, n do
    local t = i
    buf[i] = (math.random() - 0.5) * 0.02
      + 0.06 * math.sin(w1 * t) + 0.05 * math.sin(w2 * t) + 0.05 * math.sin(w3 * t)
  end

  local beat_period = 60 / bpm
  local sixteenth = beat_period / 4

  local function add_burst(time_pos, freq, decay, amp)
    local start = math.floor(time_pos * SR) + 1
    local length = math.floor(decay * 6 * SR)
    for j = 0, length do
      local idx = start + j
      if idx >= 1 and idx <= n then
        local t = j / SR
        buf[idx] = buf[idx] + amp * math.exp(-t / decay) * math.sin(2 * math.pi * freq * t)
      end
    end
  end

  local s = 0
  while true do
    local t0 = s * sixteenth
    if t0 >= seconds then break end

    local beat = math.floor(s / 4)
    local sub = s % 4
    local bar = math.floor(beat / 4)
    local breakdown = (bar % 8) == 7 -- every 8th bar: drop kick/bass

    if sub == 0 and not breakdown then
      add_burst(t0, 60, 0.05, 0.9) -- kick on every beat
    end

    if sub % 2 == 0 and not breakdown then
      add_burst(t0, 110, 0.09, 0.35) -- bass on 8ths
    end

    -- 16th hats with accent pattern (always playing)
    local hat_amp = (sub == 0) and 0.30 or ((sub == 2) and 0.25 or 0.15)
    add_burst(t0, 3200, 0.008, hat_amp)

    -- snare on beats 2 and 4, with a longer tail (reverb-ish)
    if sub == 0 and (beat % 4 == 1 or beat % 4 == 3) then
      add_burst(t0, 200, 0.05, 0.5)
      add_burst(t0, 900, 0.20, 0.12)
    end

    s = s + 1
  end

  return buf, n
end

local cases = {
  { bpm = 130.0, seconds = 24 },
  { bpm = 130.0, seconds = 60 },
  { bpm = 130.0, seconds = 120 },
  { bpm = 128.0, seconds = 120 },
  { bpm = 126.5, seconds = 120 },
  { bpm = 140.0, seconds = 60 },
  { bpm = 100.0, seconds = 120 },
  { bpm = 174.0, seconds = 120 },
}

local failures = 0
print(string.format("%-10s %-8s %-10s %-8s %-8s %s", "actual", "span", "estimated", "error", "conf", "verdict"))

for _, case in ipairs(cases) do
  local buf, n = make_busy_song(case.bpm, case.seconds)
  local onsets = T.build_onset_envelope(buf, n, 1)
  local est, conf = onsets and T.estimate_bpm(onsets) or nil, 0
  if onsets then est, conf = T.estimate_bpm(onsets) end

  if not est then
    print(string.format("%-10.2f %-8d FAILED (no estimate)", case.bpm, case.seconds))
    failures = failures + 1
  else
    local best_err = math.huge
    for _, c in ipairs({ est, est * 2, est / 2 }) do
      best_err = math.min(best_err, math.abs(c - case.bpm))
    end
    local limit = (case.seconds >= 60) and 0.10 or 0.30
    local ok = best_err <= limit
    if not ok then failures = failures + 1 end
    print(string.format("%-10.2f %-8d %-10.3f %-8.3f %-8.2f %s",
      case.bpm, case.seconds, est, best_err, conf, ok and "PASS" or "FAIL"))
  end
end

print(failures == 0 and "\nALL PASS" or ("\nFAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
